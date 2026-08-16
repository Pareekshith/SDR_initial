`timescale 1ns / 1ps
//
// gmsk_step2b2_nco -- Sub-step B2: dual-threshold phase-accumulator NCO,
// extending gmsk_step2b_nco with a second (mid-symbol) strobe so
// gmsk_step2d_gardner_ted can be fed real on-time/mid-point sample pairs
// instead of the degenerate is_midpoint=0 baseline it's been tested with
// so far. See docs/rx_roadmap.html Step 3, project_fpga_gmsk_plan memory
// ("Architecture decision: mid-point-sample generation, for sub-step F")
// for the full reasoning, and docs/step2b_nco.html's own "Sub-step B2"
// section for the intuitive walkthrough.
//
// gmsk_step2b_nco (sub-step B, done + hardware-validated) is left
// untouched -- this is a NEW, separate module, not an edit to the
// existing one, matching this project's convention of keeping earlier
// sub-step artifacts intact and addressable (gmsk_step1a_ila_counter next
// to gmsk_step1_discriminator, etc.) rather than overwriting a validated
// core.
//
// Same free-running modulo-1 phase-accumulator core as sub-step B, but
// now watching for TWO threshold crossings per symbol period instead of
// one: the existing 1.0/wrap crossing (the on-time instant) AND a NEW
// 0.5 crossing (the mid-symbol instant, exactly halfway between two
// on-time instants). Both events share the same strobe/mu_out pair, with
// a new is_midpoint tag saying which kind just fired -- exactly the
// interleaved ON,MID,ON,MID,... stream gmsk_step2d_gardner_ted's
// is_midpoint protocol already expects.
//
// The genuinely useful discovery here (verified numerically before
// writing this RTL, see project memory -- an earlier verbal description
// of this mechanism was wrong and caught before being trusted): mu_out's
// EXISTING bit-select ([HIBIT:LOBIT] of new_phase_w) is ALREADY the
// correct mu for the mid-point crossing too, completely unmodified. No
// extra shift, no doubling, no second bit-select. Why: the mid-point mu
// formula (x-0.5)*sps*2^MU_WIDTH expands to the on-time formula
// (x*sps*2^MU_WIDTH) minus 0.5*sps*2^MU_WIDTH -- and since sps is always
// even (a power of two, LOG2_SPS>=1), that subtracted term is an exact
// integer multiple of 2^MU_WIDTH, so it vanishes completely under the
// MU_WIDTH-bit truncation the hardware already does regardless. The only
// genuinely new logic this module needs beyond sub-step B is the
// mid-crossing DETECTION itself (comparing the accumulator's top bit
// before/after this cycle's add), not any new mu arithmetic.
//
// Correctness precondition (same category as sub-step B's own, still
// relied on here): step_in stays comfortably under 0.5 (true for any
// sane sps>=2), so the two crossings are mutually exclusive within any
// single cycle -- never both fire the same cycle. This is what lets a
// single strobe/is_midpoint/mu_out output triple represent either event
// unambiguously.
//
module gmsk_step2b2_nco #
(
    parameter integer STEP_WIDTH = 32,  // phase accumulator + step precision (fraction of one SYMBOL period, 2^STEP_WIDTH = 1.0)
    parameter integer MU_WIDTH   = 16,  // mu_out width -- matches gmsk_step2a_interpolator's MU_WIDTH/mu_in exactly
    parameter integer LOG2_SPS   = 2    // log2(nominal samples/symbol) -- MUST be a power-of-2 exponent, MUST be >=1 (see header's "sps always even" reasoning). Default 2 = 4 sps, this project's real target.
)
(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          sample_valid,   // one pulse per arriving sample -- this module's clock enable, see gmsk_step2b_nco's header for why it isn't named s_axis_tvalid

    input  wire        [STEP_WIDTH-1:0]  step_in,        // nominal per-sample phase increment, unsigned Q(STEP_WIDTH) fraction of one symbol period. For LOG2_SPS=2: nominal step_in = 2^(STEP_WIDTH-2) exactly.
    input  wire signed [STEP_WIDTH-1:0]  adj_in,         // signed loop-filter correction, added to step_in before accumulating. Tie to 0 for open-loop/standalone use.

    output reg                           strobe,         // pulses exactly on the sample where EITHER threshold (0.5 or 1.0) is crossed -- an on-time OR a mid-point instant
    output reg                           is_midpoint,    // valid alongside strobe: 1 = this strobe is the mid-symbol (0.5) crossing, 0 = the on-time (1.0/wrap) crossing
    output reg          [MU_WIDTH-1:0]   mu_out          // fractional offset (within the CURRENT input sample) of whichever instant just fired -- feeds gmsk_step2a_interpolator's mu_in directly, same [0,1) scale/width convention, SAME bit-select for both crossing types (see header)
);

    localparam integer HIBIT = STEP_WIDTH - 1 - LOG2_SPS;             // 29 for the defaults
    localparam integer LOBIT = STEP_WIDTH - LOG2_SPS - MU_WIDTH;      // 14 for the defaults

    // -----------------------------------------------------------------
    // Single registered stage: phase_acc + step_in + adj_in in one cycle,
    // same plain-add design as gmsk_step2b_nco (no multiplier anywhere in
    // this module, so none of the DSP48/SRL lessons elsewhere in this
    // project apply here).
    // -----------------------------------------------------------------
    reg  [STEP_WIDTH-1:0] phase_acc;

    wire signed [STEP_WIDTH+1:0] sum_ext =
        $signed({2'b00, phase_acc}) + $signed({2'b00, step_in}) +
        {{2{adj_in[STEP_WIDTH-1]}}, adj_in};

    wire                   wrap_w      = sum_ext[STEP_WIDTH];        // crossed the 2^STEP_WIDTH boundary this sample -- on-time instant
    wire [STEP_WIDTH-1:0]  new_phase_w = sum_ext[STEP_WIDTH-1:0];    // natural mod-2^STEP_WIDTH wraparound

    // Mid-crossing detection: did the accumulator's top bit (which is 1
    // exactly when phase_acc >= 0.5 of a symbol) flip 0->1 this cycle,
    // WITHOUT a full wrap happening in the same cycle? That flip is the
    // 0.5-crossing -- the mid-symbol instant. Excluding the wrap case
    // (mutually exclusive per the header's precondition) avoids ever
    // double-counting a single cycle as both events.
    wire                   old_top_w   = phase_acc[STEP_WIDTH-1];
    wire                   new_top_w   = new_phase_w[STEP_WIDTH-1];
    wire                   mid_cross_w = !wrap_w && !old_top_w && new_top_w;

    // mu is the SAME bit-select for both crossing types -- see header for
    // why this is exact, not an approximation, and verified numerically
    // before this RTL was written.
    wire [MU_WIDTH-1:0]    mu_w        = new_phase_w[HIBIT:LOBIT];

    always @(posedge aclk) begin
        if (!aresetn) begin
            phase_acc   <= {STEP_WIDTH{1'b0}};
            strobe      <= 1'b0;
            is_midpoint <= 1'b0;
            mu_out      <= {MU_WIDTH{1'b0}};
        end else begin
            strobe <= 1'b0;  // default: pulses for exactly the one cycle below, held low otherwise
            if (sample_valid) begin
                phase_acc <= new_phase_w;
                if (wrap_w) begin
                    strobe      <= 1'b1;
                    is_midpoint <= 1'b0;
                    mu_out      <= mu_w;
                end else if (mid_cross_w) begin
                    strobe      <= 1'b1;
                    is_midpoint <= 1'b1;
                    mu_out      <= mu_w;
                end
            end
        end
    end

endmodule
