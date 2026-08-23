#!/usr/bin/env python3
"""analyze_ila_capture.py -- cross-tabulate a system_ila_0 waveform export
(exported CSV from Vivado Hardware Manager) against each signal's own
valid/strobe pulse, instead of eyeballing the waveform view directly.
This project has been burned twice before trusting a visual read alone
(see project_fpga_gmsk_plan memory, "Idle/0 of N false-triggered-capture"
and "always cross-tabulate ... before trusting a visual read") -- this
script is the reusable version of that discipline.

Probe layout as of the 9-probe wiring established 2026-08-16 (see
project_fpga_gmsk_plan memory, "gmsk_step2b2_nco + gmsk_interp_tag_delay
wired into hardware"). Update this mapping if the block design's ILA
probe assignment ever changes:
  probe0[23:0] = gmsk_step1_discriminator  m_axis_tdata
  probe1[0:0]  = gmsk_step1_discriminator  m_axis_tvalid
  probe2[23:0] = gmsk_step2a_interpolator  m_axis_tdata
  probe3[0:0]  = gmsk_step2a_interpolator  m_axis_tvalid
  probe4[0:0]  = gmsk_step2b2_nco          strobe
  probe5[15:0] = gmsk_step2b2_nco          mu_out
  probe6[0:0]  = gmsk_step2d_gardner_ted   m_axis_tvalid
  probe7[31:0] = gmsk_step2d_gardner_ted   m_axis_tdata
  probe8[0:0]  = gmsk_interp_tag_delay     is_midpoint_out (the DELAYED
                 is_midpoint, deliberately not the NCO's raw output --
                 this is the signal whose correctness actually matters
                 for verifying end-to-end alignment into the TED)

Usage: edit `path` below to point at the exported CSV, then run.
"""
import csv

path = r"C:/Users/Parit/Documents/Projects/SDR_initial/hdl/gmsk_step2d_gardner_ted/iladata1.csv"

rows = []
with open(path, newline='') as f:
    r = csv.reader(f)
    header = next(r)
    radix = next(r)
    for row in r:
        rows.append(row)

N = len(rows)
print(f"Total samples: {N}")

# columns: 0=Sample in Buffer,1=Sample in Window,2=TRIGGER,
# 3=probe0(disc tdata,24b),4=probe1(disc tvalid),5=probe2(interp tdata,24b),
# 6=probe3(interp tvalid),7=probe4(NCO strobe),8=probe5(NCO mu_out,16b),
# 9=probe6(TED tvalid),10=probe7(TED tdata,32b),11=probe8(delayed is_midpoint)

def col(i):
    return [int(row[i], 16) for row in rows]

probe0 = col(3)   # disc tdata (24b, signed-ish but stored hex)
probe1 = col(4)   # disc tvalid
probe2 = col(5)   # interp tdata
probe3 = col(6)   # interp tvalid
probe4 = col(7)   # NCO strobe
probe5 = col(8)   # NCO mu_out
probe6 = col(9)   # TED tvalid
probe7 = col(10)  # TED tdata (32b)
probe8 = col(11)  # delayed is_midpoint

def pulse_indices(sig):
    return [i for i,v in enumerate(sig) if v == 1]

def gap_hist(idxs):
    from collections import Counter
    gaps = [idxs[i+1]-idxs[i] for i in range(len(idxs)-1)]
    return Counter(gaps), len(idxs)

print("\n--- probe1 (discriminator tvalid, ADC sample cadence) ---")
p1 = pulse_indices(probe1)
h1, n1 = gap_hist(p1)
print(f"pulses: {n1}, gap histogram: {dict(h1)}")

print("\n--- probe4 (NCO strobe) ---")
p4 = pulse_indices(probe4)
h4, n4 = gap_hist(p4)
print(f"pulses: {n4}, gap histogram: {dict(h4)}")

print("\n--- probe8 (delayed is_midpoint, sampled AT strobe pulses) ---")
mid_vals_at_strobe = [probe8[i] for i in p4]
from collections import Counter
print(f"is_midpoint at strobe instants: {Counter(mid_vals_at_strobe)}")
# check alternation
alt_ok = 0
alt_bad = 0
transitions = []
for i in range(1, len(mid_vals_at_strobe)):
    if mid_vals_at_strobe[i] != mid_vals_at_strobe[i-1]:
        alt_ok += 1
    else:
        alt_bad += 1
print(f"consecutive-strobe transitions (alternating): {alt_ok}, non-alternating (stuck): {alt_bad}")
print(f"first 20 is_midpoint values at strobes: {mid_vals_at_strobe[:20]}")

print("\n--- probe6 (TED tvalid) ---")
p6 = pulse_indices(probe6)
h6, n6 = gap_hist(p6)
print(f"pulses: {n6}, gap histogram: {dict(h6)}")

print("\n--- probe7 (TED tdata) sampled at TED tvalid pulses ---")
def to_signed32(v):
    return v - (1<<32) if v >= (1<<31) else v
ted_vals = [to_signed32(probe7[i]) for i in p6]
nonzero = sum(1 for v in ted_vals if v != 0)
print(f"TED output samples: {len(ted_vals)}, nonzero: {nonzero}, zero: {len(ted_vals)-nonzero}")
if ted_vals:
    print(f"min={min(ted_vals)}, max={max(ted_vals)}, distinct values={len(set(ted_vals))}")
    print(f"first 20 TED outputs: {ted_vals[:20]}")

print("\n--- probe5 (NCO mu_out) sampled at strobe pulses ---")
mu_vals = [probe5[i] for i in p4]
print(f"distinct mu values: {len(set(mu_vals))}, min={min(mu_vals)}, max={max(mu_vals)}")
print(f"first 20 mu values: {mu_vals[:20]}")

print("\n--- probe0 (discriminator tdata) sampled at probe1 pulses ---")
disc_vals = [probe0[i] for i in p1]
def to_signed24(v):
    return v - (1<<24) if v >= (1<<23) else v
disc_vals_s = [to_signed24(v) for v in disc_vals]
print(f"distinct: {len(set(disc_vals_s))}, min={min(disc_vals_s)}, max={max(disc_vals_s)}")

print("\n--- probe3 (interpolator tvalid) ---")
p3 = pulse_indices(probe3)
h3, n3 = gap_hist(p3)
print(f"pulses: {n3}, gap histogram: {dict(h3)}")

print("\n--- probe2 (interpolator tdata) sampled at probe3 pulses ---")
interp_vals = [to_signed24(probe2[i]) for i in p3]
print(f"distinct: {len(set(interp_vals))}, min={min(interp_vals)}, max={max(interp_vals)}")
