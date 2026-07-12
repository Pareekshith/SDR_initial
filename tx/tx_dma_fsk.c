/*
 * tx_dma_fsk.c — Sample-timed 2-FSK transmitter using non-cyclic DMA blocks
 * Runs on : ZedBoard + AD9361
 *
 * Unlike tx.c, this program never switches DDS registers and never sleeps to
 * time an RF bit.  One DMA buffer contains exactly one 50 ms bit:
 *
 *   2,304,000 samples/s * 0.050 s = 115,200 IQ samples/bit
 *
 * iio_buffer_push() queues those samples, and the AD9361 sample clock plays
 * them at the exact bit rate.  Linux may prepare the next block early or late,
 * but it does not choose the duration of samples already handed to DMA.
 *
 * IQ sample packing is derived from iio_channel_get_data_format().  On the
 * standard ADI HDL path, a signed 12-bit DAC value is stored MSB-aligned in a
 * 16-bit container (shift=4).  We report and honor the actual channel format
 * instead of silently assuming native int16 values.
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

#include "../common/rf_params.h"

#define SAMPLES_PER_BIT ((size_t)(SAMPLE_RATE_HZ * FSK_BIT_PERIOD_US / 1000000LL))
#define LOGICAL_AMPLITUDE_FRACTION 0.70
#define INTERFRAME_MARK_BITS 50  /* 2.5 seconds at 50 ms/bit */

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

/* Pack a logical signed converter value into the IIO channel's storage
 * container.  The project hardware uses little-endian, <=16-bit channels;
 * reject anything else rather than transmit incorrectly. */
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

    /* Multiplication is defined for negative values; left-shifting a negative
     * signed integer is undefined in C even though many CPUs appear to work. */
    *(int16_t *)destination =
        (int16_t)(logical_value * (int32_t)(1U << format->shift));
    return true;
}

static bool fill_and_push_bit(struct iio_buffer *buffer,
                              struct iio_channel *tx_i,
                              struct iio_channel *tx_q,
                              int bit, double *phase)
{
    const struct iio_data_format *fi = iio_channel_get_data_format(tx_i);
    const struct iio_data_format *fq = iio_channel_get_data_format(tx_q);
    if (!fi || !fq || fi->bits != fq->bits || fi->shift != fq->shift)
        return false;

    const int32_t full_scale = (1L << (fi->bits - 1)) - 1;
    const double amplitude = LOGICAL_AMPLITUDE_FRACTION * full_scale;
    const double frequency = bit ? (double)FSK_TONE_MARK_HZ
                                 : (double)FSK_TONE_SPACE_HZ;
    const double phase_step = 2.0 * M_PI * frequency / (double)SAMPLE_RATE_HZ;
    const double rotate_i = cos(phase_step);
    const double rotate_q = sin(phase_step);
    double phasor_i = cos(*phase);
    double phasor_q = sin(*phase);
    char *pi = (char *)iio_buffer_first(buffer, tx_i);
    char *pq = (char *)iio_buffer_first(buffer, tx_q);
    const ptrdiff_t step = iio_buffer_step(buffer);

    for (size_t n = 0; n < SAMPLES_PER_BIT; n++, pi += step, pq += step) {
        int32_t i = (int32_t)lrint(amplitude * phasor_i);
        int32_t q = (int32_t)lrint(amplitude * phasor_q);
        if (!pack_sample(pi, fi, i) || !pack_sample(pq, fq, q))
            return false;

        /* Rotate the complex phasor by one sample.  This needs four
         * multiplications per IQ pair instead of two costly trig calls. */
        const double next_i = phasor_i * rotate_i - phasor_q * rotate_q;
        const double next_q = phasor_q * rotate_i + phasor_i * rotate_q;
        phasor_i = next_i;
        phasor_q = next_q;
    }

    *phase = atan2(phasor_q, phasor_i);
    if (*phase < 0.0) *phase += 2.0 * M_PI;

    return iio_buffer_push(buffer) >= 0;
}

