/*
 * tx_gmsk_debug.c — continuous Gaussian-shaped 1,0,1,0,... debug transmitter
 * Runs on : ZedBoard + AD9361
 *
 * Not a spec-correct/bandwidth-optimized GMSK transmitter -- this exists
 * purely to give the discriminator a predictable, continuously repeating
 * pattern to debug against, instead of "HELLO SDR"'s mixed ASCII bit
 * pattern. Same MARK/SPACE tones as tx_dma_fsk.c (so RX gain, the
 * discriminator's scaling, and everything else already calibrated against
 * those tones stays valid) -- the only difference is Gaussian-smoothed
 * transitions between them instead of an instantaneous switch at each bit
 * boundary.
 *
 * Frequency trajectory: freq(t) = center + deviation * gaussian_filter(nrz(t))
 *   center    = (FSK_TONE_MARK_HZ + FSK_TONE_SPACE_HZ) / 2
 *   deviation = (FSK_TONE_MARK_HZ - FSK_TONE_SPACE_HZ) / 2
 *   nrz(t)    = +1 for bit '1', -1 for bit '0', alternating every bit
 *
 * The whole pattern (PATTERN_BIT_PAIRS "10" pairs) is precomputed once into
 * one buffer, Gaussian-filtered with a CIRCULAR convolution (not a plain
 * one, since the buffer must be a genuinely periodic waveform -- see
 * below), then played as a single libiio CYCLIC buffer: the AD9361 DAC
 * repeats it in hardware forever with zero further CPU/DMA involvement,
 * unlike tx_dma_fsk.c's per-bit push loop.
 *
 * Why circular convolution specifically: an equal count of +1/-1 NRZ
 * symbols averages to exactly zero, so a circularly-filtered version of
 * the pattern also integrates to exactly zero net phase over one full
 * period -- the phase returns exactly to its starting value at the buffer
 * boundary, so the hardware's loop-back is phase-continuous with no
 * glitch. A plain (non-circular) convolution would leave the filter's
 * settling tail unmatched at the wrap point, since the buffer doesn't
 * feed real "before/after" context there -- it just jumps back to sample 0.
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
#include <unistd.h>

#include "../common/rf_params.h"

/* Debug-only overrides, NOT the rf_params.h shared values -- this tool has
 * no obligation to stay within them, it's a standalone debug signal, not
 * the real link. SAMPLES_PER_BIT=4 (2.304 Msps / 4 = ~1.7us/bit, ~576 kbps)
 * so the whole cyclic pattern repeats many times within one 65.5us ILA
 * capture window, instead of covering ~3% of a single real (2ms) bit as
 * before. DEBUG_RF_BANDWIDTH_HZ is widened well past rf_params.h's 400 kHz
 * to comfortably cover this rate's true occupied bandwidth (~1.25 MHz by
 * Carson's rule) with margin, so the AD9361's own channel filter doesn't
 * smear the transitions we're trying to see. Gaussian shaping below is
 * nearly a no-op at this few samples/bit regardless of GMSK_BT -- there's
 * no room left for a meaningful kernel, which is fine here. */
#define SAMPLES_PER_BIT ((size_t)4)
#define DEBUG_RF_BANDWIDTH_HZ 4000000LL                /* 4 MHz -- comfortable
                                                         * margin over the true
                                                         * ~1.25MHz occupied
                                                         * bandwidth at this
                                                         * bit rate */
#define DEBUG_TX_ATTENUATION_MDB 3000                  /* -3dB, near max TX
                                                         * power (AD9361 range
                                                         * is 0 to -89.75dB,
                                                         * 0=max) -- was -20dB
                                                         * from rf_params.h,
                                                         * leaving ~17dB of
                                                         * headroom unused for
                                                         * a bench debug link */
#define LOGICAL_AMPLITUDE_FRACTION 0.70

/* PATTERN_BIT_PAIRS must be chosen so the buffer length is phase-continuous
 * at the wrap point, not just any convenient count. The deviation term's
 * contribution to net phase over one period is always exactly zero (equal
 * +1/-1 NRZ counts, preserved through circular convolution) -- but the
 * CENTER frequency's contribution is only a whole multiple of 2*pi if
 * total_samples is a whole multiple of
 * SAMPLE_RATE_HZ / gcd(center_hz, SAMPLE_RATE_HZ) = 2304000/gcd(100000,2304000)
 * = 2304000/4000 = 576 samples. This held by coincidence at the original
 * SAMPLES_PER_BIT=4608 (147456 total = 256x576) but broke silently when
 * SAMPLES_PER_BIT dropped to 4 for a shorter debug buffer (128 total, not a
 * multiple of 576) -- see the runtime check below, which would have caught
 * it. 72 pairs x 4 samples/bit = 576 samples/period, the smallest count
 * satisfying this at SAMPLES_PER_BIT=4. */
