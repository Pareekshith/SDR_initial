`timescale 1ns / 1ps
//
// gmsk_interp_tag_delay -- integration glue for wiring gmsk_step2b2_nco
// into gmsk_step2d_gardner_ted through gmsk_step2a_interpolator, see
// project_fpga_gmsk_plan memory for the full account of why this exists.
//
// The problem: gmsk_step2b2_nco computes strobe/is_midpoint/mu_out on the
// SAME cycle it feeds mu_in to the interpolator. But the interpolator
// itself is a 19-stage registered pipeline (confirmed by direct count of
// `always @(posedge aclk)` blocks in gmsk_step2a_interpolator.v -- verify
// that count again if this module's own DELAY_CYCLES parameter is ever
// suspected stale, e.g. after a future edit to the interpolator) -- it
// takes 19 cycles for that mu_in to actually produce the corresponding
// m_axis_tdata. Feeding the TED today's is_midpoint tag alongside
// whatever the interpolator happens to output THIS cycle would silently
// pair the wrong tag with the wrong sample -- not a crash, just quietly
// wrong data.
//
// The fix is purely mechanical: delay strobe/is_midpoint by the SAME 19
// cycles, so they land on the exact cycle the interpolator's own matching
// output does. Safe to do with a plain, unconditionally-shifting register
// (not gated by any valid/enable signal) because the interpolator's own
// pipeline was confirmed to behave the same way -- every stage updates
// every clock cycle regardless of gaps in the real sample-valid signal,
// so the latency is a fixed, deterministic constant, not something that
// stalls or varies with real ADC timing gaps.
//
// The delayed strobe_out is intended to directly replace whatever
// currently drives gmsk_step2d_gardner_ted's s_axis_tvalid (previously
// the interpolator's own m_axis_tvalid, which fires every real sample,
// not just at genuine on-time/mid-point instants) -- since strobe_out is
// already time-aligned with a cycle where the interpolator's output is
// both valid AND meaningful, no separate AND-gating against
// m_axis_tvalid is needed.
//
module gmsk_interp_tag_delay #
(
    parameter integer DELAY_CYCLES = 19  // matches gmsk_step2a_interpolator's CURRENT pipeline depth -- see header
)
(
    input  wire aclk,
    input  wire aresetn,

    input  wire strobe_in,
    input  wire is_midpoint_in,

    output wire strobe_out,
    output wire is_midpoint_out
);

    reg [DELAY_CYCLES-1:0] strobe_sr;
    reg [DELAY_CYCLES-1:0] ismid_sr;

    always @(posedge aclk) begin
        if (!aresetn) begin
            strobe_sr <= {DELAY_CYCLES{1'b0}};
            ismid_sr  <= {DELAY_CYCLES{1'b0}};
        end else begin
            strobe_sr <= {strobe_sr[DELAY_CYCLES-2:0], strobe_in};
            ismid_sr  <= {ismid_sr[DELAY_CYCLES-2:0], is_midpoint_in};
        end
    end

    assign strobe_out      = strobe_sr[DELAY_CYCLES-1];
    assign is_midpoint_out = ismid_sr[DELAY_CYCLES-1];

endmodule
