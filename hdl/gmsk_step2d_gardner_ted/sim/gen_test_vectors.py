#!/usr/bin/env python3
"""gen_test_vectors.py -- Sub-step D SIM gate: bit-exact reference model for
gmsk_step2d_gardner_ted, PLUS an independent physical-meaning check that the
Gardner error's sign genuinely tracks early/late sampling.

Test signal: a sum of alternating-sign Gaussian pulses, one per NRZ symbol --

    y(t) = sum_k b_k * exp(-(t - k*T)^2 / (2*sigma^2)),   b_k = +1 if k even else -1

This is a faithful stand-in for what this project's real discriminator output
looks like for a real "1,0,1,0,..." alternating pattern: each transmitted
symbol contributes one Gaussian-shaped bump of instantaneous-frequency
deviation, alternating sign, smoothly overlapping its neighbors -- not an
arbitrary convenience function the way gmsk_step2a_interpolator's sine test
was (that one was chosen specifically because a sine has an exact value
anywhere; this one is chosen because it's what Gardner is actually built to
track: a signal with meaningful transitions between symbols).

For each of three timing-offset scenarios (eps = 0, +EPS, -EPS, as a fraction
of one symbol period T), every ON-TIME and MID-POINT sample position is
shifted by the SAME eps*T before evaluating y(t) -- eps=0 means the RTL is
handed genuinely correctly-timed samples (loop already locked); eps!=0 means
every sample is consistently early/late by the same amount (an untracked,
uncorrected timing error). This is exactly the condition Gardner's error
term is designed to detect and report the sign of.

Two independent things are checked, not just one:
  1. Bit-exact match against the RTL's own fixed-point arithmetic (the SIM
     gate's actual pass/fail criterion) -- pure integer math, no rounding
     tolerance needed, same rigor as gmsk_step2b_nco's own generator.
  2. A printed (non-gating) physical sanity check: does the AVERAGE error
     across many symbols come out near zero at eps=0, and does it flip sign
     between +EPS and -EPS? This is the check that answers "is Gardner's
     algorithm itself doing its job," distinct from "does the RTL match its
     own spec" -- same two-tier rigor gmsk_step2a_interpolator used (y(0)=x[n]
     boundary-condition check, on top of the RTL-vs-python bit match).

Usage: python gen_test_vectors.py
Output (gitignored, regenerate as needed): tdata.hex, is_midpoint.hex,
        expected.hex, expected_valid.hex -- one line per driven sample,
        three epsilon scenarios concatenated back-to-back (accumulator/
        history state reset between scenarios via a real aresetn pulse in
        the testbench, since each scenario is a physically distinct
        timing condition, not a continuation of the previous one).
"""
import math

IN_WIDTH   = 24
OUT_WIDTH  = 32
LOBITS     = 15
N_SYMBOLS  = 60          # symbols per epsilon scenario
SETTLE_SYMBOLS = 4        # skip this many at the start of each scenario (Gaussian-sum edge truncation + the very first no-real-previous sample)
T          = 1.0          # symbol period, arbitrary units
BT_LIKE    = 0.4          # shape parameter -- wider BT_LIKE = narrower Gaussian (mirrors tx_gmsk_debug.c's own inverse BT convention)
SIGMA      = T / (2 * math.pi * BT_LIKE)
AMPLITUDE  = 300000        # matches the rough magnitude gmsk_step2a_interpolator's own generator used
EPS_LIST   = [0.0, 0.15, -0.15]   # fraction of T: locked, sampling-early-ish, sampling-late-ish (sign convention verified empirically below, not assumed)
SUM_HALF_WIDTH = 8         # sum +/- this many neighboring symbol pulses -- Gaussian decays fast, this is comfortably converged

MASK_IN  = (1 << IN_WIDTH) - 1
MASK_OUT = (1 << OUT_WIDTH) - 1
DIFF_WIDTH = IN_WIDTH + 1
HI_WIDTH   = IN_WIDTH - LOBITS
PRODW      = DIFF_WIDTH + IN_WIDTH
TRUNC_SHIFT = PRODW - OUT_WIDTH


def nrz(k):
    return 1.0 if (k % 2 == 0) else -1.0


def y(t, k_center):
    """Continuous test signal evaluated at time t, summing neighboring
    symbol pulses around k_center (the nearest integer symbol index) for
    efficiency -- Gaussian tails beyond SUM_HALF_WIDTH*T are negligible."""
    total = 0.0
    for k in range(k_center - SUM_HALF_WIDTH, k_center + SUM_HALF_WIDTH + 1):
        dt = t - k * T
        total += nrz(k) * math.exp(-(dt * dt) / (2 * SIGMA * SIGMA))
    return total


def to_signed_hex(val, width):
    val = int(round(val))
    maxval = (1 << (width - 1)) - 1
    minval = -(1 << (width - 1))
    val = max(minval, min(maxval, val))
    if val < 0:
        val += 1 << width
    hexdigits = (width + 3) // 4
    return format(val, '0{}x'.format(hexdigits))


def quantize(v):
    """Same clamp-and-round the RTL's fixed-point representation implies."""
    maxval = (1 << (IN_WIDTH - 1)) - 1
    minval = -(1 << (IN_WIDTH - 1))
    iv = int(round(v))
    return max(minval, min(maxval, iv))


def sign_extend(val, width):
    if val & (1 << (width - 1)):
        return val - (1 << width)
    return val


