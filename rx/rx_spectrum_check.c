/*
 * rx_spectrum_check.c — framing-free MARK/SPACE power check
 * Runs on : ZedBoard + AD9361
 *
 * rx.c is a UART/frame decoder -- it has nothing to lock onto against a
 * bare, unframed debug pattern (tx_gmsk_debug.c sends none), so its output
 * is meaningless noise for that case. This tool skips all of that: same
 * Goertzel power measurement rx.c already uses (reused verbatim, same
 * bins/coefficients/windowing), but just accumulates and prints averaged
 * MARK/SPACE power once a second, continuously, with no bit-decision or
 * UART state machine involved. Purely "is there a real, sustained power
 * difference between the two tones" -- a software-side check that's
 * independent of both rx.c's framing assumptions and the FPGA
 * discriminator IP, so a problem can be isolated to one or the other.
 */

#define _DEFAULT_SOURCE

#include <iio.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "../common/rf_params.h"

#define BUFFER_SAMPLES          23040   /* 10 ms at 2.304 Msps */
#define DECIMATION_FACTOR           4   /* analyze every fourth ADC sample */
#define WINDOW_ANALYSIS_SAMPLES   576   /* 2304 / 4 */
#define ANALYSIS_SAMPLE_RATE  576000LL  /* 2.304 Msps / 4 */
#define RX_GAIN_DB                 46   /* matches the value already
                                          * calibrated against real signal
                                          * amplitude this session */
#define DEBUG_RF_BANDWIDTH_HZ 4000000LL  /* wider than rf_params.h's 400 kHz --
                                          * matches tx_gmsk_debug.c's widened
                                          * filter for its faster debug bit
                                          * rate; this tool has no obligation
                                          * to stay within the "real" link's
                                          * configured bandwidth */

static volatile sig_atomic_t running = 1;

static void on_signal(int signo)
{
    (void)signo;
    running = 0;
}

/* Verbatim from rx.c -- see that file's Goertzel comment for the algorithm. */
static float goertzel_power(const char *base, ptrdiff_t step, int n,
                            float coefficient)
{
    float sI1 = 0.0f, sI2 = 0.0f;
    float sQ1 = 0.0f, sQ2 = 0.0f;

    const char *p = base;
    for (int i = 0; i < n; i++, p += step) {
        const int16_t *iq = (const int16_t *)p;
        float I = (float)iq[0];
        float Q = (float)iq[1];

        float sI0 = coefficient * sI1 - sI2 + I;
        sI2 = sI1;  sI1 = sI0;

        float sQ0 = coefficient * sQ1 - sQ2 + Q;
        sQ2 = sQ1;  sQ1 = sQ0;
    }

    float pI = sI1*sI1 + sI2*sI2 - coefficient*sI1*sI2;
    float pQ = sQ1*sQ1 + sQ2*sQ2 - coefficient*sQ1*sQ2;
    return pI + pQ;
}

