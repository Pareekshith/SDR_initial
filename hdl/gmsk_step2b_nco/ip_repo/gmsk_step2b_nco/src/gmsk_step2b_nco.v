`timescale 1ns / 1ps
//
// gmsk_step2b_nco -- Sub-step B: free-running modulo-1 phase-accumulator NCO
// that generates the strobe/mu pair driving the timing-recovery loop. See
// docs/rx_roadmap.html Step 3 and project_fpga_gmsk_plan memory for the full
// sub-step breakdown this belongs to (A = interpolator core, done and
// hardware-validated; B = this module; D = Gardner TED, standalone, not yet
// built; F = the closed loop wiring A+B+D+loop-filter together).
//
// Standard "free-running NCO" symbol-timing scheme (e.g. Rice, "Digital
// Communications: A Discrete-Time Approach", the modulo-1 counter approach
// also described in Mengali & D'Andrea): a phase accumulator, scaled so that
// one full wrap (2^STEP_WIDTH) represents exactly one SYMBOL period, is
// advanced by a fixed per-sample increment `step_in` (nominally 1/sps, sps =
// samples/symbol) every time a new input sample arrives. Whenever the
// accumulator would cross its wrap point, that crossing marks the estimated
// symbol instant -- `strobe` pulses for exactly that one sample, and the
// wrapped remainder (rescaled from symbol-period units to SAMPLE-period
// units, see below) becomes `mu_out`: the fractional offset, within the
// CURRENT input sample, of the true symbol center. This is the exact `mu`
// gmsk_step2a_interpolator's `mu_in` expects (same [0,1) meaning: mu=0 ->
// exactly the current sample, mu approaching 1 -> approaching the next).
//
// Unit-conversion note (why the mu extraction below is a bare bit-select,
// not a multiply/divide): `step_in` is 1/sps expressed as a fraction of a
// SYMBOL period. The wrapped remainder is therefore also in symbol-period
// units, but mu needs to be in SAMPLE-period units -- since one symbol
// period equals exactly `sps` samples, converting remainder-in-symbols to
// mu-in-samples means multiplying by sps, i.e. shifting the fixed-point
// binary point left by LOG2_SPS bits. Multiplying/dividing by a power of 2
// is free in fixed-point (a bit-select, not an adder or DSP48) -- this is
// exactly why LOG2_SPS must be a genuine power-of-2 exponent, not an
// arbitrary sps. This project's real target is 4 samples/symbol (see
// project_fpga_gmsk_plan memory, "Major requirements pivot"), i.e.
// LOG2_SPS=2, so this isn't a contrived simplification, it's the actual
// operating point. If `adj_in` (below) is nonzero, the true instantaneous
// sps drifts slightly away from the nominal 2^LOG2_SPS and this bit-select
// becomes a small, well-known, deliberately-accepted approximation (using
// the NOMINAL sps to rescale mu instead of the true instantaneous one) --
// standard practice in real timing loops, since the loop-filter correction
// is always small relative to the nominal step.
//
// No s_axis/m_axis AXI4-Stream naming here, deliberately, unlike every
// other module in this project so far: this core carries no data payload
// (no tdata) -- it only needs to know WHEN a new input sample arrived, not
// what its value was. `sample_valid` plays the same "clock enable" role
// s_axis_tvalid does elsewhere, `strobe` plays the same "exactly one pulse
// per event" role m_axis_tvalid does -- named plainly since there's no
// matching tdata for Vivado's packager to hang a real bus interface off of
// (same category of plain, non-bus port as the interpolator's own `mu_in`).
//
// `adj_in` is threaded through now, unused in this sub-step's own SIM gate
// (tied to 0 throughout), so the real (future) Gardner loop-filter output
// plugs straight in at sub-step F with no redesign -- same "build the real
// core now, exercise it standalone first" philosophy gmsk_step2a_interpolator
// used for its own mu_in port.
//
// Correctness precondition (not enforced in hardware, documented here): this
// module assumes step_in + adj_in never drives the accumulator negative and
// never wraps more than once in a single sample (i.e. |adj_in| stays small
// relative to step_in, and step_in itself stays comfortably below 2^STEP_WIDTH
// -- true for any sane sps>=2 and any realistic loop-filter trim). Whoever
// drives adj_in (sub-step E/F's loop filter) is responsible for keeping the
// correction within this range.
//
module gmsk_step2b_nco #
(
    parameter integer STEP_WIDTH = 32,  // phase accumulator + step precision (fraction of one SYMBOL period, 2^STEP_WIDTH = 1.0)
    parameter integer MU_WIDTH   = 16,  // mu_out width -- matches gmsk_step2a_interpolator's MU_WIDTH/mu_in exactly
    parameter integer LOG2_SPS   = 2    // log2(nominal samples/symbol) -- MUST be a power-of-2 exponent (see header). Default 2 = 4 sps, this project's real target.
)
(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          sample_valid,   // one pulse per arriving sample -- this module's clock enable, see header for why it isn't named s_axis_tvalid

    input  wire        [STEP_WIDTH-1:0]  step_in,        // nominal per-sample phase increment, unsigned Q(STEP_WIDTH) fraction of one symbol period. For LOG2_SPS=2: nominal step_in = 2^(STEP_WIDTH-2) exactly.
    input  wire signed [STEP_WIDTH-1:0]  adj_in,         // signed loop-filter correction, added to step_in before accumulating. Tie to 0 for open-loop/standalone use -- this sub-step's SIM gate does exactly that (plus two small nonzero cases to prove the mechanism works before it's ever wired to a real loop filter).

    output reg                           strobe,         // pulses exactly on the sample where the accumulator wraps -- the estimated symbol instant
    output reg          [MU_WIDTH-1:0]   mu_out          // fractional offset (within the CURRENT input sample) of the true symbol instant -- valid every cycle strobe is high, feeds gmsk_step2a_interpolator's mu_in directly
);

    localparam integer HIBIT = STEP_WIDTH - 1 - LOG2_SPS;             // 29 for the defaults
    localparam integer LOBIT = STEP_WIDTH - LOG2_SPS - MU_WIDTH;      // 14 for the defaults

    // -----------------------------------------------------------------
    // Single registered stage: phase_acc + step_in + adj_in in one cycle.
    // Unlike gmsk_step2a_interpolator, this is a plain add (no multiply),
    // comfortably fast at this clock rate even at full STEP_WIDTH -- none
    // of that module's DSP48/SRL/hi-lo-split lessons apply here, there is
    // no multiplier in this design at all.
    //
    // sum_ext is STEP_WIDTH+2 bits: +1 for the wrap/carry-out bit, +1 more
    // of headroom so a signed add with adj_in has room to be evaluated
    // correctly before being range-checked against the documented
    // single-wrap precondition above.
    // -----------------------------------------------------------------
    reg  [STEP_WIDTH-1:0] phase_acc;

    wire signed [STEP_WIDTH+1:0] sum_ext =
        $signed({2'b00, phase_acc}) + $signed({2'b00, step_in}) +
        {{2{adj_in[STEP_WIDTH-1]}}, adj_in};

    wire                   wrap_w     = sum_ext[STEP_WIDTH];       // crossed the 2^STEP_WIDTH boundary this sample
    wire [STEP_WIDTH-1:0]  new_phase_w = sum_ext[STEP_WIDTH-1:0];   // natural mod-2^STEP_WIDTH wraparound
    wire [MU_WIDTH-1:0]    mu_w        = new_phase_w[HIBIT:LOBIT];  // bit-select rescale, see header

    always @(posedge aclk) begin
        if (!aresetn) begin
            phase_acc <= {STEP_WIDTH{1'b0}};
            strobe    <= 1'b0;
            mu_out    <= {MU_WIDTH{1'b0}};
        end else begin
            strobe <= 1'b0;  // default: pulses for exactly the one cycle below, held low otherwise
            if (sample_valid) begin
                phase_acc <= new_phase_w;
                strobe    <= wrap_w;
                mu_out    <= mu_w;
            end
        end
    end

endmodule