def rtl_mirror_step(y_on_prev, mid_latched, sample_val, is_mid):
    """Mirrors the RTL's stage-1 arithmetic exactly (integer, fixed-point),
    returning (new_y_on_prev, new_mid_latched, produced_error_or_None)."""
    if is_mid:
        return y_on_prev, sample_val, None

    diff = sample_val - y_on_prev          # DIFF_WIDTH-bit signed, natural range
    mid_1 = mid_latched
    # Python's >> on a (possibly negative) int is already an arithmetic
    # (floor) shift, identical to Verilog's >>> on a signed value -- no
    # special-casing needed.
    mid_hi = mid_1 >> LOBITS
    mid_lo = mid_1 & ((1 << LOBITS) - 1)   # low LOBITS bits, unsigned magnitude, matches Verilog's mid_1[LOBITS-1:0]

    ph = diff * mid_hi
    pl = diff * mid_lo                      # mid_lo already non-negative (unsigned slice); zero-extension in Verilog is a no-op on the numeric value

    prod = (ph << LOBITS) + pl              # exact natural-width product, matches (ph_3<<<LOBITS)+pl_3
    err = prod >> TRUNC_SHIFT                # Python's >> on a (possibly negative) int is arithmetic, matches Verilog's >>>

    return sample_val, mid_1, err


def main():
    tdata_lines = []
    ismid_lines = []
    expected_lines = []
    expected_valid_lines = []
    expected_ontime_lines = []  # one entry per REAL DUT output pulse, in order -- what the testbench actually checks against, self-synchronizing on m_axis_tvalid the same way gmsk_step1_discriminator/gmsk_step2a_interpolator's own testbenches do (NOT drive-index-aligned, since this DUT is a 5-stage pipeline, not the 1-stage case gmsk_step2b_nco's simpler testbench pattern assumed)

    scenario_reports = []

    for eps in EPS_LIST:
        y_on_prev = 0
        mid_latched = 0
        errors_this_scenario = []

        # First event: ON(0), establishes y_on_prev, produced error discarded
        # (no real previous on-time sample exists yet -- matches the RTL's
        # own reset-value-0 behavior, not a special case in the RTL itself).
        v0 = quantize(AMPLITUDE * y(0 * T + eps * T, 0))
        tdata_lines.append(to_signed_hex(v0, IN_WIDTH))
        ismid_lines.append('0')
        y_on_prev, mid_latched, err0 = rtl_mirror_step(y_on_prev, mid_latched, v0, False)
        expected_lines.append(to_signed_hex(err0, OUT_WIDTH))
        expected_valid_lines.append('1')  # DUT does produce a pulse here -- just not checked for "meaningfulness" (settle sample)
        expected_ontime_lines.append(to_signed_hex(err0, OUT_WIDTH))

        for k in range(1, N_SYMBOLS + 1):
            # MID(k-0.5)
            t_mid = (k - 0.5) * T + eps * T
            vmid = quantize(AMPLITUDE * y(t_mid, k))
            tdata_lines.append(to_signed_hex(vmid, IN_WIDTH))
            ismid_lines.append('1')
            y_on_prev, mid_latched, err_none = rtl_mirror_step(y_on_prev, mid_latched, vmid, True)
            expected_lines.append(to_signed_hex(0, OUT_WIDTH))  # don't-care, DUT produces no pulse for a MID sample
            expected_valid_lines.append('0')

            # ON(k)
            t_on = k * T + eps * T
            von = quantize(AMPLITUDE * y(t_on, k))
            tdata_lines.append(to_signed_hex(von, IN_WIDTH))
            ismid_lines.append('0')
            y_on_prev, mid_latched, err = rtl_mirror_step(y_on_prev, mid_latched, von, False)
            expected_lines.append(to_signed_hex(err, OUT_WIDTH))
            expected_valid_lines.append('1')
            expected_ontime_lines.append(to_signed_hex(err, OUT_WIDTH))

            if k > SETTLE_SYMBOLS:
                errors_this_scenario.append(err)

        avg_err = sum(errors_this_scenario) / len(errors_this_scenario)
        scenario_reports.append((eps, avg_err, len(errors_this_scenario)))

    with open('tdata.hex', 'w') as f:
        f.write('\n'.join(tdata_lines) + '\n')
    with open('is_midpoint.hex', 'w') as f:
        f.write('\n'.join(ismid_lines) + '\n')
    with open('expected.hex', 'w') as f:
        f.write('\n'.join(expected_lines) + '\n')
    with open('expected_valid.hex', 'w') as f:
        f.write('\n'.join(expected_valid_lines) + '\n')
    with open('expected_ontime.hex', 'w') as f:
        f.write('\n'.join(expected_ontime_lines) + '\n')

    total = len(tdata_lines)
    print(f"Wrote {total} samples across {len(EPS_LIST)} epsilon scenarios "
          f"({N_SYMBOLS} symbols/scenario, {len(expected_ontime_lines)} real "
          f"output pulses expected) to tdata.hex / is_midpoint.hex / "
          f"expected.hex / expected_valid.hex / expected_ontime.hex")
    print()
    print("Physical sanity check (average Gardner error per scenario, "
          "settle symbols excluded -- NOT the SIM gate's pass/fail criterion, "
          "just confirms the algorithm behaves as timing-recovery theory predicts):")
    for eps, avg_err, n in scenario_reports:
        print(f"  eps={eps:+.2f}T  avg_err={avg_err:+.1f}  (n={n} symbols)")

    locked = [r for r in scenario_reports if r[0] == 0.0][0][1]
    pos = [r for r in scenario_reports if r[0] > 0.0][0][1]
    neg = [r for r in scenario_reports if r[0] < 0.0][0][1]
    print()
    if abs(locked) < abs(pos) and abs(locked) < abs(neg) and (pos > 0) != (neg > 0):
        print("PASS (physical sanity): locked scenario near zero, "
              "+eps/-eps scenarios flip sign, as timing-recovery theory predicts.")
    else:
        print("NOTE: physical sanity pattern not as expected -- inspect the "
              "numbers above before trusting this test signal's calibration.")


if __name__ == '__main__':
    main()
