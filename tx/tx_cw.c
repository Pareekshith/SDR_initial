/*
 * tx_cw.c  –  Step 1: software-generated CW tone via IIO DMA buffer
 * Runs on : ZedBoard + FMCOMMS2/3 (AD9361)
 * Build   : make tx-cw-build
 * Verify  : run make rx-run on Pluto+ — should show same ~−37 dBFS as OOK
 *
 * ════════════════════════════════════════════════════════════════════════════
 * LESSON 11 — From DDS to DMA: you own the waveform now
 * ════════════════════════════════════════════════════════════════════════════
 *
 * Every previous lesson used the DDS hardware to generate a tone. We only
 * flicked register knobs ("set frequency to X", "set scale to 0.9"). The
 * FPGA produced the samples; we just configured it.
 *
 * The DMA path flips this: WE write every I and Q sample, and the hardware
 * plays exactly what we hand it. This single change unlocks every modulation
 * scheme that exists — GMSK, OFDM, BPSK, FHSS — because we are now the
 * waveform generator. The AD9361 just converts our numbers to RF.
 *
 * ── What a sample buffer looks like in memory ─────────────────────────────
 *
 *   The AD9361 DAC expects a stream of complex (IQ) samples at SAMPLE_RATE_HZ.
 *   Each complex sample is two int16 values packed together:
 *
 *     bytes:   [ I₀lo I₀hi Q₀lo Q₀hi | I₁lo I₁hi Q₁lo Q₁hi | ... ]
 *   as int16:  [    I₀      Q₀      |    I₁      Q₁      | ... ]
 *
 *   Full scale = ±32767. The FPGA feeds these into the AD9361 DAC, which
 *   multiplies with the LO. The received frequency is LO + f_baseband.
 *
 * ── Generating a single tone in IQ ───────────────────────────────────────
 *
 *   A baseband tone at frequency f is a rotating phasor:
 *
 *     I[n] = A · cos(2π · f · n / fs)      ← real part
 *     Q[n] = A · sin(2π · f · n / fs)      ← imaginary part
 *
 *   This is the Euler relation:  I + jQ = A · e^{jωn},  ω = 2πf/fs
 *
 *   The phasor rotates counter-clockwise in the IQ plane at rate f.
 *   After the AD9361 upconverter it appears at LO + f over the air.
 *
 *   We use f = 100 kHz, same as the OOK/FSK TONE_FREQ_HZ offset,
 *   so the Pluto+ RX reads the same power level — easy comparison.
 *
 * ── Cyclic vs normal buffer ───────────────────────────────────────────────
 *
 *   Normal  (cyclic=false): hardware plays the buffer ONCE and stops.
 *     CPU must push another buffer before the DAC underflows.
 *     For 2.304 Msps × 10 ms = 23040 samples: push every 10 ms. Tight.
 *
 *   Cyclic  (cyclic=true):  hardware loops the DMA descriptor forever.
 *     Push ONCE, tone plays until you destroy the buffer. No CPU overhead.
 *     Perfect for a CW carrier or any periodic waveform.
 *
 *   Rule of thumb: use cyclic for periodic signals (tones, pilot carriers),
 *   normal for data streams (FSK, GMSK, OFDM) where each buffer differs.
 *
 * ── Why 23040 samples? ────────────────────────────────────────────────────
 *
 *   DFT bin width = fs / N = 2304000 / 23040 = 100 Hz exactly.
 *   Every multiple of 100 Hz lands on an exact DFT bin.
 *
 *   This buffer length works cleanly for ALL three FSK-related tones:
 *     50 kHz  → bin  500 →  500 complete cycles  (SPACE tone)
 *    100 kHz  → bin 1000 → 1000 complete cycles  (OOK/DDS offset)
 *    150 kHz  → bin 1500 → 1500 complete cycles  (MARK tone  ← we use this)
 *
 *   A tone on an exact DFT bin produces ZERO sidelobes into adjacent bins
 *   (DFT orthogonality). This is why a 100 kHz CW tone contributes exactly
 *   zero power to the 50 kHz and 150 kHz FSK Goertzel filters — the FSK
 *   decoder sees only noise for a 100 kHz tone. We use 150 kHz so the FSK
 *   RX registers the DMA tone the same way it registers the DDS MARK tone.
 */

#define _DEFAULT_SOURCE

#include <iio.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "../common/rf_params.h"

