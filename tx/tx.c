/*
 * tx.c — OOK (On-Off Keying) Transmitter
 * Runs on : Zedboard + FMCOMMS2/3 (AD9361)
 * Build   : make tx-build
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 1 — What is a radio carrier wave?
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  A radio wave is just a sine wave oscillating at very high frequency:
 *
 *    v(t) = A · cos(2π · f_carrier · t)
 *
 *  At 434 MHz this sine wave completes 434,000,000 cycles per second.
 *  We can't compute samples at 434 MHz directly — so radios use IQ baseband.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 2 — IQ baseband (recap)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  ANY RF signal can be described by two low-rate numbers I(t) and Q(t):
 *
 *    v(t) = I(t)·cos(2π·f_LO·t)  −  Q(t)·sin(2π·f_LO·t)
 *
 *  The AD9361 multiplies your I/Q samples by the LO internally (up-conversion).
 *  You only supply samples at 2.304 Msps; the chip handles the 434 MHz part.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 3 — DDS (recap)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  The FPGA DDS generates I(t) = cos(2π·f·t), Q(t) = sin(2π·f·t) in hardware.
 *  We toggle its amplitude (scale 0.9 ↔ 0.0) to encode bits.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 7 — On-Off Keying (OOK)
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  The simplest digital modulation:
 *
 *    bit = 1  →  DDS scale = 0.9  →  carrier radiates   (RF power ON)
 *    bit = 0  →  DDS scale = 0.0  →  carrier silent      (RF power OFF)
 *
 *  Over the air it looks like a morse-code envelope: the 434.020 MHz carrier
 *  is switched on and off at OOK_BIT_PERIOD_US intervals.
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 8 — UART framing over OOK
 * ════════════════════════════════════════════════════════════════════════════
 *
 *  We borrow the UART (serial port) frame format to package bytes:
 *
 *    [IDLE=1]···[START=0][b0][b1][b2][b3][b4][b5][b6][b7][STOP=1]···
 *
 *  Idle     : carrier ON  (line high — receiver knows "no data yet")
 *  Start bit: carrier OFF (falling edge — receiver aligns its clock here)
 *  Data bits: 8 bits, LSB first (b0 = bit0 of the byte)
 *  Stop bit : carrier ON  (line high — receiver confirms byte is done)
 *
 *  Each bit lasts OOK_BIT_PERIOD_US microseconds (100 ms = 10 bps here).
 *
 *  Example — 'H' = 0x48 = 0b01001000, LSB first = 0,0,0,1,0,0,1,0:
 *
 *    ‾‾‾‾|_____|‾|___|‾‾‾|‾‾‾‾‾‾
 *    idle  S  0 0 0 1 0 0 1 0  P
 *              └── b0 ──────────┘
 *    S=start(0)  P=stop(1)
 */

#define _DEFAULT_SOURCE         /* expose usleep() under -std=c11 */

#include <iio.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../common/rf_params.h"

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }

/* ── DDS on/off — toggles carrier by changing amplitude scale ───────────── */
static void carrier_on(struct iio_channel *di, struct iio_channel *dq)
{
    iio_channel_attr_write_double(di, "scale", 0.9);
    iio_channel_attr_write_double(dq, "scale", 0.9);
}

static void carrier_off(struct iio_channel *di, struct iio_channel *dq)
{
    iio_channel_attr_write_double(di, "scale", 0.0);
    iio_channel_attr_write_double(dq, "scale", 0.0);
}

static void send_bit(int bit, struct iio_channel *di, struct iio_channel *dq)
{
    if (bit) carrier_on(di, dq);
    else     carrier_off(di, dq);
    usleep(OOK_BIT_PERIOD_US);
}

/* UART frame: start(0), 8 data bits LSB first, stop(1) */
static void send_byte(unsigned char c,
                      struct iio_channel *di, struct iio_channel *dq)
{
    send_bit(0, di, dq);                        /* start bit */
    for (int i = 0; i < 8; i++)
        send_bit((c >> i) & 1, di, dq);
    send_bit(1, di, dq);                        /* stop bit  */
}

/* ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════╗\n"
        "║  SDR_Link — OOK Transmitter (Zedboard + AD9361)          ║\n"
        "╚══════════════════════════════════════════════════════════╝\n\n");

    /* ── Step 1: Open the local IIO context ──────────────────────────────── */
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
    fprintf(stderr, "        Bandwidth : %lld kHz\n", RF_BANDWIDTH_HZ / 1000);
    fprintf(stderr, "        TX power  : -%d dB\n\n", TX_ATTENUATION_MDB / 1000);

    /* ── Step 3: Configure hardware DDS ─────────────────────────────────── */
    fprintf(stderr, "[ 3/4 ] Configuring DDS...\n");
    struct iio_device *dds = iio_context_find_device(ctx, TX_DDS_DEVICE);
    if (!dds) {
        fprintf(stderr, "ERROR: %s not found\n", TX_DDS_DEVICE);
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_channel *dds_i = iio_device_find_channel(dds, "altvoltage0", true);
    struct iio_channel *dds_q = iio_device_find_channel(dds, "altvoltage2", true);
    if (!dds_i || !dds_q) {
        fprintf(stderr, "ERROR: DDS tone channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    iio_channel_attr_write_longlong(dds_i, "frequency", DDS_TONE_OFFSET_HZ);
    iio_channel_attr_write_longlong(dds_q, "frequency", DDS_TONE_OFFSET_HZ);
    iio_channel_attr_write_longlong(dds_i, "phase",     0);
    iio_channel_attr_write_longlong(dds_q, "phase",     90000);
    iio_channel_attr_write_longlong(dds_i, "raw",       1);
    iio_channel_attr_write_longlong(dds_q, "raw",       1);

    fprintf(stderr, "        Tone      : %.3f MHz\n", TONE_FREQ_HZ / 1e6);
    fprintf(stderr, "        Bit rate  : %d bps (%d ms/bit)\n\n",
            1000000 / OOK_BIT_PERIOD_US, OOK_BIT_PERIOD_US / 1000);

    /* ── Step 4: OOK transmission loop ──────────────────────────────────────
     *
     * Idle = carrier ON (1).  Each character is UART-framed:
     *   start(0) + 8 data bits LSB-first + stop(1)
     * After the full message: 2 s of carrier OFF, then repeat.
     *
     * The stderr log prints the bit pattern for each character so you can
     * cross-check it against what the RX decodes.
     */
    fprintf(stderr, "[ 4/4 ] Transmitting OOK — press Ctrl-C to stop.\n\n");

    carrier_on(dds_i, dds_q);          /* line idle = high */

    int msg_num = 0;
    while (g_running) {
        fprintf(stderr, "── TX msg #%d ──────────────────────────────\n", ++msg_num);

        for (const char *p = OOK_MESSAGE; *p && g_running; p++) {
            unsigned char c = (unsigned char)*p;

            /* print the UART frame we're about to send */
            fprintf(stderr, "  '%c' 0x%02X  [0|", (c >= 32 && c < 127) ? c : '.', c);
            for (int i = 0; i < 8; i++)
                fprintf(stderr, "%d", (c >> i) & 1);
            fprintf(stderr, "|1]  %d ms\n",
                    10 * OOK_BIT_PERIOD_US / 1000);

            send_byte(c, dds_i, dds_q);
        }

        /* 2-second inter-message gap: carrier OFF */
        fprintf(stderr, "  [2 s gap]\n\n");
        carrier_off(dds_i, dds_q);
        for (int i = 0; i < 20 && g_running; i++)
            usleep(100000);
        carrier_on(dds_i, dds_q);      /* return to idle */
    }

    /* ── Shutdown ─────────────────────────────────────────────────────────── */
    carrier_off(dds_i, dds_q);
    iio_channel_attr_write_longlong(dds_i, "raw", 0);
    iio_channel_attr_write_longlong(dds_q, "raw", 0);
    iio_context_destroy(ctx);
    fprintf(stderr, "\nStopped.\n");
    return EXIT_SUCCESS;
}
