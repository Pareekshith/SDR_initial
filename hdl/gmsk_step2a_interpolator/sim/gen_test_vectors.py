#!/usr/bin/env python3
"""gen_test_vectors.py -- Sub-step A SIM gate: synthesizes a sine-wave input
stream plus its analytically-exact cubic-interpolated expected output, for a
few fixed mu values, to test gmsk_step2a_interpolator in isolation.

Why a sine wave and not the MARK/SPACE FSK vectors gmsk_step1_discriminator's
testbench uses: a smooth sine has an exact, easily-computed analytic value at
ANY fractional sample position (A*sin(2*pi*f0*(n+mu)/Fs)), letting this test
check genuine sub-sample interpolation accuracy directly against ground
truth -- not just "settles near a rough expected level" the way Step 1's
bimodal MARK/SPACE test works. That's the right test for a discriminator
(prove two levels are separated); it's the wrong test for an interpolator
(prove the curve is right BETWEEN samples).

Expected values are computed by mirroring the RTL's own delay-line indexing
in Python (not just the abstract math) so the output is already in the exact
same order the RTL will emit it in -- the testbench then just consumes
expected.hex in strict order against each captured m_axis_tvalid pulse,
skipping only the initial settle period, the same self-synchronizing pattern
gmsk_step1_discriminator's testbench uses (see its GAP_CYCLES comment for
why this matters more than a fixed-latency-offset capture).

Usage: python gen_test_vectors.py
Output: input.hex, mu.hex, expected.hex (all $readmemh-compatible,
        one value per line) -- gitignored, regenerate as needed.
"""
import math

FS = 2304000          # arbitrary for this isolated math test -- matches
                       # rf_params.h's SAMPLE_RATE_HZ by convention only
F0 = 200000            # test tone frequency, comfortably inside Nyquist
                       # (~11.5 samples/cycle -- smooth enough for cubic
                       # interpolation to be accurate, not so smooth it
                       # can't catch a real bug)
AMPLITUDE = 300000      # matches the rough magnitude of real discriminator
                       # output seen on hardware (see project memory)
IN_WIDTH = 24
MU_WIDTH = 16
N_SAMPLES_PER_MU = 200  # input samples fed per mu phase
MU_VALUES = [0.0, 0.25, 0.5, 0.75]


def to_signed_hex(val, width):
    val = int(round(val))
    maxval = (1 << (width - 1)) - 1
    minval = -(1 << (width - 1))
    val = max(minval, min(maxval, val))
    if val < 0:
        val += 1 << width
    hexdigits = (width + 3) // 4
    return format(val, '0{}x'.format(hexdigits))


def main():
    input_lines = []
    mu_lines = []
    expected_lines = []

    global_n = 0  # continuous sample index across all mu phases, so the
                  # sine stays phase-continuous instead of jumping at each
                  # phase boundary (irrelevant to correctness, just keeps
                  # the test signal sane to look at if ever plotted)

    # Mirror the RTL's own 4-tap delay line in Python, index-for-index, so
    # expected[] comes out pre-aligned to the RTL's output order. Only
    # initialized ONCE, outside the mu loop -- the RTL's delay line is never
    # reset between mu phases (aresetn stays high, mu_in just changes value
    # mid-stream), so the reference must not reset either or the first few
    # samples of phase 2/3/4 would wrongly assume a zeroed window when the
    # real RTL still holds genuine signal from the end of the prior phase.
    x_m1 = x_0 = x_1 = x_2 = 0.0

    for mu in MU_VALUES:
        mu_int = int(round(mu * (1 << MU_WIDTH)))
        mu_hex = format(mu_int, '0{}x'.format((MU_WIDTH + 3) // 4))

        for i in range(N_SAMPLES_PER_MU):
            n = global_n
            x_n = AMPLITUDE * math.sin(2 * math.pi * F0 * n / FS)

            input_lines.append(to_signed_hex(x_n, IN_WIDTH))
            mu_lines.append(mu_hex)

            # Shift the window exactly like the RTL: new sample becomes x_2.
            x_m1, x_0, x_1, x_2 = x_0, x_1, x_2, x_n

            # After this shift, x_0 corresponds to input sample (n-2) --
            # see the RTL module's header comment for the derivation.
            x0_index = n - 2
            expected = AMPLITUDE * math.sin(2 * math.pi * F0 * (x0_index + mu) / FS)
            expected_lines.append(to_signed_hex(expected, IN_WIDTH))

            global_n += 1

    with open('input.hex', 'w') as f:
        f.write('\n'.join(input_lines) + '\n')
    with open('mu.hex', 'w') as f:
        f.write('\n'.join(mu_lines) + '\n')
    with open('expected.hex', 'w') as f:
        f.write('\n'.join(expected_lines) + '\n')

    print(f"Wrote {len(input_lines)} samples across {len(MU_VALUES)} mu phases "
          f"({N_SAMPLES_PER_MU} samples/phase) to input.hex / mu.hex / expected.hex")


if __name__ == '__main__':
    main()