/*
 * Buffer holds exactly 1500 cycles of the 150 kHz MARK tone at 2.304 Msps.
 * (2304000 / 150000) × 1500 = 23040  — zero-glitch cyclic wrap.
 *
 * Using MARK (150 kHz) so the FSK decoder on Pluto+ directly measures the
 * DMA output power: constant ΔP ≈ +17..+25 dB (same as DDS MARK) confirms
 * the DMA path delivers the same amplitude as the DDS hardware tone.
 *
 * DFT orthogonality reminder: 150 kHz = bin 1500 (at 100 Hz/bin) contributes
 * zero power to the 50 kHz SPACE bin — the same property that made 100 kHz
 * invisible to both FSK Goertzel filters in the first test run.
 */
#define CW_BUF_SAMPLES  23040
#define CW_TONE_HZ      FSK_TONE_MARK_HZ             /* 150 kHz = FSK MARK   */
#define CW_AMPLITUDE    ((int16_t)(0.9f * 32767.0f)) /* 90% full scale = 29490 */

static volatile bool g_running = true;
static void on_signal(int s) { (void)s; g_running = false; }
#define setup_signals() do { \
    signal(SIGINT,  on_signal); \
    signal(SIGTERM, on_signal); \
    signal(SIGHUP,  on_signal); \
} while (0)

