#!/usr/bin/env python3
"""gen_test_vectors.py -- Sub-step E SIM gate: bit-exact reference model for
gmsk_step2e_loop_filter, mirroring the RTL's own fixed-point PI arithmetic
exactly (hi/lo-split multiplies, per-term shifts, saturating adds) -- see
gmsk_step2e_loop_filter.v's own header for the full design rationale, and
docs/step2e_loop_filter.html for the derivation/intuition.

Two back-to-back phases, matching the DUT's own genuinely stateful
integrator (NOT reset between phases within a run -- this is a real
accumulator, not a per-scenario-independent core like gmsk_step2d_gardner_ted's
own y_on_prev/mid_latched history):
  1. "realistic" -- a repeating mix of small, real-captured-range e[n]
     values (both signs), confirming normal accumulation behaves correctly
     and the integrator's extra GUARD_BITS precision genuinely lets small
     increments accumulate (not truncate to zero every symbol -- the exact
     failure mode caught in docs/step2e_loop_filter.html's own interactive
     demo before this RTL was ever written).
  2. "saturation" -- after an explicit reset (a clean, physically sensible
     re-acquisition boundary), a sustained run of full-scale e[n] designed
     to deliberately overflow an UNPROTECTED integrator/adj_out, confirming
     both actually clamp at their MAX/MIN bounds instead of silently
     wrapping. This phase exists specifically because a real bug (Verilog
     concatenation being unsigned by default, corrupting the saturation
     comparisons) was caught by re-reading the RTL and fixed BEFORE this
     generator was written -- this phase is what actually proves the fix,
     not just trusts the re-reading.

Usage: python gen_test_vectors.py
Output (gitignored, regenerate as needed): phase1_e_in.hex /
        phase1_expected_adj.hex / phase1_expected_integ.hex (production
        gains, drives the testbench's main `dut`) and phase2_e_in.hex /
        phase2_expected_adj.hex / phase2_expected_integ.hex (a much larger
        Ki_INT, drives a separate `dut_sat` instance) -- two separate DUT
        instances because reaching the saturation rails under the
        production gains would take on the order of 2.6e5 symbols, not a
        practical testbench length (see KI_INT_SAT comment below).
"""

IN_WIDTH   = 32
OUT_WIDTH  = 32
GAIN_WIDTH = 18
LOBITS     = 16
GUARD_BITS = 16

# Phase 1 (realistic operation) uses the RTL's own illustrative defaults.
KP_INT, KP_SHIFT = 1, 2
KI_INT, KI_SHIFT = 1, 2

# Phase 2 (saturation stress) uses a SEPARATE, deliberately much more
# aggressive Ki -- with the production Ki_INT=1 above, reaching INTEG_MAX
# under sustained full-scale e[n] takes on the order of 2.6e5 symbols
# (verified: increment/symbol ~5.4e8, INTEG_MAX~1.4e14), impractical for a
# testbench. This phase drives a SEPARATE DUT instance instantiated with
# this larger Ki_INT specifically to reach both saturation rails within a
# reasonable number of test vectors -- exercises the exact same clamp code
# path (the RTL's saturation logic doesn't care what produced a large
# integ_sum_wide, only that it's out of range), just via a shortcut gain
# rather than an impractically long realistic-gain run.
KI_INT_SAT = 8192

HI_WIDTH    = IN_WIDTH - LOBITS
LO_SWIDTH   = LOBITS + 1
INTEG_WIDTH = OUT_WIDTH + GUARD_BITS

MASK_IN    = (1 << IN_WIDTH) - 1
MASK_OUT   = (1 << OUT_WIDTH) - 1
MASK_INTEG = (1 << INTEG_WIDTH) - 1

INTEG_MAX = (1 << (INTEG_WIDTH - 1)) - 1
INTEG_MIN = -(1 << (INTEG_WIDTH - 1))
ADJ_MAX   = (1 << (OUT_WIDTH - 1)) - 1
ADJ_MIN   = -(1 << (OUT_WIDTH - 1))


