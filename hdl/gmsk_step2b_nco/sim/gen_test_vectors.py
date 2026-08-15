#!/usr/bin/env python3
"""gen_test_vectors.py -- Sub-step B SIM gate: bit-exact reference model for
gmsk_step2b_nco, mirroring the RTL's own fixed-point formula (phase_acc +
step_in + adj_in, wrap-detect, bit-select mu extraction) with plain Python
integers -- no floating point, so there is zero rounding-difference risk
between this model and the RTL, unlike gmsk_step2a_interpolator's sine-based
generator (which necessarily tolerates small cubic-vs-sine error). This
module has no external "ground truth" signal to interpolate (no physical
waveform involved) -- the correctness question is purely "does the RTL
implement its OWN specified integer algorithm correctly," which a bit-exact
mirror answers directly and strictly, with an exact-match check rather than
a tolerance.

Three back-to-back phases, accumulator state carried continuously across all
of them (mirrors how the testbench never resets aresetn mid-stream, same
"don't cheat and let a design decision hide behind a reset" discipline
gmsk_step2a_interpolator's generator used for its own mu-phase transitions):
  1. adj_in=0                 -- nominal open-loop behavior, step_in exactly
                                  1/sps -> every strobe should land exactly
                                  sps=4 samples apart, mu=0 every time.
  2. adj_in=+ADJ_MAG           -- small positive loop-filter-style trim ->
                                  the accumulator runs slightly faster ->
                                  strobe period should average slightly
                                  BELOW 4 samples.
  3. adj_in=-ADJ_MAG           -- small negative trim -> period should
                                  average slightly ABOVE 4 samples.

Usage: python gen_test_vectors.py
Output (gitignored, regenerate as needed): step.hex, adj.hex,
        expected_strobe.hex, expected_mu.hex -- one line per sample, in
        $readmemh format, across all three phases concatenated in order.
"""

STEP_WIDTH = 32
MU_WIDTH   = 16
LOG2_SPS   = 2               # must match the RTL parameter -- 4 samples/symbol
N_PER_PHASE = 1000

MASK_STEP = (1 << STEP_WIDTH) - 1
MASK_MU   = (1 << MU_WIDTH) - 1
HIBIT = STEP_WIDTH - 1 - LOG2_SPS   # 29
LOBIT = STEP_WIDTH - LOG2_SPS - MU_WIDTH  # 14

STEP_NOMINAL = 1 << (STEP_WIDTH - LOG2_SPS)  # exact 1/4 in Q32
ADJ_MAG = 1 << 25                            # ~3% of STEP_NOMINAL -- small, plausible loop-filter trim

PHASES = [
    ("nominal",  STEP_NOMINAL, 0),
    ("speed up", STEP_NOMINAL, +ADJ_MAG),
    ("slow down", STEP_NOMINAL, -ADJ_MAG),
]


def to_hex(val, width):
    hexdigits = (width + 3) // 4
    return format(val & ((1 << width) - 1), '0{}x'.format(hexdigits))


def main():
    step_lines = []
    adj_lines = []
    strobe_lines = []
    mu_lines = []

    phase_acc = 0  # carried continuously across all three phases, never reset mid-stream

    for name, step, adj in PHASES:
        strobe_count = 0
        last_strobe_idx = None
        gaps = []

        for i in range(N_PER_PHASE):
            # Mirror the RTL exactly: sum_ext = phase_acc + step_in + adj_in,
            # evaluated as a genuine (unbounded) Python integer -- the RTL's
            # documented single-wrap precondition (0 <= sum < 2 * 2^STEP_WIDTH)
            # is asserted here, not silently masked, so a generator bug or a
            # precondition violation shows up immediately rather than being
            # hidden by Python's arbitrary-precision arithmetic.
            s = phase_acc + step + adj
            assert 0 <= s < (1 << (STEP_WIDTH + 1)), \
                f"single-wrap precondition violated at phase={name} i={i}: sum={s}"

            wrap = 1 if (s >> STEP_WIDTH) & 1 else 0
            new_phase = s & MASK_STEP
            mu = (new_phase >> LOBIT) & MASK_MU

            step_lines.append(to_hex(step, STEP_WIDTH))
            adj_lines.append(to_hex(adj, STEP_WIDTH))  # two's-complement STEP_WIDTH-bit repr, $readmemh into a `reg signed`
            strobe_lines.append('1' if wrap else '0')
            mu_lines.append(to_hex(mu, MU_WIDTH))

            if wrap:
                strobe_count += 1
                if last_strobe_idx is not None:
                    gaps.append(i - last_strobe_idx)
                last_strobe_idx = i

            phase_acc = new_phase

        avg_gap = sum(gaps) / len(gaps) if gaps else float('nan')
        print(f"phase '{name}': step={step} adj={adj:+d} -> "
              f"{strobe_count} strobes across {N_PER_PHASE} samples, "
              f"avg inter-strobe gap {avg_gap:.4f} samples "
              f"(nominal sps = {1 << LOG2_SPS})")

    with open('step.hex', 'w') as f:
        f.write('\n'.join(step_lines) + '\n')
    with open('adj.hex', 'w') as f:
        f.write('\n'.join(adj_lines) + '\n')
    with open('expected_strobe.hex', 'w') as f:
        f.write('\n'.join(strobe_lines) + '\n')
    with open('expected_mu.hex', 'w') as f:
        f.write('\n'.join(mu_lines) + '\n')

    total = len(PHASES) * N_PER_PHASE
    print(f"Wrote {total} samples across {len(PHASES)} phases to "
          f"step.hex / adj.hex / expected_strobe.hex / expected_mu.hex")


if __name__ == '__main__':
    main()
