"""Numeric design/verification for gmsk_step2e_loop_filter's fixed-point PI
arithmetic, BEFORE committing to RTL widths/shifts -- same discipline every
other sub-step in this project used.

Real constraints to satisfy:
  - e[n] (input): signed 32-bit, matches gmsk_step2d_gardner_ted's OUT_WIDTH.
    Real hardware capture (2026-08-23, iladata1.csv) showed range -10..+71
    in a near-zero-mu, unlocked scenario -- genuinely small values, but
    gardner_ted's own header says OUT_WIDTH is "sized for full-scale worst
    case" so larger real e[n] under different signal conditions is possible.
  - adj_out (output): signed 32-bit Q32, matches gmsk_step2b2_nco's
    STEP_WIDTH/adj_in. STEP_NOMINAL = 2^30 (=0.25, exact 1/4 symbol for
    LOG2_SPS=2). NCO's own documented precondition: |adj_in| << step_in.
  - The integrator must NOT truncate small Ki*e[n] contributions to zero
    every symbol (the exact bug almost written into the educational demo's
    reasoning) -- needs guard bits of extra fractional precision below
    adj_out's own resolution, mirroring the NCO's own wide-accumulator
    pattern (expose only the top bits).
"""

IN_WIDTH  = 32
OUT_WIDTH = 32
STEP_NOMINAL = 1 << 30

GAIN_WIDTH = 18   # Kp_INT/Ki_INT -- comfortably fits DSP48E1's 18-bit "B" operand
LOBITS     = 16   # e[n] hi/lo split point (clean half of a 32-bit operand)
HI_WIDTH   = IN_WIDTH - LOBITS   # 16
LO_SWIDTH  = LOBITS + 1          # 17, zero-extended into a signed container

GUARD_BITS   = 16                        # integrator's extra low-end fractional precision
INTEG_WIDTH  = OUT_WIDTH + GUARD_BITS     # 48

# candidate gain constants -- illustrative, need real-hardware tuning
# (see docs/step2e_loop_filter.html's own callout) -- chosen here just to
# get a sane, non-overflowing, non-truncated-to-zero starting point.
KP_INT, KP_SHIFT = 1, 2      # Kp_term = e[n] >> 2       (quarter of e[n], OUT_WIDTH precision)
KI_INT, KI_SHIFT = 1, 2      # Ki contribution computed at INTEG_WIDTH precision (see below)

def sext(v, w):
    v &= (1 << w) - 1
    if v & (1 << (w - 1)):
        v -= (1 << w)
    return v

def mask(v, w):
    return v & ((1 << w) - 1)

def split_mult_e(e, gain_int):
    """Mirrors the RTL's hi/lo-split DSP48-safe multiply of e[n] * gain."""
    e = sext(e, IN_WIDTH)
    hi = sext(e >> LOBITS, HI_WIDTH) if LOBITS < IN_WIDTH else 0
    # arithmetic shift for hi (sign-preserving), matching >>> in Verilog
    hi = e >> LOBITS  # Python's >> is already arithmetic (floor) for negative ints... need sign-correct hi
    # careful: Python's >> on negative ints floors toward -inf, matching Verilog's >>> (arithmetic) exactly.
    hi = sext(hi, HI_WIDTH)
    lo = mask(e, LOBITS)  # unsigned low bits
    lo_s = sext(lo, LO_SWIDTH)  # zero-extended into a signed container -- always >=0, fits LO_SWIDTH
    ph = hi * gain_int
    pl = lo_s * gain_int
    prod = (ph << LOBITS) + pl   # exact reconstruction of e * gain_int
    return prod

def kp_term(e):
    prod = split_mult_e(e, KP_INT)
    return prod >> KP_SHIFT  # arithmetic shift (Python floor-shift matches >>> for these signs)

def ki_increment(e):
    """Increment added into the WIDE integrator each symbol -- kept at
    INTEG_WIDTH-ish precision (only shifted by KI_SHIFT, not all the way
    down to OUT_WIDTH) so small e[n] still contributes a nonzero amount at
    the integrator's own extra-precision LSBs."""
    prod = split_mult_e(e, KI_INT)
    return prod >> KI_SHIFT

# ---- sanity check 1: does a small real e[n] actually move the integrator? ----
print("=== Ki increment for real captured e[n] values ===")
for e in [1, 4, 10, 71, -10]:
    inc = ki_increment(e)
    print(f"e[n]={e:+4d}  ki_increment={inc:+d}  (as fraction of integrator's own LSB significance)")

# ---- sanity check 2: accumulate many small increments, confirm it moves ----
print("\n=== accumulate ki_increment(71) x 2000 symbols ===")
integ = 0
for n in range(2000):
    integ += ki_increment(71)
    if n in (0, 1, 10, 100, 500, 1000, 1999):
        top = integ >> GUARD_BITS
        print(f"n={n:5d} integ_raw={integ:12d}  integ_top(OUT_WIDTH domain)={top}")

# ---- sanity check 3: adj_out magnitude vs STEP_NOMINAL, worst-case-ish e[n] ----
print("\n=== adj_out for a range of e[n], checking against STEP_NOMINAL precondition ===")
for e in [71, 1000, 100000, 1 << 20, 1 << 24, (1 << 31) - 1]:
    kt = kp_term(e)
    ratio = abs(kt) / STEP_NOMINAL
    print(f"e[n]={e:>12d}  Kp_term={kt:>14d}  |Kp_term|/STEP_NOMINAL={ratio:.6e}")

# ---- sanity check 4: overflow headroom on INTEG_WIDTH ----
max_ki_inc = split_mult_e((1 << (IN_WIDTH-1)) - 1, (1 << (GAIN_WIDTH-1)) - 1) >> KI_SHIFT
print(f"\nmax possible single-symbol ki_increment (full-scale e[n], full-scale Ki_INT) = {max_ki_inc}")
print(f"INTEG_WIDTH={INTEG_WIDTH} range = +-{(1<<(INTEG_WIDTH-1))-1}")
symbols_to_overflow = ((1 << (INTEG_WIDTH-1)) - 1) / max_ki_inc if max_ki_inc else float('inf')
print(f"symbols to overflow at that pathological max rate: {symbols_to_overflow:.3e}")

print("\n=== realistic-case overflow headroom (Ki_INT up to 1024, not full 18-bit) ===")
max_ki_inc_realistic = split_mult_e((1 << (IN_WIDTH-1)) - 1, 1024) >> KI_SHIFT
print(f"max realistic ki_increment (full-scale e[n], Ki_INT=1024) = {max_ki_inc_realistic}")
symbols_realistic = ((1 << (INTEG_WIDTH-1)) - 1) / max_ki_inc_realistic
print(f"symbols to overflow at that rate: {symbols_realistic:.3e}  ({symbols_realistic/(4e6/4):.1f} sec @ 4Msym/s-ish)")

print("\n=== with saturating integrator add, INTEG_WIDTH=48 ===")
INTEG_MAX = (1 << (INTEG_WIDTH - 1)) - 1
INTEG_MIN = -(1 << (INTEG_WIDTH - 1))
def sat_add(a, b, lo=INTEG_MIN, hi=INTEG_MAX):
    r = a + b
    if r > hi: return hi
    if r < lo: return lo
    return r

integ = 0
for n in range(5):
    integ = sat_add(integ, max_ki_inc)  # pathological full-scale increment
    print(f"n={n} integ={integ}  saturated={'YES' if integ in (INTEG_MAX, INTEG_MIN) else 'no'}")
