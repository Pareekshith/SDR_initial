/*
 * rx_buffer_lab.c — Learn what an Industrial I/O (IIO) RX buffer contains
 * Runs on : Pluto+ / AD9361
 * Build   : make rx-lab-build
 * Deploy  : make rx-lab-deploy
 * Run     : make rx-lab-run
 *
 * This is deliberately a diagnostic/teaching program, not a data decoder.
 * It leaves rx.c unchanged while making the FPGA -> DMA -> RAM -> ARM path
 * visible at the C-program level.
 *
 * HARDWARE DATA PATH
 * ------------------
 *
 *   antenna -> AD9361 ADC -> FPGA RX core -> AXI DMA -> RAM -> this program
 *
 * The DMA controller writes ADC samples into RAM without asking the ARM to
 * copy every sample.  iio_buffer_refill() blocks until one DMA buffer has
 * completed, then libiio gives the ARM a pointer to those samples in RAM.
 * There is no second DMA from RAM to the ARM: the ARM reads RAM normally.
 *
 * BUFFER TIME
 * -----------
 *
 * At 2.304 Msps, a buffer of 23040 IQ scans describes 10 ms of RF history:
 *
 *     23040 samples / 2304000 samples/s = 0.010 s
 *
 * A refill is therefore not an instantaneous measurement.  By the time the
 * function returns, all 10 ms of samples have already been captured.
 *
 * MEMORY LAYOUT
 * -------------
 *
 * With voltage0 (I) and voltage1 (Q) enabled, one scan normally looks like:
 *
 *     [I: signed 16-bit] [Q: signed 16-bit]
 *
 * Do not hard-code four bytes per scan.  iio_buffer_step() reports the real
 * spacing, and iio_buffer_first() locates the selected channel's first item.
 *
 * SEEING A TONE TRANSITION
 * ------------------------
 *
 * The full 10 ms buffer is divided into ten 1 ms windows.  Each window gets
 * two Goertzel measurements: power at SPACE (50 kHz) and MARK (150 kHz).
 * The resulting line might look like this:
 *
 *   buf 007: M+21 M+20 M+18 ?+1 S-17 S-21 S-22 S-20 S-19 S-21
 *
 * This says the transmitter changed from MARK to SPACE inside that buffer.
 * "?" marks a window where the two powers differ by less than 6 dB, usually
 * because it contains a transition.  The signed number is
 * 10*log10(Pmark/Pspace): positive means MARK, negative means SPACE.
 *
 * THREE DIFFERENT TIME MEASUREMENTS
 * ---------------------------------
 *
 *   processing_ms = time from the previous refill return until this refill
 *                   call begins (Goertzel, printf and loop overhead)
 *   refill_ms     = time blocked inside this iio_buffer_refill() call
 *   cycle_ms      = time between two completed refill calls
 *
 * Except for small clock-reading overhead:
 *
 *   cycle_ms = processing_ms + refill_ms
 *
 * If DMA fills a queued next block while the ARM processes the old block,
 * more processing should cause less refill waiting.  If capture is rearmed
 * only by refill, refill_ms will remain near 10 ms and cycle_ms will grow by
 * the processing time.  Measuring the phases separately tells us which
 * behaviour this Pluto+ IIO stack actually has.
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
#include <string.h>
#include <time.h>

#include "../common/rf_params.h"

#define BUFFER_SAMPLES       23040
#define WINDOWS_PER_BUFFER      10
#define WINDOW_SAMPLES       (BUFFER_SAMPLES / WINDOWS_PER_BUFFER)
#define DECIMATION_FACTOR        4
#define ANALYSIS_SAMPLE_RATE  (SAMPLE_RATE_HZ / DECIMATION_FACTOR)
#define ANALYSIS_WINDOW_SAMPLES (WINDOW_SAMPLES / DECIMATION_FACTOR)
#define ANALYSIS_BUFFER_SAMPLES (BUFFER_SAMPLES / DECIMATION_FACTOR)
#define DEFAULT_BUFFER_COUNT    50
#define BENCHMARK_BUFFER_COUNT 500
#define RAW_SAMPLES_TO_PRINT     8
#define UNCERTAIN_DB             6.0f

static volatile sig_atomic_t g_running = 1;

static void on_signal(int signal_number)
{
    (void)signal_number;
    g_running = 0;
}

static int write_ll(struct iio_channel *channel, const char *attribute,
                    long long value)
{
    int rc = iio_channel_attr_write_longlong(channel, attribute, value);
    if (rc < 0)
        fprintf(stderr, "ERROR: writing %s failed (%d)\n", attribute, rc);
    return rc;
}

static int write_text(struct iio_channel *channel, const char *attribute,
                      const char *value)
{
    int rc = iio_channel_attr_write(channel, attribute, value);
    if (rc < 0)
        fprintf(stderr, "ERROR: writing %s failed (%d)\n", attribute, rc);
    return rc;
}

/* Return Goertzel power at one frequency for a section of interleaved IQ.
 * "base" points at the section's first I sample and "step" is the number
 * of bytes from one IQ scan to the next. */
