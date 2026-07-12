/*
 * rx_stream_test.c — Raw libiio RX streaming/throughput baseline
 *
 * Purpose
 * -------
 * Measure the FPGA -> AXI DMA -> kernel IIO -> userspace path without any
 * demodulator or per-buffer printing.  This separates transport performance
 * from DSP performance.  It follows the libiio v0.x API used by Pluto+ 0.26.
 *
 * Usage on Pluto+:
 *   /tmp/rx_stream_test [samples-per-buffer] [buffer-count]
 *
 * Examples at 2.304 Msps:
 *     23040 samples =  10.0 ms
 *     65536 samples =  28.4 ms
 *    262144 samples = 113.8 ms  (default)
 *   1048576 samples = 455.1 ms
 */

#define _DEFAULT_SOURCE

#include <iio.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../common/rf_params.h"

#define DEFAULT_SAMPLES 262144
#define DEFAULT_BUFFERS 100

static volatile sig_atomic_t running = 1;

static void on_signal(int signo)
{
    (void)signo;
    running = 0;
}

static double elapsed_s(const struct timespec *a, const struct timespec *b)
{
    return (double)(b->tv_sec - a->tv_sec) +
           (double)(b->tv_nsec - a->tv_nsec) / 1.0e9;
}

static long parse_positive(const char *text, long maximum, const char *name)
{
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (!end || *end != '\0' || value < 1 || value > maximum) {
        fprintf(stderr, "ERROR: %s must be in the range 1..%ld\n",
                name, maximum);
        return -1;
    }
    return value;
}

static void print_format(const char *name, const struct iio_channel *channel)
{
    const struct iio_data_format *f = iio_channel_get_data_format(channel);
    fprintf(stderr,
            "  %-3s: container=%u bits, useful=%u bits, shift=%u, "
            "%s, %s-endian, repeat=%u\n",
            name, f->length, f->bits, f->shift,
            f->is_signed ? "signed" : "unsigned",
            f->is_be ? "big" : "little", f->repeat);
}

int main(int argc, char **argv)
{
    long requested_samples = DEFAULT_SAMPLES;
    long requested_buffers = DEFAULT_BUFFERS;

    if (argc > 3) {
        fprintf(stderr, "Usage: %s [samples-per-buffer] [buffer-count]\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (argc >= 2) {
        requested_samples = parse_positive(argv[1], 16L * 1024L * 1024L,
                                           "samples-per-buffer");
        if (requested_samples < 0) return EXIT_FAILURE;
    }
    if (argc == 3) {
        requested_buffers = parse_positive(argv[2], 1000000L, "buffer-count");
        if (requested_buffers < 0) return EXIT_FAILURE;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    fprintf(stderr, "\n== SDR_Link: Raw RX Streaming Baseline ==\n\n");
    fprintf(stderr, "Requested buffer : %ld IQ scans (%.3f ms)\n",
            requested_samples,
            requested_samples * 1000.0 / (double)SAMPLE_RATE_HZ);
    fprintf(stderr, "Requested count  : %ld buffers\n\n", requested_buffers);

    struct iio_context *ctx = iio_create_local_context();
    if (!ctx) {
        fprintf(stderr, "ERROR: cannot create local IIO context\n");
        return EXIT_FAILURE;
    }

    struct iio_device *phy = iio_context_find_device(ctx, PHY_DEVICE);
    struct iio_device *rx = iio_context_find_device(ctx, RX_DEVICE);
    if (!phy || !rx) {
        fprintf(stderr, "ERROR: AD9361 PHY/RX streaming device not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    struct iio_channel *lo = iio_device_find_channel(phy, "altvoltage0", true);
    struct iio_channel *rx_phy = iio_device_find_channel(phy, "voltage0", false);
    struct iio_channel *rx_i = iio_device_find_channel(rx, "voltage0", false);
    struct iio_channel *rx_q = iio_device_find_channel(rx, "voltage1", false);
    if (!lo || !rx_phy || !rx_i || !rx_q) {
        fprintf(stderr, "ERROR: required RX channels not found\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    if (iio_channel_attr_write_longlong(lo, "frequency", CARRIER_FREQ_HZ) < 0 ||
        iio_channel_attr_write_longlong(rx_phy, "rf_bandwidth", RF_BANDWIDTH_HZ) < 0 ||
        iio_channel_attr_write_longlong(rx_phy, "sampling_frequency", SAMPLE_RATE_HZ) < 0) {
        fprintf(stderr, "ERROR: AD9361 RF configuration failed\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    iio_channel_enable(rx_i);
    iio_channel_enable(rx_q);
    fprintf(stderr, "Channel data format reported by libiio:\n");
    print_format("I", rx_i);
    print_format("Q", rx_q);

    struct iio_buffer *buf =
        iio_device_create_buffer(rx, (size_t)requested_samples, false);
    if (!buf) {
        fprintf(stderr, "ERROR: cannot create RX buffer\n");
        iio_context_destroy(ctx);
        return EXIT_FAILURE;
    }

    const ptrdiff_t step = iio_buffer_step(buf);
    const ssize_t scan_size = iio_device_get_sample_size(rx);
    fprintf(stderr, "  scan step=%td bytes, device sample size=%zd bytes\n\n",
            step, scan_size);
    fprintf(stderr, "Streaming quietly; progress is printed only at the end...\n");

    size_t completed = 0;
    unsigned long long total_bytes = 0;
    volatile int32_t checksum = 0;
    struct timespec start, finish;
    clock_gettime(CLOCK_MONOTONIC, &start);

    while (running && completed < (size_t)requested_buffers) {
        ssize_t bytes = iio_buffer_refill(buf);
        if (bytes < 0) {
            fprintf(stderr, "ERROR: refill failed after %zu buffers (%zd)\n",
                    completed, bytes);
            break;
        }
        total_bytes += (unsigned long long)bytes;
        completed++;

        /* Touch one IQ pair so the test also validates that the returned
         * userspace address is readable.  This is intentionally not DSP. */
        const int16_t *iq = (const int16_t *)iio_buffer_first(buf, rx_i);
        checksum += (int32_t)iq[0] + (int32_t)iq[1];
    }
    clock_gettime(CLOCK_MONOTONIC, &finish);

    const double seconds = elapsed_s(&start, &finish);
    const double iq_scans = step > 0 ? (double)total_bytes / step : 0.0;
    fprintf(stderr, "\nStreaming result:\n");
    fprintf(stderr, "  completed buffers : %zu\n", completed);
    fprintf(stderr, "  elapsed time       : %.6f s\n", seconds);
    fprintf(stderr, "  transferred bytes : %llu\n", total_bytes);
    fprintf(stderr, "  IQ scans           : %.0f\n", iq_scans);
    fprintf(stderr, "  measured rate      : %.3f Msps\n",
            seconds > 0.0 ? iq_scans / seconds / 1.0e6 : 0.0);
    fprintf(stderr, "  data rate          : %.3f MB/s\n",
            seconds > 0.0 ? total_bytes / seconds / 1.0e6 : 0.0);
    fprintf(stderr, "  requested rate     : %.3f Msps\n", SAMPLE_RATE_HZ / 1.0e6);
    fprintf(stderr, "  checksum           : %d\n", (int)checksum);

    iio_buffer_destroy(buf);
    iio_context_destroy(ctx);
    return completed > 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
