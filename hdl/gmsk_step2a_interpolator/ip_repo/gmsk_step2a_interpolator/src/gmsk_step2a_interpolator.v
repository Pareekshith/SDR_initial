`timescale 1ns / 1ps
//
// gmsk_step2a_interpolator -- Sub-step A: cubic Farrow (Lagrange) interpolator
// core, open-loop (mu supplied externally via mu_in, not yet driven by a real
// NCO). See docs/rx_roadmap.html Step 3 and project_fpga_gmsk_plan memory for
// the full sub-step breakdown this belongs to.
//
// Classic 4-point cubic Lagrange interpolation, Farrow form: given four
// consecutive samples x[n-1], x[n], x[n+1], x[n+2] and a fractional offset
// mu in [0,1) (mu=0 -> exactly x[n], mu approaching 1 -> approaching x[n+1]),
// computes the interpolated value at position n+mu.
//
//   y(mu) = v0 + v1*mu + v2*mu^2 + v3*mu^3        (evaluated via Horner)
//   v0 = x[n]
//   v1 = (-2*x[n-1] - 3*x[n] + 6*x[n+1] - x[n+2]) / 6
//   v2 = (x[n-1] - 2*x[n] + x[n+1]) / 2
//   v3 = (-x[n-1] + 3*x[n] - 3*x[n+1] + x[n+2]) / 6
//
// Derived directly from the Lagrange basis polynomials through samples at
// integer positions -1,0,1,2. Verified by construction that y(0)=x[n] and
// y(1)=x[n+1] exactly -- the defining property of Lagrange interpolation
// (the curve passes through every sample it's built from).
//
// This is the real interpolator core, not throwaway test code -- mu is a
// plain streaming input so the same module later takes a continuously
// varying NCO output (Sub-step F) with no redesign; this sub-step just
// exercises it at a few FIXED mu values to verify the math in isolation,
// decoupled from any Gardner/NCO feedback.
//
// Interface matches gmsk_step1_discriminator's convention: AXI4-Stream
// in/out, one input sample per clock (when valid), no rate change,
// s_axis_tready tied high (fixed-rate pipeline, no realistic backpressure).
// mu_in is a plain (non-AXI-Stream) input, latched alongside each valid
// input sample.
//
// /6 and /2 below are CONSTANT-divisor division -- synthesizable, and NOT
// the same cost/timing class as a runtime variable divide: Vivado optimizes
// a compile-time-constant divisor into a multiply-by-reciprocal-plus-shift.
//
module gmsk_step2a_interpolator #
(
    parameter integer IN_WIDTH  = 24,  // matches gmsk_step1_discriminator's OUT_WIDTH
    parameter integer OUT_WIDTH = 24,  // must be a multiple of 8 (AXI4-Stream TDATA rule)
    parameter integer MU_WIDTH  = 16   // mu_in unsigned, mu = mu_in / 2^MU_WIDTH, range [0,1)
)
(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire signed [IN_WIDTH-1:0]    s_axis_tdata,
    input  wire        [MU_WIDTH-1:0]    mu_in,          // fractional offset for this window, in [0,1)

    output reg                           m_axis_tvalid,
    input  wire                          m_axis_tready,
    output reg  signed [OUT_WIDTH-1:0]   m_axis_tdata
);

    assign s_axis_tready = 1'b1;

    // -----------------------------------------------------------------
    // Stage 1: 4-tap delay line, atomic shift -- ALL taps move together in
    // the same always-block condition, gated only by s_axis_tvalid.
    // Deliberately avoiding the exact bug class gmsk_step1_discriminator
    // hit on real hardware (see project memory): splitting a shift across
    // a separately-delayed valid signal duplicates a sample instead of
    // holding the genuinely-previous one, whenever idle cycles separate
    // valid pulses -- which real hardware always has.
    //   x_m1 = x[n-1], x_0 = x[n], x_1 = x[n+1], x_2 = x[n+2]
    // Interpolation happens between x_0 and x_1, using x_m1/x_2 as the
    // outer Lagrange support points.
    // -----------------------------------------------------------------
    reg signed [IN_WIDTH-1:0] x_m1, x_0, x_1, x_2;
    reg        [MU_WIDTH-1:0] mu_d1;
    reg                       valid_d1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            x_m1     <= {IN_WIDTH{1'b0}};
            x_0      <= {IN_WIDTH{1'b0}};
            x_1      <= {IN_WIDTH{1'b0}};
            x_2      <= {IN_WIDTH{1'b0}};
            mu_d1    <= {MU_WIDTH{1'b0}};
            valid_d1 <= 1'b0;
        end else begin
            valid_d1 <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                x_m1  <= x_0;
                x_0   <= x_1;
                x_1   <= x_2;
                x_2   <= s_axis_tdata;
                mu_d1 <= mu_in;
            end
        end
    end

    // -----------------------------------------------------------------
    // Stage 2: Lagrange coefficients v0..v3, computed from the now-stable
    // registered delay-line taps -- one full cycle after the shift, never
    // combinationally chained with the shift itself (same caution as
    // above). Common width NUM_WIDTH for all four so the Horner stages
    // below can treat them uniformly.
    // -----------------------------------------------------------------
    localparam integer NUM_WIDTH = IN_WIDTH + 4;  // headroom for the widest
                                                   // coefficient sum (v1's
                                                   // terms have |coeffs| summing to 12)

    wire signed [NUM_WIDTH-1:0] x_m1_w = {{4{x_m1[IN_WIDTH-1]}}, x_m1};
    wire signed [NUM_WIDTH-1:0] x_0_w  = {{4{x_0[IN_WIDTH-1]}},  x_0};
    wire signed [NUM_WIDTH-1:0] x_1_w  = {{4{x_1[IN_WIDTH-1]}},  x_1};
    wire signed [NUM_WIDTH-1:0] x_2_w  = {{4{x_2[IN_WIDTH-1]}},  x_2};

    reg signed [NUM_WIDTH-1:0] v0_2, v1_2, v2_2, v3_2;
    reg        [MU_WIDTH-1:0]  mu_d2;
    reg                        valid_d2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            v0_2 <= {NUM_WIDTH{1'b0}};
            v1_2 <= {NUM_WIDTH{1'b0}};
            v2_2 <= {NUM_WIDTH{1'b0}};
            v3_2 <= {NUM_WIDTH{1'b0}};
            mu_d2    <= {MU_WIDTH{1'b0}};
            valid_d2 <= 1'b0;
        end else begin
            valid_d2 <= valid_d1;
            mu_d2    <= mu_d1;
            v0_2 <= x_0_w;
            v1_2 <= (-2*x_m1_w - 3*x_0_w + 6*x_1_w - x_2_w) / 6;
            v2_2 <= (x_m1_w - 2*x_0_w + x_1_w) / 2;
            v3_2 <= (-x_m1_w + 3*x_0_w - 3*x_1_w + x_2_w) / 6;
        end
    end

    // -----------------------------------------------------------------
    // Stages 3-5: Horner evaluation y = ((v3*mu + v2)*mu + v1)*mu + v0,
    // one multiply-accumulate per stage (both MAC operands registered each
    // stage -- same DSP48-friendly pattern gmsk_step1_discriminator's real
    // timing fix established). mu is unsigned in [0,1) (mu_in / 2^MU_WIDTH);
    // zero-extended into a signed container one bit wider at each use so
    // the signed(v) * mu multiply isn't silently coerced to unsigned by
    // Verilog's operand-mixing rule (a real correctness pitfall, not just
    // style -- mixing a signed operand with an unsigned one in the same
    // expression makes Verilog treat the whole expression as unsigned).
    // -----------------------------------------------------------------
    localparam integer ACC_WIDTH = NUM_WIDTH + 2;  // guard bits through the MAC chain

    // Multiply-then-shift result, given its own explicitly-widened signal
    // rather than written as a chained inline expression -- confirmed by
    // direct A/B test (see project memory) that XSIM does NOT reliably
    // give ((A*mu)>>>N)+B's multiply its full natural width when it's
    // nested inline feeding a narrower target: the exact same arithmetic
    // gave a wrong answer inline and the right answer once broken into
    // explicit full-width intermediate wires. Real Verilog width-inference
    // pitfall, not a one-off mistake -- worth remembering for any future
    // multiply-accumulate chain in this project.
    localparam integer PROD_WIDTH = ACC_WIDTH + MU_WIDTH + 1;

    reg signed [ACC_WIDTH-1:0] acc_3, acc_4;
    reg signed [NUM_WIDTH-1:0] v1_3, v0_3, v0_4;
    reg        [MU_WIDTH-1:0]  mu_d3, mu_d4;
    reg                        valid_d3, valid_d4;

    // Stage 3: acc_3 = (v3*mu >>> MU_WIDTH) + v2. Carries v0 and v1 forward
    // (v1 needed at stage 4, v0 needed at stage 5) alongside the running
    // Horner accumulator and mu.
    wire signed [PROD_WIDTH-1:0] prod_3   = v3_2 * $signed({1'b0, mu_d2});
    wire signed [PROD_WIDTH-1:0] shifted_3 = prod_3 >>> MU_WIDTH;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc_3 <= {ACC_WIDTH{1'b0}};
            v1_3  <= {NUM_WIDTH{1'b0}};
            v0_3  <= {NUM_WIDTH{1'b0}};
            mu_d3 <= {MU_WIDTH{1'b0}};
            valid_d3 <= 1'b0;
        end else begin
            valid_d3 <= valid_d2;
            acc_3 <= shifted_3 + v2_2;
            v1_3  <= v1_2;
            v0_3  <= v0_2;
            mu_d3 <= mu_d2;
        end
    end

    // Stage 4: acc_4 = (acc_3*mu >>> MU_WIDTH) + v1. Carries v0 forward to stage 5.
    wire signed [PROD_WIDTH-1:0] prod_4    = acc_3 * $signed({1'b0, mu_d3});
    wire signed [PROD_WIDTH-1:0] shifted_4 = prod_4 >>> MU_WIDTH;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc_4 <= {ACC_WIDTH{1'b0}};
            v0_4  <= {NUM_WIDTH{1'b0}};
            mu_d4 <= {MU_WIDTH{1'b0}};
            valid_d4 <= 1'b0;
        end else begin
            valid_d4 <= valid_d3;
            acc_4 <= shifted_4 + v1_3;
            v0_4  <= v0_3;
            mu_d4 <= mu_d3;
        end
    end

    // Stage 5: output = (acc_4*mu >>> MU_WIDTH) + v0. The natural scale of
    // the Horner result already matches the input's scale (Lagrange basis
    // coefficients sum to 1 at any mu -- this is a weighted average of
    // x[-1..2], not a growing product like the discriminator's multiply),
    // so truncating to the low OUT_WIDTH bits is correct here -- unlike
    // gmsk_step1_discriminator's TRUNC_SHIFT, this isn't a deliberate
    // multiplicative rescale, the extra ACC_WIDTH-OUT_WIDTH bits are just
    // guard bits against transient overflow through the MAC chain.
    wire signed [PROD_WIDTH-1:0] prod_5    = acc_4 * $signed({1'b0, mu_d4});
    wire signed [PROD_WIDTH-1:0] shifted_5 = prod_5 >>> MU_WIDTH;
    wire signed [ACC_WIDTH-1:0]  acc_5     = shifted_5 + v0_4;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {OUT_WIDTH{1'b0}};
        end else begin
            m_axis_tvalid <= valid_d4;
            m_axis_tdata  <= acc_5[OUT_WIDTH-1:0];
        end
    end

endmodule