def sext(v, w):
    v &= (1 << w) - 1
    if v & (1 << (w - 1)):
        v -= (1 << w)
    return v


def to_hex(val, width):
    hexdigits = (width + 3) // 4
    return format(val & ((1 << width) - 1), '0{}x'.format(hexdigits))


def split_mult_e(e, gain_int):
    """Exact mirror of the RTL's Stage 1/2/3: hi/lo split e[n], two
    DSP48-safe partial-product multiplies, shift+add recombine -- an EXACT
    (not approximate) reconstruction of e[n]*gain_int, same category as
    gmsk_step2d_gardner_ted's own hi/lo-split multiply."""
    e = sext(e, IN_WIDTH)
    hi = sext(e >> LOBITS, HI_WIDTH)      # arithmetic (floor) shift, matches Verilog >>>
    lo = e & ((1 << LOBITS) - 1)          # unsigned low bits
    lo_s = sext(lo, LO_SWIDTH)            # zero-extended into a signed container -- always >=0
    ph = hi * gain_int
    pl = lo_s * gain_int
    prod = (ph << LOBITS) + pl
    return prod


def kp_term(e, kp_int, kp_shift):
    # Python's >> already floors toward -inf for negative ints, matching
    # Verilog's >>> arithmetic shift exactly -- no special-casing needed.
    prod = split_mult_e(e, kp_int)
    return prod >> kp_shift


def ki_increment(e, ki_int, ki_shift):
    prod = split_mult_e(e, ki_int)
    return prod >> ki_shift


def sat(v, lo, hi):
    if v > hi:
        return hi
    if v < lo:
        return lo
    return v


class LoopFilterModel:
    """Stateful reference model -- one persistent integrator, exactly
    mirroring the DUT's own Stage 5 (read current integrator for adj_out,
    THEN update it -- the ordering this project has repeatedly needed to
    get right for delay-line/accumulator interactions). Gains are per-
    instance (not module-level globals) so Phase 1's production-gain DUT
    and Phase 2's aggressive-gain saturation-test DUT can each get their
    own correctly-parameterized reference model."""

    def __init__(self, kp_int=KP_INT, kp_shift=KP_SHIFT, ki_int=KI_INT, ki_shift=KI_SHIFT):
        self.integrator = 0
        self.kp_int = kp_int
        self.kp_shift = kp_shift
        self.ki_int = ki_int
        self.ki_shift = ki_shift

    def step(self, e):
        kt = kp_term(e, self.kp_int, self.kp_shift)
        ki_inc = ki_increment(e, self.ki_int, self.ki_shift)

        integ_top = sext(self.integrator, INTEG_WIDTH) >> GUARD_BITS  # arithmetic shift
        # truncate integ_top to OUT_WIDTH domain exactly as the RTL's
        # `wire signed [OUT_WIDTH-1:0] integ_top = integrator >>> GUARD_BITS;`
        # does (INTEG_WIDTH-GUARD_BITS == OUT_WIDTH exactly, by construction,
        # so no extra truncation is actually needed here -- asserted below).
        assert INTEG_WIDTH - GUARD_BITS == OUT_WIDTH

        adj_sum = kt + integ_top
        adj_out = sat(adj_sum, ADJ_MIN, ADJ_MAX)

        integ_sum = sext(self.integrator, INTEG_WIDTH) + ki_inc
        self.integrator = sat(integ_sum, INTEG_MIN, INTEG_MAX)

        return adj_out, self.integrator


def run_phase(model, seq):
    e_lines, adj_lines, integ_lines = [], [], []
    for e in seq:
        adj, integ = model.step(e)
        e_lines.append(to_hex(e, IN_WIDTH))
        adj_lines.append(to_hex(adj, OUT_WIDTH))
        integ_lines.append(to_hex(integ, INTEG_WIDTH))
    return e_lines, adj_lines, integ_lines