#define PATTERN_BIT_PAIRS 72
#define PATTERN_BITS      (PATTERN_BIT_PAIRS * 2)
#define GMSK_BT            4.0                         /* BT is INVERSELY related to
                                                         * smoothing (sigma ~ 1/BT) --
                                                         * a high BT here means a
                                                         * NARROW kernel (~0.13 bit
                                                         * periods half-width), so the
                                                         * signal actually settles near
                                                         * the true tones for most of
                                                         * each bit instead of
                                                         * continuously sweeping.
                                                         * Real GSM uses BT=0.3, the
                                                         * opposite end of the scale --
                                                         * this is a debug aid, not
                                                         * spec-correct minimal-
                                                         * bandwidth GMSK. */

static volatile sig_atomic_t running = 1;

static void on_signal(int signo)
{
    (void)signo;
    running = 0;
}

static void print_format(const char *name, const struct iio_channel *channel)
{
    const struct iio_data_format *f = iio_channel_get_data_format(channel);
    fprintf(stderr,
            "        %s: container=%u, useful=%u, shift=%u, %s, %s-endian\n",
            name, f->length, f->bits, f->shift,
            f->is_signed ? "signed" : "unsigned",
            f->is_be ? "big" : "little");
}

static bool pack_sample(void *destination, const struct iio_data_format *format,
                        int32_t logical_value)
{
    if (!format || format->length != 16 || format->bits < 2 ||
        format->bits > 16 || format->is_be || !format->is_signed)
        return false;

    const int32_t minimum = -(1L << (format->bits - 1));
    const int32_t maximum =  (1L << (format->bits - 1)) - 1;
    if (logical_value < minimum) logical_value = minimum;
    if (logical_value > maximum) logical_value = maximum;

    *(int16_t *)destination =
        (int16_t)(logical_value * (int32_t)(1U << format->shift));
    return true;
}

/* Build the per-sample NRZ array: +1.0/-1.0, each bit held for
 * SAMPLES_PER_BIT samples, alternating starting with '1'. */
static void build_nrz(double *nrz, size_t total_samples)
{
    for (size_t n = 0; n < total_samples; n++) {
        size_t bit_index = n / SAMPLES_PER_BIT;
        nrz[n] = (bit_index % 2 == 0) ? 1.0 : -1.0;
    }
}

/* Gaussian LPF impulse response, standard sigma-from-BT relationship
 * (same one GNU Radio's gaussian_taps uses), sampled at the IQ rate and
 * normalized to unit sum (a smoothing kernel, not a unit-energy filter --
 * we want it to preserve the NRZ levels' average, not their power). */
static size_t build_gaussian_kernel(double **kernel_out, double bt)
{
    const double sigma_samples =
        sqrt(log(2.0)) / (2.0 * M_PI * bt) * (double)SAMPLES_PER_BIT;
    const size_t half_width = (size_t)ceil(4.0 * sigma_samples);
    const size_t width = 2 * half_width + 1;

    double *kernel = malloc(width * sizeof(double));
    if (!kernel) return 0;

    double sum = 0.0;
    for (size_t n = 0; n < width; n++) {
        double t = (double)n - (double)half_width;
        /* expf, not exp: this rootfs's runtime glibc predates the
         * GLIBC_2.29 symbol version the double-precision exp() pulled in
         * on the (newer-glibc) system this was cross-compiled on. A
         * Gaussian smoothing kernel doesn't need double precision here. */
        kernel[n] = (double)expf((float)(-(t * t) / (2.0 * sigma_samples * sigma_samples)));
        sum += kernel[n];
    }
    for (size_t n = 0; n < width; n++)
        kernel[n] /= sum;

    *kernel_out = kernel;
    return width;
}

/* Circular convolution: out[n] = sum_k nrz[(n - k + N) % N] * kernel[k],
 * kernel indexed so kernel[half_width] is the center tap. */
