/*
 * tx.c — 2-FSK Transmitter
 * Runs on : Zedboard + FMCOMMS2/3 (AD9361)
 * Build   : make tx-build
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 9 — Frequency Shift Keying (FSK)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  In OOK we turned the carrier ON/OFF.  The receiver had to detect whether
 *  the carrier was present — simple, but fragile: amplitude fading, AGC
 *  hunting, and path-loss changes all corrupt the decision.
 *
 *  FSK is different: the carrier is ALWAYS present; we only shift its
 *  frequency between two values:
 *
 *    bit '1' → MARK  : LO + 150 kHz  =  434.070 MHz
 *    bit '0' → SPACE : LO +  50 kHz  =  433.970 MHz
 *
 *  The receiver asks "which frequency is louder?" — not "how loud?".
 *  Amplitude variations (fading, distance changes) don't matter at all,
 *  because we're comparing two frequencies in the same channel at the
 *  same time.  This is why FM radio sounds clean even at the edge of
 *  coverage, while AM fades.
 *
 *  Naming convention (inherited from landline modems):
 *    MARK  = '1'  (the "marking" state — idle and stop bits)
 *    SPACE = '0'  (the "spacing" state — start bits)
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 10 — How we generate two tones with the AD9361 DDS
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  The FPGA DDS has two independent tone generators per I/Q path:
 *    F1 (altvoltage0 / altvoltage2) — we assign to MARK  (150 kHz)
 *    F2 (altvoltage1 / altvoltage3) — we assign to SPACE ( 50 kHz)
 *
 *  To transmit MARK:  set F1 scale=0.9, F2 scale=0.0
 *  To transmit SPACE: set F1 scale=0.0, F2 scale=0.9
 *
 *  We always silence the outgoing tone before enabling the incoming one
 *  to avoid a brief moment where both tones overlap.  The four IIO sysfs
 *  writes take ~4 ms total — comfortably inside the 50 ms bit period.
 *
 *  Phase continuity: the DDS free-runs even when scale=0; on re-enable
 *  it resumes at whatever phase it reached — so each bit transition has
 *  a random phase jump.  This causes a small spectral splatter at 50 Hz
 *  intervals.  For an educational lab link it's irrelevant.  Real-world
 *  FSK (MSK / GMSK) maintains continuous phase across transitions.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 8 — UART framing (unchanged from OOK)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  [IDLE=MARK]···[START=SPACE][b0][b1]···[b7][STOP=MARK]···
 *
 *  Idle and stop = MARK ('1').  Start = SPACE ('0').
 *  Bit rate: FSK_BIT_PERIOD_US µs per bit = 20 bps.
 */

#define _DEFAULT_SOURCE

#include <iio.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../common/rf_params.h"

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }

/* ── Tone switching ─────────────────────────────────────────────────────────
 * Always silence the departing tone FIRST to avoid momentary dual-tone.     */

static void tone_mark(struct iio_channel *f1i, struct iio_channel *f1q,
                      struct iio_channel *f2i, struct iio_channel *f2q)
{
    iio_channel_attr_write_double(f2i, "scale", 0.0);
    iio_channel_attr_write_double(f2q, "scale", 0.0);
    iio_channel_attr_write_double(f1i, "scale", 0.9);
    iio_channel_attr_write_double(f1q, "scale", 0.9);
}

static void tone_space(struct iio_channel *f1i, struct iio_channel *f1q,
                       struct iio_channel *f2i, struct iio_channel *f2q)
{
    iio_channel_attr_write_double(f1i, "scale", 0.0);
    iio_channel_attr_write_double(f1q, "scale", 0.0);
    iio_channel_attr_write_double(f2i, "scale", 0.9);
    iio_channel_attr_write_double(f2q, "scale", 0.9);
}

/* Advance absolute deadline by us microseconds. */
static void ts_add_us(struct timespec *ts, long us)
{
    ts->tv_nsec += us * 1000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_nsec -= 1000000000L;
        ts->tv_sec++;
    }
}

/*
 * Set tone and sleep until the absolute deadline *next, then advance *next
 * by one bit period.  Because the deadline is absolute (not relative to
 * "now"), any time spent in IIO writes is subtracted from the sleep — the
 * bit period seen by the receiver stays exactly FSK_BIT_PERIOD_US regardless
 * of how long the four sysfs writes take.
 */
static void send_bit(int bit, struct timespec *next,
                     struct iio_channel *f1i, struct iio_channel *f1q,
                     struct iio_channel *f2i, struct iio_channel *f2q)
{
    if (bit) tone_mark (f1i, f1q, f2i, f2q);
    else     tone_space(f1i, f1q, f2i, f2q);
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, next, NULL);
    ts_add_us(next, FSK_BIT_PERIOD_US);
}

