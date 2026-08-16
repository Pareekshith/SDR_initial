#!/usr/bin/env python3
"""gen_test_vectors.py -- Sub-step B2 SIM gate: bit-exact reference model
for gmsk_step2b2_nco, mirroring the RTL's own fixed-point formula (same
accumulate-and-wrap core as gmsk_step2b_nco's own generator, extended with
the second 0.5-threshold crossing).

Three back-to-back phases, same as gmsk_step2b_nco's own generator and for
the same reason (accumulator state carried continuously across all of
them, never reset mid-stream):
  1. adj_in=0                 -- nominal, exact step -- both crossing types
                                  should land with mu=0 every single time
                                  (the accumulator only ever hits exact
                                  multiples of 0.25 symbol, and 0.5 IS one
                                  of those multiples).
  2. adj_in=+ADJ_MAG           -- accumulator runs slightly faster -> mu
                                  should drift away from 0 for BOTH
                                  crossing types, not just the on-time one.
  3. adj_in=-ADJ_MAG           -- slightly slower -> opposite drift.

The core correctness claim being tested -- that the SAME [HIBIT:LOBIT]
bit-select gives the right mu for the mid-point crossing, with zero extra
arithmetic -- was independently verified against a from-first-principles
floating-point ground truth (not just self-consistency with the RTL's own
formula) BEFORE this RTL was written; see project_fpga_gmsk_plan memory's
correction note. This generator re-derives that same ground truth here so
the SIM gate itself re-proves it, not just trusts the earlier one-off
verification script.

Usage: python gen_test_vectors.py
Output (gitignored, regenerate as needed): step.hex, adj.hex,
        expected_strobe.hex, expected_ismid.hex, expected_mu.hex -- one
        line per sample, across all three phases concatenated in order.
"""

STEP_WIDTH = 32
MU_WIDTH   = 16
LOG2_SPS   = 2               # must match the RTL parameter -- 4 samples/symbol
N_PER_PHASE = 1000

MASK_STEP = (1 << STEP_WIDTH) - 1
MASK_MU   = (1 << MU_WIDTH) - 1
HIBIT = STEP_WIDTH - 1 - LOG2_SPS   # 29
LOBIT = STEP_WIDTH - LOG2_SPS - MU_WIDTH  # 14
SPS = 1 << LOG2_SPS

STEP_NOMINAL = 1 << (STEP_WIDTH - LOG2_SPS)  # exact 1/4 in Q32
ADJ_MAG = 1 << 25                            # ~3% of STEP_NOMINAL -- same magnitude gmsk_step2b_nco's own generator used

PHASES = [
    ("nominal",   STEP_NOMINAL, 0),
    ("speed up",  STEP_NOMINAL, +ADJ_MAG),
    ("slow down", STEP_NOMINAL, -ADJ_MAG),
]


def to_hex(val, width):
    hexdigits = (width + 3) // 4
    return format(val & ((1 << width) - 1), '0{}x'.format(hexdigits))


def ground_truth_mu(new_phase, wrap, mid_cross):
    """Independent from-first-principles floating-point derivation (NOT
    the RTL's own bit-select formula) -- deliberately re-derived here so
    the SIM gate proves the bit-select formula is correct, not just
    self-consistent with itself."""
    x = new_phase / (1 << STEP_WIDTH)
    if wrap:
        true_mu = (x * SPS) % 1.0
    elif mid_cross:
        true_mu = ((x - 0.5) * SPS) % 1.0
    else:
        return None
    return int(round(true_mu * (1 << MU_WIDTH))) % (1 << MU_WIDTH)


def main():
    step_lines = []
    adj_lines = []
    strobe_lines = []
    ismid_lines = []
    mu_lines = []

    phase_acc = 0  # carried continuously across all three phases

    ground_truth_checks = 0
    ground_truth_mismatches = 0

    for name, step, adj in PHASES:
        strobe_count = 0
        mid_count = 0
        on_count = 0

        for i in range(N_PER_PHASE):
            s = phase_acc + step + adj
            assert 0 <= s < (1 << (STEP_WIDTH + 1)), \
                f"single-wrap precondition violated at phase={name} i={i}: sum={s}"

            wrap = 1 if (s >> STEP_WIDTH) & 1 else 0
            new_phase = s & MASK_STEP

            old_top = (phase_acc >> (STEP_WIDTH - 1)) & 1
            new_top = (new_phase >> (STEP_WIDTH - 1)) & 1
            mid_cross = 1 if (not wrap and old_top == 0 and new_top == 1) else 0

            # RTL formula (what gmsk_step2b2_nco.v actually computes):
            mu_rtl = (new_phase >> LOBIT) & MASK_MU

            # Cross-check against the independent ground truth whenever a
            # real crossing happens -- this IS the claim being tested.
            if wrap or mid_cross:
                gt = ground_truth_mu(new_phase, wrap, mid_cross)
                ground_truth_checks += 1
                if abs(gt - mu_rtl) > 2:  # same +-2 quantization tolerance as the one-off verification script
                    ground_truth_mismatches += 1
                    print(f"GROUND-TRUTH MISMATCH phase={name} i={i}: "
                          f"gt={gt} rtl={mu_rtl}")

            step_lines.append(to_hex(step, STEP_WIDTH))
            adj_lines.append(to_hex(adj, STEP_WIDTH))
            strobe_lines.append('1' if (wrap or mid_cross) else '0')
            ismid_lines.append('1' if mid_cross else '0')
            mu_lines.append(to_hex(mu_rtl, MU_WIDTH))

            if wrap:
                strobe_count += 1
                on_count += 1
            if mid_cross:
                strobe_count += 1
                mid_count += 1

            phase_acc = new_phase

        print(f"phase '{name}': step={step} adj={adj:+d} -> "
              f"{on_count} on-time + {mid_count} mid-point = {strobe_count} "
              f"total strobes across {N_PER_PHASE} samples "
              f"(nominal sps = {SPS})")

    print()
    print(f"Ground-truth cross-check: {ground_truth_checks} crossing events, "
          f"{ground_truth_mismatches} mismatches "
          f"({'PASS' if ground_truth_mismatches == 0 else 'FAIL'})")

    with open('step.hex', 'w') as f:
        f.write('\n'.join(step_lines) + '\n')
    with open('adj.hex', 'w') as f:
        f.write('\n'.join(adj_lines) + '\n')
    with open('expected_strobe.hex', 'w') as f:
        f.write('\n'.join(strobe_lines) + '\n')
    with open('expected_ismid.hex', 'w') as f:
        f.write('\n'.join(ismid_lines) + '\n')
    with open('expected_mu.hex', 'w') as f:
        f.write('\n'.join(mu_lines) + '\n')

    total = len(PHASES) * N_PER_PHASE
    print(f"\nWrote {total} samples across {len(PHASES)} phases to "
          f"step.hex / adj.hex / expected_strobe.hex / expected_ismid.hex / "
          f"expected_mu.hex")


if __name__ == '__main__':
    main()