static void circular_convolve(const double *nrz, size_t n_samples,
                              const double *kernel, size_t kernel_width,
                              double *out)
{
    const size_t half_width = kernel_width / 2;
    for (size_t n = 0; n < n_samples; n++) {
        double acc = 0.0;
        for (size_t k = 0; k < kernel_width; k++) {
            long offset = (long)n - ((long)k - (long)half_width);
            long idx = ((offset % (long)n_samples) + (long)n_samples) % (long)n_samples;
            acc += nrz[idx] * kernel[k];
        }
        out[n] = acc;
    }
}

int main(void)
{
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    fprintf(stderr, "\n== SDR_Link: GMSK debug transmitter (Gaussian 1,0,1,0,...) ==\n\n");

    const size_t total_samples = (size_t)PATTERN_BITS * SAMPLES_PER_BIT;
    const double center_hz    = (FSK_TONE_MARK_HZ + FSK_TONE_SPACE_HZ) / 2.0;
    const double deviation_hz = (FSK_TONE_MARK_HZ - FSK_TONE_SPACE_HZ) / 2.0;

    fprintf(stderr, "Pattern   : %d bits (%d x \"10\"), %zu samples, BT=%.2f\n",
            PATTERN_BITS, PATTERN_BIT_PAIRS, total_samples, GMSK_BT);
    fprintf(stderr, "Center    : %.0f kHz above LO, deviation +/- %.0f kHz "
            "(same MARK/SPACE tones as tx_dma_fsk.c)\n",
            center_hz / 1000.0, deviation_hz / 1000.0);

    double *nrz = malloc(total_samples * sizeof(double));
    double *filtered = malloc(total_samples * sizeof(double));
    double *kernel = NULL;
    if (!nrz || !filtered) {
        fprintf(stderr, "ERROR: allocation failed\n");
        return EXIT_FAILURE;
    }
    build_nrz(nrz, total_samples);

    size_t kernel_width = build_gaussian_kernel(&kernel, GMSK_BT);
    if (!kernel) {
        fprintf(stderr, "ERROR: kernel allocation failed\n");
        return EXIT_FAILURE;
    }
    fprintf(stderr, "Gaussian kernel: %zu taps (%.2f bit periods half-width)\n",
            kernel_width, (kernel_width / 2) / (double)SAMPLES_PER_BIT);

    circular_convolve(nrz, total_samples, kernel, kernel_width, filtered);
    free(kernel);

    /* Integrate phase from the filtered frequency-deviation trajectory. */
    double *phase_i = malloc(total_samples * sizeof(double));
    double *phase_q = malloc(total_samples * sizeof(double));
    if (!phase_i || !phase_q) {
        fprintf(stderr, "ERROR: allocation failed\n");
        return EXIT_FAILURE;
    }
    double phase = 0.0;
    for (size_t n = 0; n < total_samples; n++) {
        double freq = center_hz + deviation_hz * filtered[n];
        phase += 2.0 * M_PI * freq / (double)SAMPLE_RATE_HZ;
        phase_i[n] = cos(phase);
        phase_q[n] = sin(phase);
    }
    /* Wrap to (-pi, pi] and check it's actually close to zero -- a real
     * check, not just a printed number to eyeball. A bad wrap here means a
     * phase-discontinuity glitch will appear in the transmitted signal
     * every time the cyclic buffer loops, which for a short debug buffer
     * can be frequent enough to dominate what's visible on the ILA. */
    double wrapped = fmod(phase, 2.0 * M_PI);
    if (wrapped > M_PI) wrapped -= 2.0 * M_PI;
    if (wrapped < -M_PI) wrapped += 2.0 * M_PI;
    fprintf(stderr, "Net phase over one period: %.4f rad (wrapped: %.4f rad, "
            "should be ~0 for a glitch-free loop)\n", phase, wrapped);
    if (fabs(wrapped) > 0.01) {
        fprintf(stderr, "ERROR: buffer is not phase-continuous at the wrap point "
                "(%.4f rad off) -- adjust PATTERN_BIT_PAIRS so total_samples "
                "(%zu) is a whole multiple of SAMPLE_RATE_HZ/gcd(center_hz, "
                "SAMPLE_RATE_HZ) = 576 samples. Refusing to transmit a "
                "glitchy signal.\n", wrapped, total_samples);
        free(nrz); free(filtered); free(phase_i); free(phase_q);
        return EXIT_FAILURE;
    }

    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) {
        fprintf(stderr, "ERROR: cannot create local IIO context\n");
        return EXIT_FAILURE;
    }

    struct iio_device *phy = iio_context_find_device(ctx, PHY_DEVICE);
    struct iio_device *dac = iio_context_find_device(ctx, TX_DDS_DEVICE);
    if (!phy || !dac) {
        fprintf(stderr, "ERROR: PHY or TX streaming device not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_channel *lo = iio_device_find_channel(phy, "altvoltage1", true);
    struct iio_channel *tx_phy = iio_device_find_channel(phy, "voltage0", true);
    struct iio_channel *tx_i = iio_device_find_channel(dac, "voltage0", true);
    struct iio_channel *tx_q = iio_device_find_channel(dac, "voltage1", true);
    if (!lo || !tx_phy || !tx_i || !tx_q) {
        fprintf(stderr, "ERROR: required TX channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    if (iio_channel_attr_write_longlong(lo, "frequency", CARRIER_FREQ_HZ) < 0 ||
        iio_channel_attr_write_longlong(tx_phy, "rf_bandwidth", DEBUG_RF_BANDWIDTH_HZ) < 0 ||
        iio_channel_attr_write_longlong(tx_phy, "sampling_frequency", SAMPLE_RATE_HZ) < 0 ||
        iio_channel_attr_write_longlong(tx_phy, "hardwaregain",
                                        -(DEBUG_TX_ATTENUATION_MDB / 1000)) < 0) {
        fprintf(stderr, "ERROR: AD9361 TX configuration failed\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    for (int n = 0; n < 4; n++) {
        char name[16];
        snprintf(name, sizeof(name), "altvoltage%d", n);
        struct iio_channel *dds = iio_device_find_channel(dac, name, true);
        if (dds) {
            iio_channel_attr_write_double(dds, "scale", 0.0);
            iio_channel_attr_write_longlong(dds, "raw", 0);
        }
    }

    iio_channel_enable(tx_i);
    iio_channel_enable(tx_q);
    fprintf(stderr, "TX channel data format:\n");
    print_format("I", tx_i);
    print_format("Q", tx_q);

    const struct iio_data_format *format = iio_channel_get_data_format(tx_i);
    if (!format || format->length != 16 || !format->is_signed || format->is_be) {
        fprintf(stderr, "ERROR: this tool currently supports signed LE 16-bit containers\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }
    const int32_t full_scale = (1L << (format->bits - 1)) - 1;
    const double amplitude = LOGICAL_AMPLITUDE_FRACTION * full_scale;

    /* Cyclic buffer: filled and pushed once, the AD9361 DAC then repeats
     * it in hardware forever -- no further software involvement needed. */
    struct iio_buffer *buffer =
        iio_device_create_buffer(dac, total_samples, true);
    if (!buffer) {
        fprintf(stderr, "ERROR: cannot create cyclic TX buffer\n");
        free(nrz); free(filtered); free(phase_i); free(phase_q);
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    char *pi = (char *)iio_buffer_first(buffer, tx_i);
    char *pq = (char *)iio_buffer_first(buffer, tx_q);
    const ptrdiff_t step = iio_buffer_step(buffer);
    for (size_t n = 0; n < total_samples; n++, pi += step, pq += step) {
        int32_t i = (int32_t)lrint(amplitude * phase_i[n]);
        int32_t q = (int32_t)lrint(amplitude * phase_q[n]);
        if (!pack_sample(pi, format, i) || !pack_sample(pq, format, q)) {
            fprintf(stderr, "ERROR: sample packing failed\n");
            iio_buffer_destroy(buffer);
            iio_context_destroy(ctx);
            return EXIT_FAILURE;
        }
    }
    free(nrz); free(filtered); free(phase_i); free(phase_q);

    if (iio_buffer_push(buffer) < 0) {
        fprintf(stderr, "ERROR: iio_buffer_push failed\n");
        iio_buffer_destroy(buffer);
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    fprintf(stderr, "Cyclic buffer pushed -- hardware now repeating it continuously.\n");
    fprintf(stderr, "Ctrl-C to stop.\n\n");
    while (running)
        pause();

    iio_buffer_destroy(buffer);
    iio_context_destroy(ctx);
    fprintf(stderr, "Stopped.\n");
    return EXIT_SUCCESS;
}