/* UART frame: start(SPACE=0), 8 data bits LSB first, stop(MARK=1) */
static void send_byte(uint8_t c, struct timespec *next,
                      struct iio_channel *f1i, struct iio_channel *f1q,
                      struct iio_channel *f2i, struct iio_channel *f2q)
{
    send_bit(0, next, f1i, f1q, f2i, f2q);     /* start: SPACE */
    for (int i = 0; i < 8; i++)
        send_bit((c >> i) & 1, next, f1i, f1q, f2i, f2q);
    send_bit(1, next, f1i, f1q, f2i, f2q);     /* stop:  MARK  */
}

/* ── RF frame: [0x55 × N] [0xD5] [LEN] [DATA ...] ──────────────────────────
 *
 * Preamble (0x55 = 01010101):
 *   Each byte alternates MARK/SPACE on every bit — both FSK tones are
 *   exercised repeatedly, giving the receiver AGC time to settle and
 *   the bit-clock time to align before any data arrives.
 *
 * SYNC (0xD5 = 11010101):
 *   Identical to the preamble byte except bit 7 is '1' instead of '0'.
 *   It can only appear after a complete preamble sequence, so it is
 *   unambiguous as a start-of-frame marker.
 *
 * LEN: 1-byte count of data bytes that follow.
 */
static void send_frame(const char *data, uint8_t len, struct timespec *next,
                       struct iio_channel *f1i, struct iio_channel *f1q,
                       struct iio_channel *f2i, struct iio_channel *f2q)
{
    fprintf(stderr, "  [PREAMBLE] %d × 0x%02X\n",
            FRAME_PREAMBLE_CNT, FRAME_PREAMBLE_BYTE);
    for (int i = 0; i < FRAME_PREAMBLE_CNT; i++)
        send_byte(FRAME_PREAMBLE_BYTE, next, f1i, f1q, f2i, f2q);

    fprintf(stderr, "  [SYNC    ] 0x%02X\n", FRAME_SYNC_BYTE);
    send_byte(FRAME_SYNC_BYTE, next, f1i, f1q, f2i, f2q);

    fprintf(stderr, "  [LEN     ] %u\n", len);
    send_byte(len, next, f1i, f1q, f2i, f2q);

    fprintf(stderr, "  [DATA    ] \"");
    for (uint8_t i = 0; i < len; i++) {
        uint8_t c = (uint8_t)data[i];
        fprintf(stderr, "%c", (c >= 32 && c < 127) ? (char)c : '.');
        send_byte(c, next, f1i, f1q, f2i, f2q);
    }
    fprintf(stderr, "\"\n");
}

/* ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════╗\n"
        "║  SDR_Link — 2-FSK Transmitter (Zedboard + AD9361)        ║\n"
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
    if (!phy) {
        fprintf(stderr, "ERROR: %s not found\n", PHY_DEVICE);
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_channel *lo_tx  = iio_device_find_channel(phy, "altvoltage1", true);
    struct iio_channel *tx_phy = iio_device_find_channel(phy, "voltage0",    true);
    if (!lo_tx || !tx_phy) {
        fprintf(stderr, "ERROR: TX PHY channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    iio_channel_attr_write_longlong(lo_tx,  "frequency",          CARRIER_FREQ_HZ);
    iio_channel_attr_write_longlong(tx_phy, "rf_bandwidth",       RF_BANDWIDTH_HZ);
    iio_channel_attr_write_longlong(tx_phy, "sampling_frequency", SAMPLE_RATE_HZ);
    iio_channel_attr_write_longlong(tx_phy, "hardwaregain",       -TX_ATTENUATION_MDB / 1000);

    fprintf(stderr, "        LO        : %.3f MHz\n", CARRIER_FREQ_HZ / 1e6);
    fprintf(stderr, "        MARK      : %.3f MHz  (bit '1', +150 kHz)\n",
            (CARRIER_FREQ_HZ + FSK_TONE_MARK_HZ) / 1e6);
    fprintf(stderr, "        SPACE     : %.3f MHz  (bit '0',  +50 kHz)\n",
            (CARRIER_FREQ_HZ + FSK_TONE_SPACE_HZ) / 1e6);
    fprintf(stderr, "        Bit rate  : %d bps (%d ms/bit)\n\n",
            1000000 / FSK_BIT_PERIOD_US, FSK_BIT_PERIOD_US / 1000);

    /* ── Step 3: Configure DDS — two tones, F1=MARK, F2=SPACE ──────────── */
    fprintf(stderr, "[ 3/4 ] Configuring DDS (F1=MARK, F2=SPACE)...\n");
    struct iio_device *dds = iio_context_find_device(ctx, TX_DDS_DEVICE);
    if (!dds) {
        fprintf(stderr, "ERROR: %s not found\n", TX_DDS_DEVICE);
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    /* F1: MARK at 150 kHz — I=altvoltage0 (0°), Q=altvoltage2 (90°) */
    struct iio_channel *f1i = iio_device_find_channel(dds, "altvoltage0", true);
    struct iio_channel *f1q = iio_device_find_channel(dds, "altvoltage2", true);
    /* F2: SPACE at  50 kHz — I=altvoltage1 (0°), Q=altvoltage3 (90°) */
    struct iio_channel *f2i = iio_device_find_channel(dds, "altvoltage1", true);
    struct iio_channel *f2q = iio_device_find_channel(dds, "altvoltage3", true);
    if (!f1i || !f1q || !f2i || !f2q) {
        fprintf(stderr, "ERROR: DDS channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    /* Frequencies and phases (phase in millidegrees) */
    iio_channel_attr_write_longlong(f1i, "frequency", FSK_TONE_MARK_HZ);
    iio_channel_attr_write_longlong(f1q, "frequency", FSK_TONE_MARK_HZ);
    iio_channel_attr_write_longlong(f1i, "phase",     0);
    iio_channel_attr_write_longlong(f1q, "phase",     90000);

    iio_channel_attr_write_longlong(f2i, "frequency", FSK_TONE_SPACE_HZ);
    iio_channel_attr_write_longlong(f2q, "frequency", FSK_TONE_SPACE_HZ);
    iio_channel_attr_write_longlong(f2i, "phase",     0);
    iio_channel_attr_write_longlong(f2q, "phase",     90000);

    /* Enable all four DDS outputs (scale controls which is active) */
    iio_channel_attr_write_longlong(f1i, "raw", 1);
    iio_channel_attr_write_longlong(f1q, "raw", 1);
    iio_channel_attr_write_longlong(f2i, "raw", 1);
    iio_channel_attr_write_longlong(f2q, "raw", 1);

    fprintf(stderr, "        F1 (MARK) : %lld kHz  I=altv0 Q=altv2\n",
            FSK_TONE_MARK_HZ / 1000);
    fprintf(stderr, "        F2 (SPACE): %lld kHz  I=altv1 Q=altv3\n\n",
            FSK_TONE_SPACE_HZ / 1000);

    /* ── Step 4: Transmit loop ───────────────────────────────────────────
     *
     * Idle = MARK ('1').  Each character uses UART framing:
     *   SPACE start bit + 8 data bits + MARK stop bit.
     * Inter-message gap: stay at MARK (idle high — same as OOK lesson).
     */
    fprintf(stderr, "[ 4/4 ] Transmitting FSK — press Ctrl-C to stop.\n\n");

    tone_mark(f1i, f1q, f2i, f2q);     /* idle = MARK */
    usleep(500000);                     /* 500 ms so RX locks before first bit */

    int msg_num = 0;
    while (g_running) {
        fprintf(stderr, "── TX frame #%d ─────────────────────────────\n", ++msg_num);

        /* Anchor the absolute bit-clock to now + one bit period.
         * send_bit() sleeps to this absolute deadline so IIO write latency
         * does not accumulate — each bit starts exactly FSK_BIT_PERIOD_US
         * after the previous, regardless of how long the DDS writes took. */
        struct timespec next;
        clock_gettime(CLOCK_MONOTONIC, &next);
        ts_add_us(&next, FSK_BIT_PERIOD_US);

        const char *msg = FSK_MESSAGE;
        send_frame(msg, (uint8_t)strlen(msg), &next, f1i, f1q, f2i, f2q);

        /* Inter-frame gap: stay at MARK (UART idle = '1') */
        fprintf(stderr, "  [2.5 s idle at MARK]\n\n");
        for (int i = 0; i < 25 && g_running; i++)
            usleep(100000);
    }

    /* ── Shutdown ─────────────────────────────────────────────────────── */
    iio_channel_attr_write_longlong(f1i, "raw", 0);
    iio_channel_attr_write_longlong(f1q, "raw", 0);
    iio_channel_attr_write_longlong(f2i, "raw", 0);
    iio_channel_attr_write_longlong(f2q, "raw", 0);
    iio_context_destroy(ctx);
    fprintf(stderr, "\nStopped.\n");
    return EXIT_SUCCESS;
}
