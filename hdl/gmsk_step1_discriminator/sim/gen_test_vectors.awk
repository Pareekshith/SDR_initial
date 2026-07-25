# gen_test_vectors.awk — synthesizes a continuous-phase two-tone (MARK/
# SPACE) baseband IQ test stream for gmsk_step1_discriminator's testbench.
#
# Mirrors the FSK tone offsets from common/rf_params.h (both tones are
# *baseband offsets after downconversion*, both positive, per that file's
# comment) and the design doc's stated test plan: a continuous alternating
# 1,0,1,0,... bit pattern is the cleanest input for exercising this block,
# with no framing logic involved yet.
#
# Phase is accumulated continuously across bit boundaries (never reset to
# zero at a bit edge) because real FSK/GMSK is continuous-phase — a
# discontinuity here would not match what the real TX produces.
#
# Usage: awk -f gen_test_vectors.awk > test_vectors.hex
# Output: one 8-hex-digit line per sample, $readmemh-compatible, each word
# packed as {Q[15:0], I[15:0]} to match gmsk_step1_discriminator's TDATA
# convention.

BEGIN {
    PI              = 3.14159265358979323846
    FS              = 2304000
    MARK_HZ         = 150000   # bit '1' — see rf_params.h FSK_TONE_MARK_HZ
    SPACE_HZ        = 50000    # bit '0' — see rf_params.h FSK_TONE_SPACE_HZ
    AMPLITUDE       = 20000    # well within signed 16-bit range, headroom like a real ADC
    SAMPLES_PER_BIT = 480      # sim-scale window, not the real 50ms bit period
    NUM_BITS        = 10       # alternating 1,0,1,0,... per the doc's test plan

    phase = 0.0
    for (b = 0; b < NUM_BITS; b++) {
        bit = (b % 2 == 0) ? 1 : 0
        f   = (bit == 1) ? MARK_HZ : SPACE_HZ
        dtheta = 2.0 * PI * f / FS
        for (s = 0; s < SAMPLES_PER_BIT; s++) {
            i_val = int(AMPLITUDE * cos(phase) + (AMPLITUDE * cos(phase) >= 0 ? 0.5 : -0.5))
            q_val = int(AMPLITUDE * sin(phase) + (AMPLITUDE * sin(phase) >= 0 ? 0.5 : -0.5))

            i_u16 = (i_val < 0) ? i_val + 65536 : i_val
            q_u16 = (q_val < 0) ? q_val + 65536 : q_val

            word = q_u16 * 65536 + i_u16
            printf "%08x\n", word

            phase += dtheta
            if (phase > 2.0 * PI) phase -= 2.0 * PI
        }
    }
}
