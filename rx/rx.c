/*
 * rx.c — 2-FSK Receiver / UART Decoder
 * Runs on : ADALM-PLUTO+ (AD9361)
 * Build   : cross-compile from laptop (see Makefile)
 * Run     : /tmp/rx
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 9 — FSK demodulation: frequency, not amplitude
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  OOK decision: is the amplitude above a threshold?
 *  FSK decision: which of two frequencies has more power?
 *
 *    P_mark  = power at 150 kHz  (MARK,  bit '1')
 *    P_space = power at  50 kHz  (SPACE, bit '0')
 *
 *    if P_mark > P_space  → bit = 1
 *    else                 → bit = 0
 *
 *  No threshold to tune.  The decision is relative, so amplitude fading
 *  and gain changes are irrelevant — both frequencies fade equally.
 *
 *  RX LO = CARRIER_FREQ_HZ (433.920 MHz, same as TX LO).
 *  After mixing: MARK lands at 150 kHz baseband, SPACE at 50 kHz baseband.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 10 — Goertzel algorithm: single-frequency DFT
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  We need power at exactly two frequencies.  A full FFT computes all N/2
 *  bins — wasteful.  The Goertzel algorithm computes the DFT at ONE target
 *  frequency in O(N) time, with only two trig operations (not N):
 *
 *    ω  = 2π × f_target / f_s
 *    coeff = 2 cos(ω)          ← computed once
 *
 *    For each sample x[n]:
 *      s[n] = coeff × s[n-1]  −  s[n-2]  +  x[n]     (IIR recursion)
 *
 *    After N samples:
 *      |X(k)|²  =  s[N-1]² + s[N-2]² − coeff × s[N-1] × s[N-2]
 *
 *  This is identical to the DFT at bin k = f_target × N / f_s.
 *
 *  Our tones land on EXACT bins (bin 500 for 50 kHz, bin 1500 for 150 kHz,
 *  since f_s/N = 2304000/23040 = 100 Hz).  No spectral leakage → perfect
 *  discrimination between MARK and SPACE.
 *
 *  We run Goertzel on I and Q separately and sum the powers.  For a
 *  single-sideband complex tone, both channels carry equal power and
 *  the sum gives the correct total.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 8 — UART framing decoder (unchanged from OOK)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  [IDLE=MARK]···[START=SPACE][b0]···[b7][STOP=MARK]···
 *
 *  Edge detection: MARK→SPACE  =  start bit.
 *  Half-bit centering + bit-period sampling — same state machine as OOK,
 *  now with FSK_BIT_PERIOD_BUF = 2 (20 ms/bit = 50 bps).
 */

#define _DEFAULT_SOURCE         /* expose M_PI under -std=c11 */

#include <iio.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../common/rf_params.h"

#define BUFFER_SAMPLES   23040          /* 10 ms at 2.304 Msps               */
#define STATUS_INTERVAL  50             /* print status every 50 buf = 500 ms */

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }

typedef enum { S_IDLE, S_START, S_DATA, S_STOP } ook_state_t;
static const char *state_name[] = { "IDLE ", "START", "DATA ", "STOP " };

/* ── Goertzel: power at target_hz in one IQ buffer ─────────────────────────
 *
 * base : pointer to first IQ sample  (from iio_buffer_first)
 * step : bytes between samples       (from iio_buffer_step, = 4 for int16 IQ)
 * n    : number of IQ pairs
 *
 * Memory layout: [I_lo I_hi Q_lo Q_hi][I_lo I_hi Q_lo Q_hi]...
 * I = *(int16_t *)(ptr + 0),  Q = *(int16_t *)(ptr + 2)
 */
static float goertzel_power(const char *base, ptrdiff_t step, int n,
                             float target_hz, float sample_rate)
{
    float omega = 2.0f * (float)M_PI * target_hz / sample_rate;
    float coeff = 2.0f * cosf(omega);          /* computed once per call */

    float sI1 = 0.0f, sI2 = 0.0f;             /* IIR state for I channel */
    float sQ1 = 0.0f, sQ2 = 0.0f;             /* IIR state for Q channel */

    const char *p = base;
    for (int i = 0; i < n; i++, p += step) {
        const int16_t *iq = (const int16_t *)p;
        float I = (float)iq[0];
        float Q = (float)iq[1];

        float sI0 = coeff * sI1 - sI2 + I;
        sI2 = sI1;  sI1 = sI0;

        float sQ0 = coeff * sQ1 - sQ2 + Q;
        sQ2 = sQ1;  sQ1 = sQ0;
    }

    /* |X(k)|² for each channel, then sum */
    float pI = sI1*sI1 + sI2*sI2 - coeff*sI1*sI2;
    float pQ = sQ1*sQ1 + sQ2*sQ2 - coeff*sQ1*sQ2;
    return pI + pQ;
}

/* ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════╗\n"
        "║  SDR_Link — 2-FSK Receiver / Decoder (Pluto+ / AD9361)   ║\n"
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
     * RX LO = CARRIER_FREQ_HZ (433.920 MHz) — same as TX LO.
     * After down-conversion:
     *   MARK  (434.070 MHz)  →  150 kHz in baseband
     *   SPACE (433.970 MHz)  →   50 kHz in baseband
     * Both land on exact Goertzel bins (bin 1500 and bin 500).
     */
    iio_channel_attr_write_longlong(lo_rx,  "frequency",          CARRIER_FREQ_HZ);
    iio_channel_attr_write_longlong(rx_phy, "rf_bandwidth",       RF_BANDWIDTH_HZ);
    iio_channel_attr_write_longlong(rx_phy, "sampling_frequency", SAMPLE_RATE_HZ);

    /* Manual gain: FSK doesn't care about amplitude, but fixed gain keeps
     * the Goertzel values in a stable range for display purposes.         */
    iio_channel_attr_write(rx_phy, "gain_control_mode", "manual");
    iio_channel_attr_write_longlong(rx_phy, "hardwaregain", 40);

    fprintf(stderr, "        RX LO     : %.3f MHz  (= TX LO)\n",
            CARRIER_FREQ_HZ / 1e6);
    fprintf(stderr, "        MARK bin  : %.0f kHz  (Goertzel bin %lld)\n",
            FSK_TONE_MARK_HZ / 1e3,
            FSK_TONE_MARK_HZ * BUFFER_SAMPLES / SAMPLE_RATE_HZ);
    fprintf(stderr, "        SPACE bin : %.0f kHz  (Goertzel bin %lld)\n",
            FSK_TONE_SPACE_HZ / 1e3,
            FSK_TONE_SPACE_HZ * BUFFER_SAMPLES / SAMPLE_RATE_HZ);
    fprintf(stderr, "        Bit rate  : %d bps (%d ms/bit, %d buf/bit)\n\n",
            1000000 / FSK_BIT_PERIOD_US,
            FSK_BIT_PERIOD_US / 1000,
            FSK_BIT_PERIOD_BUF);

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
    fprintf(stderr, "        Buffer    : %d IQ samples (%.0f ms)\n\n",
            BUFFER_SAMPLES, 1000.0 * BUFFER_SAMPLES / SAMPLE_RATE_HZ);

    /* ── Step 4: FSK decoder loop ────────────────────────────────────────
     *
     * Each buffer iteration (10 ms):
     *   1. Refill buffer (DMA from ADC)
     *   2. Goertzel at 150 kHz → P_mark
     *   3. Goertzel at  50 kHz → P_space
     *   4. lvl = (P_mark > P_space) ? 1 : 0
     *   5. UART state machine — identical to OOK version
     */
    fprintf(stderr, "[ 4/4 ] Listening for FSK on %.3f–%.3f MHz — Ctrl-C to stop.\n\n",
            (CARRIER_FREQ_HZ + FSK_TONE_SPACE_HZ) / 1e6,
            (CARRIER_FREQ_HZ + FSK_TONE_MARK_HZ) / 1e6);
    fprintf(stderr, "  [state]  ΔP (dB)   bit   ← positive=MARK='1', negative=SPACE='0'\n");
    fprintf(stderr, "  ─────────────────────────────────────────────────────────────\n");

    ook_state_t state    = S_IDLE;
    int         buf_cnt  = 0;
    int         bit_cnt  = 0;
    uint8_t     dbyte    = 0;
    int         prev_lvl = 0;      /* 0 = SPACE, 1 = MARK; start at SPACE   */
    int         consec_hi = 0;     /* consecutive MARK buffers               */
    int         stat_cnt  = 0;
    float       last_dp   = 0.0f;  /* last ΔP = 10·log10(P_mark/P_space) dB */
    int         last_lvl  = 0;

    fprintf(stdout, "\n--- RX DECODED ---\n");
    fflush(stdout);

    while (g_running) {

        /* ── Refill DMA buffer ─────────────────────────────────────────── */
        ssize_t nb = iio_buffer_refill(buf);
        if (nb < 0) {
            fprintf(stderr, "\niio_buffer_refill error: %zd\n", nb);
            break;
        }

        /* ── Goertzel at both FSK tones ────────────────────────────────── */
        const char *base = iio_buffer_first(buf, rx_i);
        ptrdiff_t   step = iio_buffer_step(buf);

        float pm = goertzel_power(base, step, BUFFER_SAMPLES,
                                  (float)FSK_TONE_MARK_HZ,  (float)SAMPLE_RATE_HZ);
        float ps = goertzel_power(base, step, BUFFER_SAMPLES,
                                  (float)FSK_TONE_SPACE_HZ, (float)SAMPLE_RATE_HZ);

        /*
         * Frequency decision: which tone is louder?
         * The 1e-10 guard prevents log10(0) on pure silence.
         */
        int   lvl = (pm > ps) ? 1 : 0;
        float dp  = 10.0f * log10f(pm / (ps + 1e-10f));   /* ΔP in dB */
        last_dp   = dp;
        last_lvl  = lvl;

        /* ── Consecutive MARK counter (for start-bit guard) ────────────── */
        int prev_consec = consec_hi;
        if (lvl == 1) consec_hi++;
        else          consec_hi = 0;

        /* ── UART decoder state machine ────────────────────────────────── */
        switch (state) {

        case S_IDLE:
            /*
             * Wait for MARK→SPACE falling edge.
             * Require FSK_MIN_IDLE_BUF consecutive MARK buffers first so
             * mid-data MARK bits (which are only 2 buffers long) cannot
             * re-trigger the decoder if a framing error drops us here.
             */
            if (prev_lvl == 1 && lvl == 0 && prev_consec >= FSK_MIN_IDLE_BUF) {
                buf_cnt = 0;
                state   = S_START;
            }
            break;

        case S_START:
            /* Wait half a bit (1 buffer = 10 ms) to land in the centre.  */
            if (++buf_cnt == FSK_HALF_BIT_BUF) {
                if (lvl == 0) {
                    buf_cnt = 0;  bit_cnt = 0;  dbyte = 0;
                    state   = S_DATA;
                } else {
                    state = S_IDLE;          /* glitch — abandon */
                }
            }
            break;

        case S_DATA:
            /* Sample one bit every FSK_BIT_PERIOD_BUF buffers (= 20 ms). */
            if (++buf_cnt == FSK_BIT_PERIOD_BUF) {
                dbyte  |= (uint8_t)(lvl << bit_cnt);
                buf_cnt = 0;
                if (++bit_cnt == 8)
                    state = S_STOP;
            }
            break;

        case S_STOP:
            /* Stop bit must be MARK ('1'). */
            if (++buf_cnt == FSK_BIT_PERIOD_BUF) {
                if (lvl == 1) {
                    char c = (char)dbyte;
                    if (c >= 32 && c < 127)  fprintf(stdout, "%c", c);
                    else if (c == '\n')       fprintf(stdout, "\n");
                    else                      fprintf(stdout, "[%02X]", dbyte);
                    fflush(stdout);
                } else {
                    fprintf(stderr,
                            "\n  [FRAME ERROR: stop=SPACE, partial=0x%02X]\n",
                            dbyte);
                }
                state   = S_IDLE;
                buf_cnt = 0;
            }
            break;
        }

        prev_lvl = lvl;

        /* ── Status display every STATUS_INTERVAL buffers (500 ms) ─────── */
        if (++stat_cnt >= STATUS_INTERVAL) {
            fprintf(stderr, "  [%s]  %+7.1f dB  '%c'  %s\n",
                    state_name[state],
                    last_dp,
                    last_lvl ? '1' : '0',
                    last_lvl ? "\033[32mMARK \033[0m" : "\033[33mSPACE\033[0m");
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