static float goertzel_power(const char *base, ptrdiff_t step, int sample_count,
                            float target_hz, float sample_rate)
{
    const float omega = 2.0f * (float)M_PI * target_hz /
                        sample_rate;
    const float coefficient = 2.0f * cosf(omega);
    float i1 = 0.0f, i2 = 0.0f;
    float q1 = 0.0f, q2 = 0.0f;

    for (int n = 0; n < sample_count; n++) {
        const int16_t *iq = (const int16_t *)(base + (ptrdiff_t)n * step);
        const float i0 = coefficient * i1 - i2 + (float)iq[0];
        const float q0 = coefficient * q1 - q2 + (float)iq[1];
        i2 = i1;
        i1 = i0;
        q2 = q1;
        q1 = q0;
    }

    const float pi = i1*i1 + i2*i2 - coefficient*i1*i2;
    const float pq = q1*q1 + q2*q2 - coefficient*q1*q2;
    return pi + pq;
}

static double elapsed_ms(const struct timespec *before,
                         const struct timespec *after)
{
    return (double)(after->tv_sec - before->tv_sec) * 1000.0 +
           (double)(after->tv_nsec - before->tv_nsec) / 1000000.0;
}

int main(int argc, char **argv)
{
    int requested_buffers = DEFAULT_BUFFER_COUNT;
    bool benchmark_mode = false;
    const char *count_argument = NULL;

    if (argc >= 2 && strcmp(argv[1], "--benchmark") == 0) {
        benchmark_mode = true;
        requested_buffers = BENCHMARK_BUFFER_COUNT;
        if (argc == 3)
            count_argument = argv[2];
        else if (argc > 3) {
            fprintf(stderr, "Usage: %s [count] | --benchmark [count]\n", argv[0]);
            return EXIT_FAILURE;
        }
    } else if (argc == 2) {
        count_argument = argv[1];
    } else if (argc > 2) {
        fprintf(stderr, "Usage: %s [count] | --benchmark [count]\n", argv[0]);
        return EXIT_FAILURE;
    }

    if (count_argument) {
        char *end = NULL;
        long value = strtol(count_argument, &end, 10);
        if (!end || *end != '\0' || value < 1 || value > 100000) {
            fprintf(stderr, "Usage: %s [count] | --benchmark [count]\n", argv[0]);
            return EXIT_FAILURE;
        }
        requested_buffers = (int)value;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    fprintf(stderr, "\n== SDR_Link: IIO RX Buffer Laboratory ==\n\n");
    fprintf(stderr, "One DMA buffer : %d IQ scans = %.1f ms\n",
            BUFFER_SAMPLES,
            1000.0 * BUFFER_SAMPLES / (double)SAMPLE_RATE_HZ);
    fprintf(stderr, "One analysis window: %d IQ scans = %.1f ms\n\n",
            WINDOW_SAMPLES,
            1000.0 * WINDOW_SAMPLES / (double)SAMPLE_RATE_HZ);
    fprintf(stderr,
            "DSP decimation    : %d (analyze %d of %d samples per 1 ms window)\n"
            "Analysis rate     : %.3f ksps, Nyquist %.3f kHz\n\n",
            DECIMATION_FACTOR, ANALYSIS_WINDOW_SAMPLES, WINDOW_SAMPLES,
            ANALYSIS_SAMPLE_RATE / 1000.0,
            ANALYSIS_SAMPLE_RATE / 2000.0);

    struct iio_context *context = iio_create_local_context();
    if (!context) {
        fprintf(stderr, "ERROR: cannot create local IIO context\n");
        return EXIT_FAILURE;
    }

    struct iio_device *phy = iio_context_find_device(context, PHY_DEVICE);
    struct iio_device *rx = iio_context_find_device(context, RX_DEVICE);
    if (!phy || !rx) {
        fprintf(stderr, "ERROR: required AD9361 IIO devices not found\n");
        iio_context_destroy(context);
        return EXIT_FAILURE;
    }

    struct iio_channel *lo =
        iio_device_find_channel(phy, "altvoltage0", true);
    struct iio_channel *rx_phy =
        iio_device_find_channel(phy, "voltage0", false);
    struct iio_channel *rx_i =
        iio_device_find_channel(rx, "voltage0", false);
    struct iio_channel *rx_q =
        iio_device_find_channel(rx, "voltage1", false);
    if (!lo || !rx_phy || !rx_i || !rx_q) {
        fprintf(stderr, "ERROR: required AD9361 channels not found\n");
        iio_context_destroy(context);
        return EXIT_FAILURE;
    }

    if (write_ll(lo, "frequency", CARRIER_FREQ_HZ) < 0 ||
        write_ll(rx_phy, "rf_bandwidth", RF_BANDWIDTH_HZ) < 0 ||
        write_ll(rx_phy, "sampling_frequency", SAMPLE_RATE_HZ) < 0 ||
        write_text(rx_phy, "gain_control_mode", "manual") < 0 ||
        write_ll(rx_phy, "hardwaregain", 40) < 0) {
        iio_context_destroy(context);
        return EXIT_FAILURE;
    }

    iio_channel_enable(rx_i);
    iio_channel_enable(rx_q);

    /* false means non-cyclic RX operation.  Each refill requests the next
     * completed capture rather than replaying one old buffer. */
    struct iio_buffer *buffer =
        iio_device_create_buffer(rx, BUFFER_SAMPLES, false);
    if (!buffer) {
        fprintf(stderr, "ERROR: cannot create RX DMA buffer\n");
        iio_context_destroy(context);
        return EXIT_FAILURE;
    }

    if (benchmark_mode) {
        fprintf(stderr,
            "QUIET BENCHMARK: %d buffers, two decimate-by-4 Goertzel detectors.\n"
            "No per-buffer output will be produced (Ctrl-C stops early).\n\n",
            requested_buffers);
    } else {
        fprintf(stderr, "Capturing %d buffers (Ctrl-C stops early).\n",
                requested_buffers);
        fprintf(stderr,
            "Legend: M=MARK, S=SPACE, ?=within %.0f dB; number is Delta-P dB\n\n",
            UNCERTAIN_DB);
    }

    struct timespec previous_return = { 0, 0 };
    bool have_previous_return = false;
    double total_processing_ms = 0.0;
    double total_refill_ms = 0.0;
    double total_cycle_ms = 0.0;
    int timing_cycles = 0;
    int completed_buffers = 0;
    double total_analysis_ms = 0.0;
    double min_analysis_ms = 1.0e30;
    double max_analysis_ms = 0.0;
    double min_steady_refill_ms = 1.0e30;
    double max_steady_refill_ms = 0.0;
    double total_steady_refill_ms = 0.0;
    int steady_refills = 0;
    unsigned long mark_decisions = 0;
    unsigned long space_decisions = 0;
    volatile float power_checksum = 0.0f;

    for (int buffer_number = 0;
         buffer_number < requested_buffers && g_running;
         buffer_number++) {
        /* call_start is recorded immediately before entering libiio.  The
         * interval from previous_return to call_start is everything our
         * application did with the preceding buffer. */
        struct timespec call_start;
        clock_gettime(CLOCK_MONOTONIC, &call_start);

        const ssize_t byte_count = iio_buffer_refill(buffer);
        struct timespec this_return;
        clock_gettime(CLOCK_MONOTONIC, &this_return);

        if (byte_count < 0) {
            fprintf(stderr, "ERROR: iio_buffer_refill returned %zd\n", byte_count);
            break;
        }

        const char *first = (const char *)iio_buffer_first(buffer, rx_i);
        const ptrdiff_t step = iio_buffer_step(buffer);
        const ptrdiff_t available_samples = step > 0 ? byte_count / step : 0;
        const double refill_ms = elapsed_ms(&call_start, &this_return);
        const double processing_ms = have_previous_return ?
            elapsed_ms(&previous_return, &call_start) : 0.0;
        const double cycle_ms = have_previous_return ?
            elapsed_ms(&previous_return, &this_return) : 0.0;

        total_refill_ms += refill_ms;
        if (have_previous_return) {
            total_processing_ms += processing_ms;
            total_cycle_ms += cycle_ms;
            timing_cycles++;
            total_steady_refill_ms += refill_ms;
            if (refill_ms < min_steady_refill_ms) min_steady_refill_ms = refill_ms;
            if (refill_ms > max_steady_refill_ms) max_steady_refill_ms = refill_ms;
            steady_refills++;
        }
        previous_return = this_return;
        have_previous_return = true;
        completed_buffers++;

        if (buffer_number == 0 && !benchmark_mode) {
            fprintf(stderr, "First refill metadata:\n");
            fprintf(stderr, "  returned bytes       : %zd\n", byte_count);
            fprintf(stderr, "  bytes per IQ scan    : %td\n", step);
            fprintf(stderr, "  calculated IQ scans  : %td\n", available_samples);
            fprintf(stderr, "  requested IQ scans   : %d\n", BUFFER_SAMPLES);
            fprintf(stderr, "  first %d raw [I,Q] pairs:\n", RAW_SAMPLES_TO_PRINT);
            for (int n = 0; n < RAW_SAMPLES_TO_PRINT && n < available_samples; n++) {
                const int16_t *iq =
                    (const int16_t *)(first + (ptrdiff_t)n * step);
                fprintf(stderr, "    sample[%d] = [%6d, %6d]\n",
                        n, iq[0], iq[1]);
            }
            fprintf(stderr, "\n");
        }

        if (available_samples < BUFFER_SAMPLES) {
            fprintf(stderr, "ERROR: short buffer: only %td IQ scans\n",
                    available_samples);
            break;
        }

        if (benchmark_mode) {
            /* Same workload as the revised rx.c: retain every fourth input
             * sample, then run two Goertzel detectors over the resulting
             * 5760 samples.  Timing excludes refill and terminal output. */
            struct timespec analysis_start, analysis_end;
            clock_gettime(CLOCK_MONOTONIC, &analysis_start);
            const float mark = goertzel_power(
                first, step * DECIMATION_FACTOR, ANALYSIS_BUFFER_SAMPLES,
                (float)FSK_TONE_MARK_HZ, (float)ANALYSIS_SAMPLE_RATE);
            const float space = goertzel_power(
                first, step * DECIMATION_FACTOR, ANALYSIS_BUFFER_SAMPLES,
                (float)FSK_TONE_SPACE_HZ, (float)ANALYSIS_SAMPLE_RATE);
            clock_gettime(CLOCK_MONOTONIC, &analysis_end);

            const double analysis_ms =
                elapsed_ms(&analysis_start, &analysis_end);
            total_analysis_ms += analysis_ms;
            if (analysis_ms < min_analysis_ms) min_analysis_ms = analysis_ms;
            if (analysis_ms > max_analysis_ms) max_analysis_ms = analysis_ms;

            if (mark > space) mark_decisions++;
            else              space_decisions++;
            /* Making the result externally observable prevents an optimizing
             * compiler from deleting either Goertzel calculation. */
            power_checksum += mark / (space + 1.0f);
            continue;
        }

        if (buffer_number == 0) {
            printf("buf %03d  process   n/a  refill %6.2f  cycle   n/a :",
                   buffer_number, refill_ms);
        } else {
            printf("buf %03d  process %5.2f  refill %6.2f  cycle %6.2f :",
                   buffer_number, processing_ms, refill_ms, cycle_ms);
        }
        for (int window = 0; window < WINDOWS_PER_BUFFER; window++) {
            const char *window_start =
                first + (ptrdiff_t)window * WINDOW_SAMPLES * step;
            const float mark = goertzel_power(
                window_start, step * DECIMATION_FACTOR,
                ANALYSIS_WINDOW_SAMPLES, (float)FSK_TONE_MARK_HZ,
                (float)ANALYSIS_SAMPLE_RATE);
            const float space = goertzel_power(
                window_start, step * DECIMATION_FACTOR,
                ANALYSIS_WINDOW_SAMPLES, (float)FSK_TONE_SPACE_HZ,
                (float)ANALYSIS_SAMPLE_RATE);
            const float delta_db =
                10.0f * log10f((mark + 1.0e-20f) / (space + 1.0e-20f));
            const char decision = fabsf(delta_db) < UNCERTAIN_DB ? '?' :
                                  delta_db > 0.0f ? 'M' : 'S';
            printf(" %c%+3.0f", decision, delta_db);
        }
        putchar('\n');
        fflush(stdout);
    }

    iio_buffer_destroy(buffer);
    iio_context_destroy(context);
    fprintf(stderr, "\nTiming summary:\n");
    fprintf(stderr, "  completed buffers : %d\n", completed_buffers);
    if (completed_buffers > 0)
        fprintf(stderr, "  initial refill_ms  : %.3f\n",
                total_refill_ms - total_steady_refill_ms);
    if (steady_refills > 0) {
        fprintf(stderr, "  steady refill_ms   : min %.3f  avg %.3f  max %.3f\n",
                min_steady_refill_ms,
                total_steady_refill_ms / steady_refills,
                max_steady_refill_ms);
    }
    if (timing_cycles > 0) {
        fprintf(stderr, "  average processing_ms: %.3f\n",
                total_processing_ms / timing_cycles);
        fprintf(stderr, "  average cycle_ms     : %.3f\n",
                total_cycle_ms / timing_cycles);
    }
    if (benchmark_mode && completed_buffers > 0) {
        fprintf(stderr, "\nQuiet DSP benchmark (two decimate-by-4 Goertzels):\n");
        fprintf(stderr, "  analysis_ms       : min %.3f  avg %.3f  max %.3f\n",
                min_analysis_ms,
                total_analysis_ms / completed_buffers,
                max_analysis_ms);
        fprintf(stderr, "  real-time budget  : %.3f ms per buffer\n",
                1000.0 * BUFFER_SAMPLES / (double)SAMPLE_RATE_HZ);
        fprintf(stderr, "  timing margin     : %.3f ms (budget - worst case)\n",
                1000.0 * BUFFER_SAMPLES / (double)SAMPLE_RATE_HZ -
                max_analysis_ms);
        fprintf(stderr, "  decisions         : MARK %lu, SPACE %lu\n",
                mark_decisions, space_decisions);
        fprintf(stderr, "  checksum          : %.6g\n", (double)power_checksum);
    }
    fprintf(stderr, "\nCapture complete.\n");
    return EXIT_SUCCESS;
}