int main(void)
{
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    fprintf(stderr, "\n== SDR_Link: framing-free MARK/SPACE power check ==\n\n");

    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) {
        fprintf(stderr, "ERROR: cannot open local IIO context\n");
        return EXIT_FAILURE;
    }

    struct iio_device *phy = iio_context_find_device(ctx, PHY_DEVICE);
    struct iio_device *rx  = iio_context_find_device(ctx, RX_DEVICE);
    if (!phy || !rx) {
        fprintf(stderr, "ERROR: AD9361 devices not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_channel *lo_rx  = iio_device_find_channel(phy, "altvoltage0", true);
    struct iio_channel *rx_phy = iio_device_find_channel(phy, "voltage0",    false);
    if (!lo_rx || !rx_phy) {
        fprintf(stderr, "ERROR: RX PHY channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    iio_channel_attr_write_longlong(lo_rx,  "frequency",          CARRIER_FREQ_HZ);
    iio_channel_attr_write_longlong(rx_phy, "rf_bandwidth",       DEBUG_RF_BANDWIDTH_HZ);
    iio_channel_attr_write_longlong(rx_phy, "sampling_frequency", SAMPLE_RATE_HZ);
    iio_channel_attr_write(rx_phy, "gain_control_mode", "manual");
    iio_channel_attr_write_longlong(rx_phy, "hardwaregain", RX_GAIN_DB);

    fprintf(stderr, "RX LO: %.3f MHz, gain: %d dB, MARK bin: %.0f kHz, SPACE bin: %.0f kHz\n\n",
            CARRIER_FREQ_HZ / 1e6, RX_GAIN_DB,
            FSK_TONE_MARK_HZ / 1e3, FSK_TONE_SPACE_HZ / 1e3);

    struct iio_channel *rx_i = iio_device_find_channel(rx, "voltage0", false);
    struct iio_channel *rx_q = iio_device_find_channel(rx, "voltage1", false);
    if (!rx_i || !rx_q) {
        fprintf(stderr, "ERROR: IQ channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }
    iio_channel_enable(rx_i);
    iio_channel_enable(rx_q);

    struct iio_buffer *buf = iio_device_create_buffer(rx, BUFFER_SAMPLES, false);
    if (!buf) {
        fprintf(stderr, "ERROR: failed to create RX buffer\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    const float mark_coeff = 2.0f * cosf(2.0f * (float)M_PI *
        (float)FSK_TONE_MARK_HZ / (float)ANALYSIS_SAMPLE_RATE);
    const float space_coeff = 2.0f * cosf(2.0f * (float)M_PI *
        (float)FSK_TONE_SPACE_HZ / (float)ANALYSIS_SAMPLE_RATE);

    fprintf(stderr, "Averaging over ~1s, printing once per second. Ctrl-C to stop.\n\n");
    fprintf(stderr, "  mark_pow      space_pow     dP(dB)\n");
    fprintf(stderr, "  ────────────────────────────────────\n");

    double mark_sum = 0.0, space_sum = 0.0;
    long   window_cnt = 0;
    int    refill_cnt = 0;

    while (running) {
        ptrdiff_t n = iio_buffer_refill(buf);
        if (n < 0) {
            fprintf(stderr, "iio_buffer_refill error: %zd\n", n);
            break;
        }

        const ptrdiff_t step = iio_buffer_step(buf);
        char *window_start = (char *)iio_buffer_first(buf, rx_i);
        const int num_windows = BUFFER_SAMPLES / (WINDOW_ANALYSIS_SAMPLES * DECIMATION_FACTOR);

        for (int w = 0; w < num_windows; w++) {
            float pm = goertzel_power(window_start, step * DECIMATION_FACTOR,
                                      WINDOW_ANALYSIS_SAMPLES, mark_coeff);
            float ps = goertzel_power(window_start, step * DECIMATION_FACTOR,
                                      WINDOW_ANALYSIS_SAMPLES, space_coeff);
            mark_sum += pm;
            space_sum += ps;
            window_cnt++;
            window_start += step * WINDOW_ANALYSIS_SAMPLES * DECIMATION_FACTOR;
        }

        /* Buffer is 10 ms -- print once per ~100 buffers (~1 s). */
        if (++refill_cnt >= 100) {
            double mark_avg  = mark_sum / window_cnt;
            double space_avg = space_sum / window_cnt;
            double dp_db = 10.0 * log10(mark_avg / space_avg);
            fprintf(stderr, "  %-13.1f %-13.1f %+.2f\n", mark_avg, space_avg, dp_db);
            mark_sum = 0.0; space_sum = 0.0; window_cnt = 0; refill_cnt = 0;
        }
    }

    iio_buffer_destroy(buf);
    iio_context_destroy(ctx);
    fprintf(stderr, "Stopped.\n");
    return EXIT_SUCCESS;
}
