/*
 * rx.c — OOK / UART Receiver + Decoder
 * Runs on : ADALM-PLUTO+ (AD9361)
 * Build   : cross-compile from laptop (see Makefile)
 * Run     : /tmp/rx
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 4 — IQ envelope detection (recap)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  After down-conversion, the AD9361 gives us complex baseband samples:
 *
 *    I(t) = A·cos(2π·Δf·t + φ)
 *    Q(t) = A·sin(2π·Δf·t + φ)
 *
 *  We recover the amplitude A (regardless of phase φ) by:
 *
 *    magnitude = √(I² + Q²) = A     (Pythagoras — works for any φ)
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 7 — OOK detection
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  OOK turns the carrier ON (1) or OFF (0).  We detect it by:
 *
 *    1. Compute RMS of √(I²+Q²) over one buffer (10 ms)
 *    2. Compare RMS → dBFS against a threshold:
 *         dBFS > OOK_THRESHOLD_DBFS  →  level = 1  (carrier present)
 *         dBFS ≤ OOK_THRESHOLD_DBFS  →  level = 0  (silence)
 *
 *  Our baseline: signal ≈ -37 dBFS (TX on),  noise ≈ -78 dBFS (TX off).
 *  Threshold at -55 dBFS sits 18 dB above noise, 18 dB below signal.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 8 — UART framing decoder
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  The TX sends bytes with UART framing (one bit = OOK_BIT_PERIOD_US):
 *
 *    [IDLE=1] ··· [START=0][b0][b1][b2][b3][b4][b5][b6][b7][STOP=1] ···
 *
 *  We recover the bit clock by edge detection:
 *
 *    1. Wait in IDLE until we see a falling edge (1→0) = start bit begins.
 *    2. Wait half a bit period (OOK_HALF_BIT_BUF × 10 ms) to land in the
 *       CENTRE of the start bit.  Sampling in the centre maximises noise margin.
 *    3. Every OOK_BIT_PERIOD_BUF buffers, sample one bit.  Do this 8 times.
 *    4. Verify stop bit (must be 1), then assemble byte and print.
 *
 *  Timing diagram (each cell = one 10 ms buffer, × = sample point):
 *
 *   edge                             bit0    bit1  …  bit7   stop
 *    ↓                                ↓       ↓         ↓      ↓
 *    |  start  |   5 buf  |× 10 buf  ×|  10  ×| …   10 ×| 10  ×|
 *    |_________|          |            |       |          |      |‾‾‾
 *
 *  State machine:  IDLE → START → DATA → STOP → IDLE → …
 */

#include <iio.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../common/rf_params.h"

#define BUFFER_SAMPLES   23040          /* 10 ms at 2.304 Msps                */
#define STATUS_INTERVAL  100            /* print status every 100 buf = 1 s   */

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }

/* ── Decoder state machine ──────────────────────────────────────────────── */
typedef enum { S_IDLE, S_START, S_DATA, S_STOP } ook_state_t;

static const char *state_name[] = { "IDLE ", "START", "DATA ", "STOP " };

/* ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════╗\n"
        "║  SDR_Link — OOK Receiver / Decoder (Pluto+ / AD9361)     ║\n"
        "╚══════════════════════════════════════════════════════════╝\n\n");

    /* ── Step 1: Open IIO context ───────────────────────────────────────── */
    fprintf(stderr, "[ 1/4 ] Opening IIO context...\n");
    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) {
        fprintf(stderr, "ERROR: cannot open local IIO context\n");
        return EXIT_FAILURE;
    }
    fprintf(stderr, "        %s\n\n", iio_context_get_description(ctx));

    /* ── Step 2: Configure AD9361 RF front-end ───────────────────────────── */
    fprintf(stderr, "[ 2/4 ] Configuring AD9361 RF front-end...\n");
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

    /*
     * Tune the RX LO directly to the TX tone frequency (434.020 MHz).
     * After mixing, the tone appears at 0 Hz (DC) in baseband.
     * √(I²+Q²) gives the envelope — perfect for OOK detection.
     */
    iio_channel_attr_write_longlong(lo_rx,  "frequency",          TONE_FREQ_HZ);
    iio_channel_attr_write_longlong(rx_phy, "rf_bandwidth",       RF_BANDWIDTH_HZ);
    iio_channel_attr_write_longlong(rx_phy, "sampling_frequency", SAMPLE_RATE_HZ);

    /* Manual gain: fixed at 40 dB so noise floor stays low */
    iio_channel_attr_write(rx_phy, "gain_control_mode", "manual");
    iio_channel_attr_write_longlong(rx_phy, "hardwaregain", 40);

    fprintf(stderr, "        RX LO     : %.3f MHz\n", TONE_FREQ_HZ / 1e6);
    fprintf(stderr, "        Gain      : 40 dB manual\n");
    fprintf(stderr, "        Threshold : %.1f dBFS\n\n", OOK_THRESHOLD_DBFS);

    /* ── Step 3: Enable IQ channels and create DMA buffer ──────────────── */
    fprintf(stderr, "[ 3/4 ] Creating RX buffer...\n");
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
    fprintf(stderr, "        Buffer    : %d samples (%.0f ms)\n\n",
            BUFFER_SAMPLES, 1000.0 * BUFFER_SAMPLES / SAMPLE_RATE_HZ);

    /* ── Step 4: OOK decoder loop ────────────────────────────────────────
     *
     * One iteration = one buffer refill = 10 ms of samples.
     *
     * Each iteration:
     *   1. Refill buffer (DMA from ADC)
     *   2. Compute RMS of |IQ| → dBFS → binary level (0 or 1)
     *   3. Advance the UART decoder state machine
     *   4. Print status to stderr, decoded chars to stdout
     */
    fprintf(stderr, "[ 4/4 ] Listening on %.3f MHz — press Ctrl-C to stop.\n",
            TONE_FREQ_HZ / 1e6);
    fprintf(stderr, "        Decoded message appears below.\n\n");
    fprintf(stderr, "  [state] [dBFS]   [level]\n");
    fprintf(stderr, "  ─────────────────────────────────────────────\n");

    ook_state_t state    = S_IDLE;
    int         buf_cnt  = 0;       /* buffers counted within current state   */
    int         bit_cnt  = 0;       /* data bits collected so far             */
    uint8_t     dbyte    = 0;       /* accumulates data bits                  */
    int         prev_lvl = 1;       /* previous level (idle = 1)              */
    int         stat_cnt = 0;       /* counter for status display             */
    float       last_dbfs = -99.0f;

    fprintf(stdout, "\n--- RX DECODED ---\n");
    fflush(stdout);

    while (g_running) {

        /* ── Refill DMA buffer ─────────────────────────────────────────── */
        ssize_t nb = iio_buffer_refill(buf);
        if (nb < 0) {
            fprintf(stderr, "\niio_buffer_refill error: %zd\n", nb);
            break;
        }

        /* ── Compute RMS of √(I²+Q²) over buffer ──────────────────────── */
        char     *p    = iio_buffer_first(buf, rx_i);
        char     *end  = iio_buffer_end(buf);
        ptrdiff_t step = iio_buffer_step(buf);
        double    ssq  = 0.0;
        long      nsmp = 0;

        while (p < end) {
            const int16_t *iq = (const int16_t *)p;
            float I = (float)iq[0], Q = (float)iq[1];
            ssq += (double)I*I + (double)Q*Q;
            nsmp++;
            p += step;
        }

        float rms  = sqrtf((float)(ssq / nsmp));
        float dbfs = 20.0f * log10f(rms / 32767.0f + 1e-10f);
        int   lvl  = (dbfs > OOK_THRESHOLD_DBFS) ? 1 : 0;
        last_dbfs  = dbfs;

        /* ── UART decoder state machine ────────────────────────────────── */
        switch (state) {

        case S_IDLE:
            /*
             * Wait for a falling edge: prev_lvl=1 (idle/ON) → lvl=0 (OFF).
             * That falling edge is the START BIT.
             */
            if (prev_lvl == 1 && lvl == 0) {
                buf_cnt = 0;
                state   = S_START;
            }
            break;

        case S_START:
            /*
             * We're in the start bit.  Wait OOK_HALF_BIT_BUF buffers (50 ms)
             * to land in the CENTRE of the start bit, then verify it's still 0.
             * Sampling the centre gives maximum noise immunity.
             */
            if (++buf_cnt == OOK_HALF_BIT_BUF) {
                if (lvl == 0) {
                    /* confirmed start bit — prepare to collect data bits */
                    buf_cnt = 0;
                    bit_cnt = 0;
                    dbyte   = 0;
                    state   = S_DATA;
                } else {
                    /* glitch, not a real start bit */
                    state = S_IDLE;
                }
            }
            break;

        case S_DATA:
            /*
             * Sample one bit every OOK_BIT_PERIOD_BUF buffers.
             * UART sends LSB first, so bit 0 arrives first.
             * We place each received bit into dbyte at the correct position.
             */
            if (++buf_cnt == OOK_BIT_PERIOD_BUF) {
                dbyte  |= (uint8_t)(lvl << bit_cnt);
                buf_cnt = 0;
                if (++bit_cnt == 8)
                    state = S_STOP;
            }
            break;

        case S_STOP:
            /*
             * Sample the stop bit.  It must be 1 (carrier ON).
             * If it is, dbyte is a valid received byte — print it.
             */
            if (++buf_cnt == OOK_BIT_PERIOD_BUF) {
                if (lvl == 1) {
                    /* Valid byte received */
                    char c = (char)dbyte;
                    if (c >= 32 && c < 127)
                        fprintf(stdout, "%c", c);
                    else if (c == '\n')
                        fprintf(stdout, "\n");
                    else
                        fprintf(stdout, "[%02X]", dbyte);
                    fflush(stdout);
                } else {
                    fprintf(stderr, "\n  [FRAME ERROR: stop=0, partial=0x%02X]\n",
                            dbyte);
                }
                state   = S_IDLE;
                buf_cnt = 0;
            }
            break;
        }

        prev_lvl = lvl;

        /* ── Status display (stderr) — every STATUS_INTERVAL buffers ───── */
        if (++stat_cnt >= STATUS_INTERVAL) {
            fprintf(stderr, "\r  [%s] %6.1f dBFS  %s  ",
                    state_name[state],
                    last_dbfs,
                    lvl ? "\033[32m▓▓▓\033[0m" : "\033[31m░░░\033[0m");
            fflush(stderr);
            stat_cnt = 0;
        }
    }

    fprintf(stdout, "\n--- END ---\n");
    fprintf(stderr, "\n\nStopped.\n");
    iio_buffer_destroy(buf);
    iio_context_destroy(ctx);
    return EXIT_SUCCESS;
}