int main(void)
{
    setup_signals();

    fprintf(stderr,
        "\n== SDR_Link: Step 1: CW via IIO DMA Buffer (ZedBoard) ==\n\n");

    /* ── 1/5  Open IIO context ───────────────────────────────────────────── */
    fprintf(stderr, "[ 1/5 ] Opening IIO context...\n");
    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) {
        fprintf(stderr, "ERROR: cannot open IIO context\n");
        return EXIT_FAILURE;
    }
    fprintf(stderr, "        %s\n\n", iio_context_get_description(ctx));

    /* ── 2/5  Configure AD9361 RF front-end ──────────────────────────────── */
    fprintf(stderr, "[ 2/5 ] Configuring AD9361 RF parameters...\n");
    struct iio_device *phy = iio_context_find_device(ctx, PHY_DEVICE);
    if (!phy) { fprintf(stderr, "ERROR: %s not found\n", PHY_DEVICE); goto fail; }

    struct iio_channel *lo_tx  = iio_device_find_channel(phy, "altvoltage1", true);
    struct iio_channel *tx_phy = iio_device_find_channel(phy, "voltage0",    true);
    if (!lo_tx || !tx_phy) { fprintf(stderr, "ERROR: PHY channels\n"); goto fail; }

    iio_channel_attr_write_longlong(lo_tx,  "frequency",          CARRIER_FREQ_HZ);
    iio_channel_attr_write_longlong(tx_phy, "rf_bandwidth",       RF_BANDWIDTH_HZ);
    iio_channel_attr_write_longlong(tx_phy, "sampling_frequency", SAMPLE_RATE_HZ);
    iio_channel_attr_write_longlong(tx_phy, "hardwaregain",       -(TX_ATTENUATION_MDB / 1000));

    fprintf(stderr, "        LO        : %.3f MHz\n", CARRIER_FREQ_HZ / 1e6);
    fprintf(stderr, "        Tone      : %.3f MHz  (LO + %lld kHz, software IQ)\n",
            (CARRIER_FREQ_HZ + CW_TONE_HZ) / 1e6, CW_TONE_HZ / 1000);
    fprintf(stderr, "        Rate      : %.3f Msps\n",   SAMPLE_RATE_HZ / 1e6);
    fprintf(stderr, "        Amplitude : %d / 32767  (%.0f%% FS)\n\n",
            CW_AMPLITUDE, CW_AMPLITUDE * 100.0 / 32767.0);

    /* ── 3/5  Silence the DDS hardware tones ─────────────────────────────── *
     *                                                                         *
     * The DDS (altvoltage0–3) and the DMA data feed into an adder in the     *
     * FPGA before the DAC. If we leave DDS scale non-zero, it adds on top    *
     * of our DMA samples and corrupts the waveform.                          *
     * Setting scale=0 and raw=0 on all four DDS channels makes the adder    *
     * contribute zero — DMA samples reach the DAC unmodified.               */
    fprintf(stderr, "[ 3/5 ] Silencing DDS hardware tones...\n");
    struct iio_device *dac = iio_context_find_device(ctx, TX_DDS_DEVICE);
    if (!dac) { fprintf(stderr, "ERROR: %s not found\n", TX_DDS_DEVICE); goto fail; }

    for (int i = 0; i < 4; i++) {
        char cname[16];
        snprintf(cname, sizeof(cname), "altvoltage%d", i);
        struct iio_channel *ch = iio_device_find_channel(dac, cname, true);
        if (ch) {
            iio_channel_attr_write_double(ch,   "scale", 0.0);
            iio_channel_attr_write_longlong(ch, "raw",   0);
        }
    }
    fprintf(stderr, "        DDS outputs zeroed.\n\n");

    /* ── 4/5  Create DMA TX buffer and fill with CW tone ─────────────────── *
     *                                                                         *
     * voltage0 (I) and voltage1 (Q) are the DMA data channels on this        *
     * device — distinct from the altvoltage DDS control channels.           *
     * iio_channel_enable() marks them for inclusion in the DMA buffer.      */
    fprintf(stderr, "[ 4/5 ] Building IQ buffer (%d samples = %.1f ms)...\n",
            CW_BUF_SAMPLES, CW_BUF_SAMPLES * 1000.0 / (double)SAMPLE_RATE_HZ);

    struct iio_channel *tx_i = iio_device_find_channel(dac, "voltage0", true);
    struct iio_channel *tx_q = iio_device_find_channel(dac, "voltage1", true);
    if (!tx_i || !tx_q) {
        fprintf(stderr, "ERROR: TX DMA voltage channels not found\n"
                        "       (voltage0/voltage1 on %s)\n", TX_DDS_DEVICE);
        goto fail;
    }
    iio_channel_enable(tx_i);
    iio_channel_enable(tx_q);

    /* cyclic=true: hardware replays this buffer forever, no CPU needed */
    struct iio_buffer *buf = iio_device_create_buffer(dac, CW_BUF_SAMPLES, true);
    if (!buf) {
        fprintf(stderr, "ERROR: iio_device_create_buffer failed\n");
        goto fail;
    }

    /*
     * Walk the buffer sample by sample.
     * iio_buffer_step() = bytes between consecutive IQ pairs = 4 (2× int16).
     * At each step: int16[0] = I  (voltage0),  int16[1] = Q  (voltage1).
     *
     * The phasor e^{jωn} = cos(ωn) + j·sin(ωn):
     *   I[n] = A · cos(ωn)   →   rotating real axis
     *   Q[n] = A · sin(ωn)   →   rotating imaginary axis
     */
    char    *p    = iio_buffer_start(buf);
    ptrdiff_t step = iio_buffer_step(buf);
    float    omega = 2.0f * (float)M_PI * (float)CW_TONE_HZ / (float)SAMPLE_RATE_HZ;

    fprintf(stderr, "        Buffer step : %td bytes/sample (I=int16, Q=int16)\n", step);
    fprintf(stderr, "        ω (rad/smp) : %.6f   (2π × %lld / %lld)\n",
            omega, CW_TONE_HZ, SAMPLE_RATE_HZ);

    for (int n = 0; n < CW_BUF_SAMPLES; n++, p += step) {
        int16_t *iq = (int16_t *)p;
        iq[0] = (int16_t)(CW_AMPLITUDE * cosf((float)n * omega)); /* I */
        iq[1] = (int16_t)(CW_AMPLITUDE * sinf((float)n * omega)); /* Q */
    }
    fprintf(stderr, "        Buffer filled.\n\n");

    /* ── 5/5  Push once — hardware takes over ─────────────────────────────── */
    fprintf(stderr, "[ 5/5 ] Pushing cyclic buffer to DMA...\n");
    ssize_t pushed = iio_buffer_push(buf);
    if (pushed < 0) {
        fprintf(stderr, "ERROR: iio_buffer_push returned %zd\n", pushed);
        iio_buffer_destroy(buf);
        goto fail;
    }
    fprintf(stderr, "        %zd bytes transferred to DMA.\n", pushed);
    fprintf(stderr, "        Hardware is now looping the buffer — CPU idle.\n\n");

    fprintf(stderr, "════ CW tone at %.3f MHz ════  Ctrl-C to stop.\n",
            (double)(CARRIER_FREQ_HZ + CW_TONE_HZ) / 1e6);
    fprintf(stderr, "On Pluto+ RX you should see ~−37 dBFS (same as OOK carrier).\n\n");

    while (g_running)
        sleep(1);

    iio_buffer_destroy(buf);
    iio_context_destroy(ctx);
    fprintf(stderr, "\nStopped.\n");
    return EXIT_SUCCESS;

fail:
    iio_context_destroy(ctx);
    return EXIT_FAILURE;
}
