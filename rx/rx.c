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
 *  Our 1 ms decimated windows have 1 kHz bin spacing, so the tones land on
 *  exact bins 50 and 150.  No spectral leakage gives clean discrimination
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
 *  This revision makes one tone decision per 1 ms window and clocks the UART
 *  in those sample-time ticks.  Buffer return time is no longer the bit clock.
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

#define BUFFER_SAMPLES          23040   /* 10 ms at 2.304 Msps               */
#define WINDOWS_PER_BUFFER         10   /* ten 1 ms decisions per DMA block  */
#define WINDOW_INPUT_SAMPLES     2304   /* original ADC samples per 1 ms     */
#define DECIMATION_FACTOR           4   /* analyze every fourth ADC sample   */
#define WINDOW_ANALYSIS_SAMPLES   576   /* 2304 / 4                          */
#define ANALYSIS_SAMPLE_RATE  576000LL  /* 2.304 Msps / 4                    */
#define UART_BIT_TICKS             50   /* 50 × 1 ms = 50 ms                 */
#define UART_HALF_BIT_TICKS        25   /* sample at the bit centre          */
#define UART_MIN_IDLE_TICKS        15   /* reject edges without prior MARK   */
#define STATUS_INTERVAL_TICKS     500   /* status every 500 ms               */

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }
#define setup_signals() do { \
    signal(SIGINT,  on_signal); \
    signal(SIGTERM, on_signal); \
    signal(SIGHUP,  on_signal); \
} while (0)

typedef enum { S_IDLE, S_START, S_DATA, S_STOP } ook_state_t;
static const char *state_name[] = { "IDLE ", "START", "DATA ", "STOP " };

/* ── Frame-layer state machine ───────────────────────────────────────────
 *
 * Sits above the UART byte decoder.  Every time S_STOP delivers a valid
 * byte, on_byte() advances this machine:
 *
 *   HUNT → (≥ FRAME_PREAMBLE_MIN × 0x55) → PRE → (0xD5) → LEN → DATA
 *
 * Any unexpected byte in HUNT/PRE resets the preamble counter.
 * This ensures the receiver only prints data from properly framed
 * transmissions — noise and partial frames are silently discarded.
 */
typedef enum { FS_HUNT, FS_PRE, FS_LEN, FS_DATA } frame_state_t;
static const char *fs_name[]  = { "HUNT", "PRE ", "LEN ", "DATA" };

static frame_state_t fs_state = FS_HUNT;
static int           pre_cnt  = 0;
static int           data_len = 0;
static int           data_pos = 0;
static uint8_t       data_buf[256];

/* A broken UART byte also breaks the RF-frame byte sequence.  Do not let
 * preamble bytes collected before a framing error contribute to a later
 * (and therefore false) SYNC decision. */
static void frame_reset(void)
{
    fs_state = FS_HUNT;
    pre_cnt  = 0;
    data_len = 0;
    data_pos = 0;
}

static void on_byte(uint8_t byte)
{
    switch (fs_state) {

    case FS_HUNT:
    case FS_PRE:
        if (byte == FRAME_PREAMBLE_BYTE) {
            pre_cnt++;
            fprintf(stderr, "  [PRE ] 0x%02X  (%d / %d min)\n",
                    byte, pre_cnt, FRAME_PREAMBLE_MIN);
            if (pre_cnt >= FRAME_PREAMBLE_MIN)
                fs_state = FS_PRE;          /* ready to accept SYNC */
        } else if (byte == FRAME_SYNC_BYTE && pre_cnt >= FRAME_PREAMBLE_MIN) {
            fprintf(stderr, "  [SYNC] 0x%02X  — frame start\n", byte);
            fs_state = FS_LEN;
        } else {
            /* Unexpected byte — reset and keep hunting */
            if (pre_cnt > 0)
                fprintf(stderr, "  [DROP] 0x%02X  (preamble lost at %d)\n",
                        byte, pre_cnt);
            pre_cnt  = 0;
            fs_state = FS_HUNT;
        }
        break;

    case FS_LEN:
        data_len = (int)byte;
        data_pos = 0;
        fprintf(stderr, "  [LEN ] %d byte%s\n", data_len,
                data_len == 1 ? "" : "s");
        if (data_len > 0 && data_len <= (int)sizeof(data_buf) - 1)
            fs_state = FS_DATA;
        else {
            pre_cnt  = 0;
            fs_state = FS_HUNT;
        }
        break;

    case FS_DATA:
        data_buf[data_pos++] = byte;
        if (data_pos >= data_len) {
            data_buf[data_pos] = '\0';
            /* Decoded frame → stdout (clean, pipeable) */
            fprintf(stdout, ">>> %s", (char *)data_buf);
            if (data_buf[data_pos - 1] != '\n') fputc('\n', stdout);
            fflush(stdout);
            /* Reset for next frame */
            fs_state = FS_HUNT;
            pre_cnt  = 0;
        }
        break;
    }
}

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
                            float coefficient)
{
    float sI1 = 0.0f, sI2 = 0.0f;             /* IIR state for I channel */
    float sQ1 = 0.0f, sQ2 = 0.0f;             /* IIR state for Q channel */

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

    /* |X(k)|² for each channel, then sum */
    float pI = sI1*sI1 + sI2*sI2 - coefficient*sI1*sI2;
    float pQ = sQ1*sQ1 + sQ2*sQ2 - coefficient*sQ1*sQ2;
    return pI + pQ;
}

/* ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    setup_signals();

    fprintf(stderr,
        "\n== SDR_Link: 2-FSK Receiver / Decoder (Pluto+ / AD9361) ==\n\n");

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
     * In each 1 ms analysis window they land on exact bins 150 and 50.
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
            FSK_TONE_MARK_HZ * WINDOW_ANALYSIS_SAMPLES / ANALYSIS_SAMPLE_RATE);
    fprintf(stderr, "        SPACE bin : %.0f kHz  (Goertzel bin %lld)\n",
            FSK_TONE_SPACE_HZ / 1e3,
            FSK_TONE_SPACE_HZ * WINDOW_ANALYSIS_SAMPLES / ANALYSIS_SAMPLE_RATE);
    fprintf(stderr, "        Bit rate  : %d bps (%d ms/bit)\n",
            1000000 / FSK_BIT_PERIOD_US,
            FSK_BIT_PERIOD_US / 1000);
    fprintf(stderr, "        DSP       : 1 ms windows, decimate ×%d to %.0f ksps\n\n",
            DECIMATION_FACTOR, ANALYSIS_SAMPLE_RATE / 1000.0);

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
     * Each buffer iteration (10 ms) contains ten 1 ms decisions:
     *   1. Refill buffer (DMA from ADC)
     *   2. Split it into ten windows
     *   3. Retain every fourth sample in each window (576 ksps effective)
     *   4. Compare 150 kHz MARK and 50 kHz SPACE power
     *   5. Advance the UART clock by exactly one captured millisecond
     */
    fprintf(stderr, "[ 4/4 ] Listening for FSK on %.3f–%.3f MHz — Ctrl-C to stop.\n\n",
            (CARRIER_FREQ_HZ + FSK_TONE_SPACE_HZ) / 1e6,
            (CARRIER_FREQ_HZ + FSK_TONE_MARK_HZ) / 1e6);
    fprintf(stderr, "  [state]  ΔP (dB)   bit   ← positive=MARK='1', negative=SPACE='0'\n");
    fprintf(stderr, "  ─────────────────────────────────────────────────────────────\n");

    ook_state_t state    = S_IDLE;
    int         tick_cnt = 0;
    int         bit_cnt  = 0;
    uint8_t     dbyte    = 0;
    int         prev_lvl = 0;      /* 0 = SPACE, 1 = MARK; start at SPACE   */
    int         consec_hi = 0;     /* consecutive 1 ms MARK decisions        */
    int         stat_cnt  = 0;
    float       last_dp   = 0.0f;  /* last ΔP = 10·log10(P_mark/P_space) dB */
    int         last_lvl  = 0;

    fprintf(stderr, "  Frame format  : [0x55 × %d preamble] [0xD5 sync] [LEN] [DATA]\n",
            FRAME_PREAMBLE_MIN);
    fprintf(stderr, "  Status format : [UART state | frame state]  ΔP dB  bit  tone\n\n");
    fprintf(stderr, "  ─────────────────────────────────────────────────────────────\n");
    fflush(stderr);

    /* Frequencies and sample rate never change, so cosine belongs outside
     * the real-time loop.  Decimation by four changes the analysis rate but
     * not the physical tone frequencies. */
    const float mark_coeff = 2.0f * cosf(2.0f * (float)M_PI *
        (float)FSK_TONE_MARK_HZ / (float)ANALYSIS_SAMPLE_RATE);
    const float space_coeff = 2.0f * cosf(2.0f * (float)M_PI *
        (float)FSK_TONE_SPACE_HZ / (float)ANALYSIS_SAMPLE_RATE);

    while (g_running) {

        /* ── Refill DMA buffer ─────────────────────────────────────────── */
        ssize_t nb = iio_buffer_refill(buf);
        if (nb < 0) {
            fprintf(stderr, "\niio_buffer_refill error: %zd\n", nb);
            break;
        }

        /* ── Ten decimated 1 ms tone decisions ────────────────────────── */
        const char *base = iio_buffer_first(buf, rx_i);
        ptrdiff_t   step = iio_buffer_step(buf);

        for (int window = 0; window < WINDOWS_PER_BUFFER; window++) {
            const char *window_start =
                base + (ptrdiff_t)window * WINDOW_INPUT_SAMPLES * step;
            float pm = goertzel_power(window_start,
                                      step * DECIMATION_FACTOR,
                                      WINDOW_ANALYSIS_SAMPLES, mark_coeff);
            float ps = goertzel_power(window_start,
                                      step * DECIMATION_FACTOR,
                                      WINDOW_ANALYSIS_SAMPLES, space_coeff);
            int   lvl = (pm > ps) ? 1 : 0;
            float dp  = 10.0f * log10f((pm + 1e-10f) / (ps + 1e-10f));
            last_dp   = dp;
            last_lvl  = lvl;

            int prev_consec = consec_hi;
            if (lvl == 1) consec_hi++;
            else          consec_hi = 0;

            /* One pass through this switch represents exactly 1 ms of
             * captured RF time, regardless of ARM or SSH timing. */
            switch (state) {

        case S_IDLE:
            /*
             * Wait for MARK→SPACE falling edge.
             * Require prior MARK time so noise and mid-symbol edges cannot
             * re-trigger the decoder if a framing error drops us here.
             */
            if (prev_lvl == 1 && lvl == 0 &&
                prev_consec >= UART_MIN_IDLE_TICKS) {
                tick_cnt = 0;
                state   = S_START;
            }
            break;

        case S_START:
            /*
             * Confirm SPACE at the centre of the 50 ms start bit.  With 1 ms
             * windows, the uncertainty is about ±1 ms rather than ±10 ms.
             */
            if (++tick_cnt == UART_HALF_BIT_TICKS) {
                if (lvl == 0) {
                    tick_cnt = 0;  bit_cnt = 0;  dbyte = 0;
                    state   = S_DATA;
                } else {
                    state = S_IDLE;          /* glitch — abandon */
                }
            }
            break;

        case S_DATA:
            if (++tick_cnt == UART_BIT_TICKS) {
                dbyte  |= (uint8_t)(lvl << bit_cnt);
                tick_cnt = 0;
                if (++bit_cnt == 8)
                    state = S_STOP;
            }
            break;

        case S_STOP:
            /* Stop bit must be MARK ('1'). */
            if (++tick_cnt == UART_BIT_TICKS) {
                if (lvl == 1) {
                    /* Show the raw UART result even before the frame layer.
                     * Our present milestone is simply:
                     *   55 55 55 55 D5
                     */
                    fprintf(stderr, "  [UART] byte=0x%02X%s\n", dbyte,
                            dbyte == FRAME_PREAMBLE_BYTE ? "  PREAMBLE" :
                            dbyte == FRAME_SYNC_BYTE     ? "  SYNC" : "");
                    on_byte(dbyte);          /* pass to frame state machine */
                } else {
                    fprintf(stderr,
                            "\n  [UART ERR] stop=SPACE, partial=0x%02X\n",
                            dbyte);
                    frame_reset();
                }
                state   = S_IDLE;
                tick_cnt = 0;
            }
            break;
            }

            prev_lvl = lvl;

            if (++stat_cnt >= STATUS_INTERVAL_TICKS) {
                fprintf(stderr, "  [%s|%s]  %+7.1f dB  '%c'  %s\n",
                        state_name[state], fs_name[fs_state], last_dp,
                        last_lvl ? '1' : '0',
                        last_lvl ? "MARK " : "SPACE");
                fflush(stderr);
                stat_cnt = 0;
            }
        }
    }

    fprintf(stdout, "\n--- END ---\n");
    fprintf(stderr, "\n\nStopped.\n");
    iio_buffer_destroy(buf);
    iio_context_destroy(ctx);
    return EXIT_SUCCESS;
}