static bool send_byte(struct iio_buffer *buffer,
                      struct iio_channel *tx_i, struct iio_channel *tx_q,
                      uint8_t byte, double *phase)
{
    if (!fill_and_push_bit(buffer, tx_i, tx_q, 0, phase)) return false;
    for (int bit = 0; bit < 8 && running; bit++)
        if (!fill_and_push_bit(buffer, tx_i, tx_q,
                              (byte >> bit) & 1, phase)) return false;
    return running && fill_and_push_bit(buffer, tx_i, tx_q, 1, phase);
}

static bool send_frame(struct iio_buffer *buffer,
                       struct iio_channel *tx_i, struct iio_channel *tx_q,
                       const char *message, double *phase)
{
    const size_t length = strlen(message);
    if (length > 255) return false;

    for (int n = 0; n < FRAME_PREAMBLE_CNT && running; n++)
        if (!send_byte(buffer, tx_i, tx_q, FRAME_PREAMBLE_BYTE, phase)) return false;
    if (!send_byte(buffer, tx_i, tx_q, FRAME_SYNC_BYTE, phase)) return false;
    if (!send_byte(buffer, tx_i, tx_q, (uint8_t)length, phase)) return false;
    for (size_t n = 0; n < length && running; n++)
        if (!send_byte(buffer, tx_i, tx_q, (uint8_t)message[n], phase)) return false;
    return running;
}

int main(void)
{
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    fprintf(stderr, "\n== SDR_Link: Sample-timed DMA 2-FSK Transmitter ==\n\n");
    fprintf(stderr, "One bit buffer: %zu samples = %.3f ms\n",
            SAMPLES_PER_BIT,
            SAMPLES_PER_BIT * 1000.0 / (double)SAMPLE_RATE_HZ);

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
        iio_channel_attr_write_longlong(tx_phy, "rf_bandwidth", RF_BANDWIDTH_HZ) < 0 ||
        iio_channel_attr_write_longlong(tx_phy, "sampling_frequency", SAMPLE_RATE_HZ) < 0 ||
        iio_channel_attr_write_longlong(tx_phy, "hardwaregain",
                                        -(TX_ATTENUATION_MDB / 1000)) < 0) {
        fprintf(stderr, "ERROR: AD9361 TX configuration failed\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    /* DDS and DMA are summed by the FPGA TX core.  Silence all DDS tones so
     * only our sample stream reaches the DAC. */
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
        fprintf(stderr, "ERROR: this lesson currently supports signed LE 16-bit containers\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_buffer *buffer =
        iio_device_create_buffer(dac, SAMPLES_PER_BIT, false);
    if (!buffer) {
        fprintf(stderr, "ERROR: cannot create non-cyclic TX buffer\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    fprintf(stderr,
            "MARK %.0f kHz, SPACE %.0f kHz, %.0f%% logical converter scale\n",
            FSK_TONE_MARK_HZ / 1000.0, FSK_TONE_SPACE_HZ / 1000.0,
            LOGICAL_AMPLITUDE_FRACTION * 100.0);
    fprintf(stderr, "Transmitting framed message: %s", FSK_MESSAGE);
    fprintf(stderr, "Ctrl-C stops after the current DMA block.\n\n");

    double phase = 0.0;
    unsigned frame_number = 0;
    while (running) {
        fprintf(stderr, "TX DMA frame #%u\n", ++frame_number);
        if (!send_frame(buffer, tx_i, tx_q, FSK_MESSAGE, &phase)) break;
        for (int n = 0; n < INTERFRAME_MARK_BITS && running; n++)
            if (!fill_and_push_bit(buffer, tx_i, tx_q, 1, &phase)) {
                running = 0;
                break;
            }
    }

    iio_buffer_destroy(buffer);
    iio_context_destroy(ctx);
    fprintf(stderr, "Stopped.\n");
    return EXIT_SUCCESS;
}