def write_hex(prefix, e_lines, adj_lines, integ_lines):
    with open(f'{prefix}_e_in.hex', 'w') as f:
        f.write('\n'.join(e_lines) + '\n')
    with open(f'{prefix}_expected_adj.hex', 'w') as f:
        f.write('\n'.join(adj_lines) + '\n')
    with open(f'{prefix}_expected_integ.hex', 'w') as f:
        f.write('\n'.join(integ_lines) + '\n')


def main():
    # ---- Phase 1: realistic, real-captured-range values (both signs),
    # production gains -- drives the testbench's main `dut`. ----
    model1 = LoopFilterModel()  # production KP_INT/KP_SHIFT/KI_INT/KI_SHIFT defaults
    realistic_seq = [0, 1, 4, 10, 17, 71, -1, -3, -10, 45, -45, 2, -2, 8, -8,
                      71, 71, 71, -71, -71, 0, 5, -5, 12, -12, 30, -30]
    phase1 = (realistic_seq * 8)[:200]

    print(f"Phase 1 (realistic, production gains): {len(phase1)} samples")
    e1, adj1, integ1 = run_phase(model1, phase1)
    for i in list(range(10)) + list(range(len(phase1) - 4, len(phase1))):
        print(f"  n={i:3d} e={phase1[i]:+5d}  adj_out={sext(int(adj1[i], 16), OUT_WIDTH):+d}  "
              f"integrator={sext(int(integ1[i], 16), INTEG_WIDTH):+d}")
    print(f"  final integrator after phase 1: {model1.integrator:+d}  "
          f"(top bits -> {sext(model1.integrator, INTEG_WIDTH) >> GUARD_BITS:+d})")

    # ---- Phase 2: fresh state (matching a real aresetn pulse), deliberately
    # saturate in both directions -- drives a SEPARATE `dut_sat` instance
    # with a much larger Ki_INT (see KI_INT_SAT comment above) so both
    # rails are reachable in a practical number of test vectors. ----
    model2 = LoopFilterModel(ki_int=KI_INT_SAT)
    e_max = (1 << (IN_WIDTH - 1)) - 1
    e_min = -(1 << (IN_WIDTH - 1))
    n_each = 40
    phase2 = [e_max] * n_each + [e_min] * (n_each * 2) + [e_max] * n_each

    print(f"\nPhase 2 (saturation, Ki_INT={KI_INT_SAT}): {len(phase2)} samples")
    e2, adj2, integ2 = run_phase(model2, phase2)
    saw_pos_sat = any(sext(int(v, 16), INTEG_WIDTH) == INTEG_MAX for v in integ2)
    saw_neg_sat = any(sext(int(v, 16), INTEG_WIDTH) == INTEG_MIN for v in integ2)
    for i in list(range(5)) + [n_each - 1, n_each, n_each * 2, n_each * 3 - 1, len(phase2) - 1]:
        integ_v = sext(int(integ2[i], 16), INTEG_WIDTH)
        print(f"  n={i:3d} e={phase2[i]:+d}  adj_out={sext(int(adj2[i], 16), OUT_WIDTH):+d}  "
              f"integrator={integ_v:+d}"
              f"{'  <-- AT INTEG_MAX' if integ_v == INTEG_MAX else ''}"
              f"{'  <-- AT INTEG_MIN' if integ_v == INTEG_MIN else ''}")

    print(f"\nSaturation reached: positive rail={'YES' if saw_pos_sat else 'NO (test is not exercising the clamp!)'}, "
          f"negative rail={'YES' if saw_neg_sat else 'NO (test is not exercising the clamp!)'}")
    assert saw_pos_sat and saw_neg_sat, \
        "Phase 2 must actually reach both saturation rails, or it isn't testing what it claims to."

    write_hex('phase1', e1, adj1, integ1)
    write_hex('phase2', e2, adj2, integ2)

    print(f"\nWrote phase1_*.hex ({len(phase1)} samples, production-gain dut) "
          f"and phase2_*.hex ({len(phase2)} samples, Ki_INT={KI_INT_SAT} dut_sat)")
    print(f"PHASE1_COUNT={len(phase1)} PHASE2_COUNT={len(phase2)}  (for the testbench's own localparams)")


if __name__ == '__main__':
    main()
