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
    // x_m1..x_2 are deliberately NOT marked srl_style -- each tap is read
    // directly by Stage 2's combinational coefficient math every cycle, so
    // Vivado can't SRL-extract them anyway (SRL extraction only applies
    // when the intermediate taps are otherwise unused). mu_d1/valid_d1
    // marked defensively -- cheap insurance, same reasoning as the Horner
    // stages below.
    reg signed [IN_WIDTH-1:0] x_m1, x_0, x_1, x_2;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_d1;
    (* srl_style = "register" *) reg                valid_d1;

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
    // Stages 2a/2b/2c: Lagrange coefficients v0..v3, computed from the
    // now-stable registered delay-line taps -- one full cycle after the
    // shift, never combinationally chained with the shift itself (same
    // caution as above). Common width NUM_WIDTH for all four so the Horner
    // stages below can treat them uniformly.
    //
    // Real-hardware bug found and fixed (2026-08-03), after the DSP48 and
    // SRL fixes above still left WNS around -20ns: the failing path had
    // moved AGAIN, this time to x_1_reg -> v1_2_reg -- i.e. THIS stage,
    // which was never touched by either earlier fix. 23.7ns / 39 logic
    // levels / 30 CARRY4s computing a single coefficient
    // (-2*x[-1]-3*x[0]+6*x[1]-x[2])/6 combinationally in one cycle. Same
    // underlying lesson as the Horner stages -- constant multiplies by
    // non-power-of-2 values (2, 3, 6) plus a constant division, all
    // combined in one un-pipelined cycle, are NOT free at this clock rate
    // for NUM_WIDTH-wide operands, even though "small constant" made them
    // look cheap on paper. Fix: split into three sub-stages -- scale
    // (single shift/shift-add each), sum (pure adds of already-scaled
    // registered values, no multiplies), divide (isolated in its own
    // cycle, same as every other constant-divisor operation in this
    // module). Costs 2 more cycles of latency, irrelevant to this
    // fixed-rate block.
    //
    // Correctness note: x_m1/x_0/x_1/x_2 are free-running taps that can
    // shift to a NEWER window on the very next valid sample. Stage 2b
    // cannot reference them again a cycle after Stage 2a already sampled
    // them -- it would silently mix an old (scaled) term from window W
    // with a new (re-read) term from window W+1. So Stage 2a registers
    // PLAIN forwarded copies of every tap Stage 2b still needs, alongside
    // the scaled terms -- Stage 2b onward never touches x_m1/x_0/x_1/x_2
    // directly again.
    // -----------------------------------------------------------------
    localparam integer NUM_WIDTH = IN_WIDTH + 4;  // headroom for the widest
                                                   // coefficient sum (v1's
                                                   // terms have |coeffs| summing to 12)

    wire signed [NUM_WIDTH-1:0] x_m1_w = {{4{x_m1[IN_WIDTH-1]}}, x_m1};
    wire signed [NUM_WIDTH-1:0] x_0_w  = {{4{x_0[IN_WIDTH-1]}},  x_0};
    wire signed [NUM_WIDTH-1:0] x_1_w  = {{4{x_1[IN_WIDTH-1]}},  x_1};
    wire signed [NUM_WIDTH-1:0] x_2_w  = {{4{x_2[IN_WIDTH-1]}},  x_2};

    // ---- Stage 2a: scale terms (each a single shift or shift+add) and
    // forward the plain taps Stage 2b still needs. ----
    reg signed [NUM_WIDTH-1:0] m1x2_2a, x0x3_2a, x0x2_2a, x1x3_2a;
    reg signed [NUM_WIDTH-1:0] xm1_2a, x0_2a, x1_2a, x2_2a;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_2a;
    (* srl_style = "register" *) reg                valid_2a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m1x2_2a <= {NUM_WIDTH{1'b0}};
            x0x3_2a <= {NUM_WIDTH{1'b0}};
            x0x2_2a <= {NUM_WIDTH{1'b0}};
            x1x3_2a <= {NUM_WIDTH{1'b0}};
            xm1_2a  <= {NUM_WIDTH{1'b0}};
            x0_2a   <= {NUM_WIDTH{1'b0}};
            x1_2a   <= {NUM_WIDTH{1'b0}};
            x2_2a   <= {NUM_WIDTH{1'b0}};
            mu_2a    <= {MU_WIDTH{1'b0}};
            valid_2a <= 1'b0;
        end else begin
            valid_2a <= valid_d1;
            mu_2a    <= mu_d1;
            m1x2_2a <= x_m1_w <<< 1;                // 2*x[-1]
            x0x3_2a <= x_0_w + (x_0_w <<< 1);        // 3*x[0]
            x0x2_2a <= x_0_w <<< 1;                  // 2*x[0]
            x1x3_2a <= x_1_w + (x_1_w <<< 1);         // 3*x[1] (6*x[1] = this <<< 1, done in 2b)
            xm1_2a  <= x_m1_w;
            x0_2a   <= x_0_w;
            x1_2a   <= x_1_w;
            x2_2a   <= x_2_w;
        end
    end

    // ---- Stage 2b: sum into numerators (pure adds of pre-scaled/plain
    // registered values, no multiplies) -- division not yet applied. ----
    reg signed [NUM_WIDTH-1:0] num_v1_2b, num_v2_2b, num_v3_2b, v0_2b;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_2b;
    (* srl_style = "register" *) reg                valid_2b;

    always @(posedge aclk) begin
        if (!aresetn) begin
            num_v1_2b <= {NUM_WIDTH{1'b0}};
            num_v2_2b <= {NUM_WIDTH{1'b0}};
            num_v3_2b <= {NUM_WIDTH{1'b0}};
            v0_2b     <= {NUM_WIDTH{1'b0}};
            mu_2b    <= {MU_WIDTH{1'b0}};
            valid_2b <= 1'b0;
        end else begin
            valid_2b <= valid_2a;
            mu_2b    <= mu_2a;
            num_v1_2b <= -m1x2_2a - x0x3_2a + (x1x3_2a <<< 1) - x2_2a;  // -2xm1-3x0+6x1-x2
            num_v2_2b <= xm1_2a - x0x2_2a + x1_2a;                       // xm1-2x0+x1
            num_v3_2b <= -xm1_2a + x0x3_2a - x1x3_2a + x2_2a;            // -xm1+3x0-3x1+x2
            v0_2b     <= x0_2a;
        end
    end

    // ---- Stage 2c: apply the constant division, isolated in its own
    // cycle same as every other constant-divisor op in this module. ----
    reg signed [NUM_WIDTH-1:0] v0_2, v1_2, v2_2, v3_2;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_d2;
    (* srl_style = "register" *) reg                valid_d2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            v0_2 <= {NUM_WIDTH{1'b0}};
            v1_2 <= {NUM_WIDTH{1'b0}};
            v2_2 <= {NUM_WIDTH{1'b0}};
            v3_2 <= {NUM_WIDTH{1'b0}};
            mu_d2    <= {MU_WIDTH{1'b0}};
            valid_d2 <= 1'b0;
        end else begin
            valid_d2 <= valid_2b;
            mu_d2    <= mu_2b;
            v0_2 <= v0_2b;
            v1_2 <= num_v1_2b / 6;
            v2_2 <= num_v2_2b / 2;
            v3_2 <= num_v3_2b / 6;
        end
    end

    // -----------------------------------------------------------------
    // Stages 3a/3b, 4a/4b, 5a/5b: Horner evaluation
    // y = ((v3*mu + v2)*mu + v1)*mu + v0, one multiply per "a" stage, one
    // shift+add per "b" stage. mu is unsigned in [0,1) (mu_in / 2^MU_WIDTH);
    // zero-extended into a signed container one bit wider at each use so
    // the signed(v) * mu multiply isn't silently coerced to unsigned by
    // Verilog's operand-mixing rule (a real correctness pitfall, not just
    // style -- mixing a signed operand with an unsigned one in the same
    // expression makes Verilog treat the whole expression as unsigned).
    //
    // Real-hardware bug found and fixed (2026-08-02): an earlier version
    // computed multiply+shift+add all combinationally in one cycle, using a
    // single generously-oversized product width shared by every stage (to
    // work around a separate Verilog width-inference pitfall -- see below).
    // That oversizing broke DSP48 inference for the smaller multiplies:
    // ATF reported a genuine (not debug-only) setup violation of -20ns,
    // traced to gmsk_step2a_interpol_0 itself -- 45 logic levels, 30
    // CARRY4s, the unmistakable signature of a multiply that fell back to
    // slow LUT/carry-chain fabric instead of a DSP48. Fix: give each
    // multiply its own naturally-sized product width (operand widths
    // summed, no padding) AND register the raw multiply's output in its
    // own pipeline stage, before the shift+add -- registered-in,
    // registered-out is what reliably gets Vivado to infer a real DSP48,
    // matching the discriminator's own real-hardware timing lesson (both
    // MAC operands registered) one level deeper. Costs 3 extra cycles of
    // latency (one per Horner stage) -- irrelevant to this fixed-rate
    // streaming block.
    //
    // Multiply width note: assigning a product DIRECTLY into a correctly
    // sized register (as below) is unambiguous and doesn't suffer the
    // chained-inline-expression width-inference bug documented earlier in
    // this file -- that bug was specifically about a multiply's result
    // being consumed by a FURTHER inline shift+add before ever landing in
    // a register of its own.
    // -----------------------------------------------------------------
    localparam integer ACC_WIDTH   = NUM_WIDTH + 2;        // guard bits through the MAC chain
    localparam integer MULW        = MU_WIDTH + 1;         // signed, zero-extended mu container
    localparam integer PROD3_WIDTH = NUM_WIDTH + MULW;     // v3_2 (NUM_WIDTH) * mu
    localparam integer PROD_WIDTH  = ACC_WIDTH + MULW;     // acc_3/acc_4     (ACC_WIDTH) * mu

    // ---- Stage 3a: register the raw multiply v3*mu, naturally sized ----
    //
    // srl_style="register" on every pure "carry this value forward N cycles
    // unchanged" signal below (v0/v1/v2/mu/valid across stages 3a-5a): a
    // second real-hardware bug found and fixed (2026-08-02), one rebuild
    // after the multiply-width fix above. WNS was still catastrophically
    // negative (-20ns class) post-fix, but the failing path moved --
    // x_1_reg[4] -> v1_3a_reg[25]_srl2..._srlopt, 38 logic levels, 27
    // CARRY4s. The "_srlopt" name is the tell: Vivado's synthesizer
    // recognized "v1_3a <= v1_2, then v1_3b <= v1_3a, then v1_4a <= v1_3b"
    // as a textbook shift-register pattern and opportunistically converted
    // it from plain flip-flops into an SRL16/32 primitive (a space-saving
    // optimization), which then placed/routed badly against the nearby
    // CARRY4-heavy multiply logic. Forcing srl_style="register" tells
    // synthesis "no, keep these as real flip-flops" -- the standard,
    // documented fix for exactly this class of Vivado-introduced timing
    // surprise in a pipeline that was designed assuming FF-based stages.
    (* srl_style = "register" *) reg signed [PROD3_WIDTH-1:0] mult_3;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]   v2_3a, v1_3a, v0_3a;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]    mu_3a;
    (* srl_style = "register" *) reg                          valid_3a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_3 <= {PROD3_WIDTH{1'b0}};
            v2_3a  <= {NUM_WIDTH{1'b0}};
            v1_3a  <= {NUM_WIDTH{1'b0}};
            v0_3a  <= {NUM_WIDTH{1'b0}};
            mu_3a  <= {MU_WIDTH{1'b0}};
            valid_3a <= 1'b0;
        end else begin
            valid_3a <= valid_d2;
            mult_3   <= v3_2 * $signed({1'b0, mu_d2});
            v2_3a    <= v2_2;
            v1_3a    <= v1_2;
            v0_3a    <= v0_2;
            mu_3a    <= mu_d2;
        end
    end

    // ---- Stage 3b: acc_3 = (mult_3 >>> MU_WIDTH) + v2 ----
    reg signed [ACC_WIDTH-1:0] acc_3;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0] v1_3b, v0_3b;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]  mu_3b;
    (* srl_style = "register" *) reg                        valid_3b;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc_3 <= {ACC_WIDTH{1'b0}};
            v1_3b <= {NUM_WIDTH{1'b0}};
            v0_3b <= {NUM_WIDTH{1'b0}};
            mu_3b <= {MU_WIDTH{1'b0}};
            valid_3b <= 1'b0;
        end else begin
            valid_3b <= valid_3a;
            acc_3 <= (mult_3 >>> MU_WIDTH) + v2_3a;
            v1_3b <= v1_3a;
            v0_3b <= v0_3a;
            mu_3b <= mu_3a;
        end
    end

    // ---- Stage 4a: register the raw multiply acc_3*mu, naturally sized ----
    reg signed [PROD_WIDTH-1:0] mult_4;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0] v1_4a, v0_4a;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]  mu_4a;
    (* srl_style = "register" *) reg                        valid_4a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_4 <= {PROD_WIDTH{1'b0}};
            v1_4a  <= {NUM_WIDTH{1'b0}};
            v0_4a  <= {NUM_WIDTH{1'b0}};
            mu_4a  <= {MU_WIDTH{1'b0}};
            valid_4a <= 1'b0;
        end else begin
            valid_4a <= valid_3b;
            mult_4   <= acc_3 * $signed({1'b0, mu_3b});
            v1_4a    <= v1_3b;
            v0_4a    <= v0_3b;
            mu_4a    <= mu_3b;
        end
    end

    // ---- Stage 4b: acc_4 = (mult_4 >>> MU_WIDTH) + v1 ----
    reg signed [ACC_WIDTH-1:0] acc_4;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0] v0_4b;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]  mu_4b;
    (* srl_style = "register" *) reg                        valid_4b;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc_4 <= {ACC_WIDTH{1'b0}};
            v0_4b <= {NUM_WIDTH{1'b0}};
            mu_4b <= {MU_WIDTH{1'b0}};
            valid_4b <= 1'b0;
        end else begin
            valid_4b <= valid_4a;
            acc_4 <= (mult_4 >>> MU_WIDTH) + v1_4a;
            v0_4b <= v0_4a;
            mu_4b <= mu_4a;
        end
    end

    // ---- Stage 5a: register the raw multiply acc_4*mu, naturally sized ----
    reg signed [PROD_WIDTH-1:0] mult_5;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0] v0_5a;
    (* srl_style = "register" *) reg                        valid_5a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_5 <= {PROD_WIDTH{1'b0}};
            v0_5a  <= {NUM_WIDTH{1'b0}};
            valid_5a <= 1'b0;
        end else begin
            valid_5a <= valid_4b;
            mult_5   <= acc_4 * $signed({1'b0, mu_4b});
            v0_5a    <= v0_4b;
        end
    end

    // ---- Stage 5b: output = (mult_5 >>> MU_WIDTH) + v0. The natural scale
    // of the Horner result already matches the input's scale (Lagrange
    // basis coefficients sum to 1 at any mu -- this is a weighted average
    // of x[-1..2], not a growing product like the discriminator's
    // multiply), so truncating to the low OUT_WIDTH bits is correct here --
    // unlike gmsk_step1_discriminator's TRUNC_SHIFT, this isn't a
    // deliberate multiplicative rescale, the extra guard bits are just
    // headroom against transient overflow through the MAC chain.
    wire signed [ACC_WIDTH-1:0] acc_5 = (mult_5 >>> MU_WIDTH) + v0_5a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {OUT_WIDTH{1'b0}};
        end else begin
            m_axis_tvalid <= valid_5a;
            m_axis_tdata  <= acc_5[OUT_WIDTH-1:0];
        end
    end

endmodule
