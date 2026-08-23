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

    // ---- Stage 2b1: sum into numerators for v1/v3/v0 (pure adds of
    // pre-scaled/plain registered values, no multiplies) -- v1/v0 unchanged
    // from the original single-cycle Stage 2b. v2's and (as of 2026-08-24,
    // see Stage 2b2's own header below) v3's sums are each split across two
    // registered cycles instead of computed here in one.
    reg signed [NUM_WIDTH-1:0] num_v1_2b1, v0_2b1;
    reg signed [NUM_WIDTH-1:0] partial_v2_2b1, x1_fwd_2b1;
    reg signed [NUM_WIDTH-1:0] partial_v3_2b1, x1x3_fwd_2b1, x2_fwd_2b1;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_2b1;
    (* srl_style = "register" *) reg                valid_2b1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            num_v1_2b1     <= {NUM_WIDTH{1'b0}};
            v0_2b1         <= {NUM_WIDTH{1'b0}};
            partial_v2_2b1 <= {NUM_WIDTH{1'b0}};
            x1_fwd_2b1     <= {NUM_WIDTH{1'b0}};
            partial_v3_2b1 <= {NUM_WIDTH{1'b0}};
            x1x3_fwd_2b1   <= {NUM_WIDTH{1'b0}};
            x2_fwd_2b1     <= {NUM_WIDTH{1'b0}};
            mu_2b1    <= {MU_WIDTH{1'b0}};
            valid_2b1 <= 1'b0;
        end else begin
            valid_2b1 <= valid_2a;
            mu_2b1    <= mu_2a;
            num_v1_2b1     <= -m1x2_2a - x0x3_2a + (x1x3_2a <<< 1) - x2_2a;  // -2xm1-3x0+6x1-x2
            v0_2b1         <= x0_2a;
            partial_v2_2b1 <= xm1_2a - x0x2_2a;   // half of xm1-2x0+x1, finished in Stage 2b2
            x1_fwd_2b1     <= x1_2a;
            partial_v3_2b1 <= -xm1_2a + x0x3_2a;  // half of -xm1+3x0-3x1+x2, finished in Stage 2b2
            x1x3_fwd_2b1   <= x1x3_2a;
            x2_fwd_2b1     <= x2_2a;
        end
    end

    // ---- Stage 2b2: finish v2's AND v3's sums (each a cheap add, in their
    // own registered cycle), forward v1/v0 unchanged. Downstream (Stage 2c1
    // onward) is untouched -- num_v1_2b/num_v2_2b/num_v3_2b/v0_2b/mu_2b/
    // valid_2b still mean exactly what they always did, just arrive one
    // cycle later than the original single-stage Stage 2b did.
    //
    // Real-hardware bug found and fixed (2026-08-24), a SEVENTH instance of
    // this module's recurring lesson: v2's numerator (xm1-2x0+x1, a 3-term
    // NUM_WIDTH-wide add) was being computed combinationally in one cycle
    // inside the original Stage 2b, alongside v1/v3's own sums -- and on
    // the first real hardware build of the closed-loop chain (sub-step B2 +
    // Gardner TED wired in), v2's was the one that actually violated timing
    // (-0.035ns, 9 logic levels: 7 CARRY4 + 2 LUT), not v1/v3's own (even
    // wider, 4-term) sums, which had enough margin AT THAT TIME. Fix: same
    // recipe as every earlier instance -- split the add across two
    // registered cycles. Costs one more cycle of total latency (19->20) --
    // irrelevant to this fixed-rate streaming block, but DOES require
    // bumping gmsk_interp_tag_delay's DELAY_CYCLES to match (see that
    // module).
    //
    // Real-hardware bug found and fixed AGAIN (2026-08-24, sub-step F
    // rebuild), an EIGHTH instance: with the loop filter wired in and the
    // timing-recovery loop genuinely closed for the first time, placement
    // shifted enough that v3's own numerator (-xm1+3x0-3x1+x2, ALSO a
    // 4-term NUM_WIDTH-wide add, same shape as v1's still-unsplit sum) took
    // v1's place as a real (if small, -0.095ns/-0.074ns) violation --
    // exact confirmation of the "not really about which expression looks
    // more complex on paper, comes down to where these specific registers
    // land on THIS particular build" lesson already written above. Same
    // fix, same shape: v3's sum is now ALSO split across Stage 2b1
    // (partial_v3_2b1 = -xm1+3x0, plus forwarding the two terms Stage 2b2
    // still needs) and this stage (finishes -x1x3+x2). Unlike the v2 fix,
    // this does NOT need another DELAY_CYCLES bump -- Stage 2b2 already
    // existed as v3's own arrival point (it was doing a trivial 1-cycle
    // forward before), so giving it real work here doesn't change v3's
    // overall latency, just what Stage 2b2 does with the cycle it already
    // had.
    reg signed [NUM_WIDTH-1:0] num_v1_2b, num_v2_2b, v0_2b;
    // dont_touch: the FIRST rebuild with this fix showed Vivado's own
    // register retiming (AggressiveExplore phys_opt_design, already
    // load-bearing for this project's hold-timing fix) silently ate
    // straight through this exact register boundary -- the worst
    // violated path afterward ran from `x1x3_fwd_2b1_reg` directly into
    // Stage 2c's `recip_v3_2c[...]` destination registers with no
    // `num_v3_2b_reg` anywhere in the netlist at all (confirmed: 0 hits
    // for that name in the routed timing report, 182 hits for the
    // retimed/renamed `num_v3_2b0...carry...` net it turned into
    // instead). Functionally harmless (retiming preserves I/O behavior
    // by construction) but it defeated the whole POINT of this split --
    // the retimed boundary just moved the same "too much combinational
    // logic in one cycle" problem one step further downstream instead of
    // actually breaking it into two cycles. `dont_touch` forces this
    // specific register to stay exactly where the RTL says it is, the
    // standard fix when a synthesis optimizer is retiming through an
    // intentional pipeline boundary. Scoped to only this one register --
    // num_v1_2b/num_v2_2b/v0_2b weren't implicated (v0/v1 are plain
    // forwards, v2 already got this exact split treatment once with no
    // retiming issue observed), so left unconstrained.
    (* dont_touch = "true" *) reg signed [NUM_WIDTH-1:0] num_v3_2b;
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
            valid_2b <= valid_2b1;
            mu_2b    <= mu_2b1;
            num_v1_2b <= num_v1_2b1;
            v0_2b     <= v0_2b1;
            num_v2_2b <= partial_v2_2b1 + x1_fwd_2b1;               // finishes xm1-2x0+x1
            num_v3_2b <= partial_v3_2b1 - x1x3_fwd_2b1 + x2_fwd_2b1; // finishes -xm1+3x0-3x1+x2
        end
    end

    // ---- Stage 2c/2d: apply the constant division.
    //
    // Real-hardware bug found and fixed (2026-08-09), a fourth instance of
    // the exact same underlying lesson: even with Stage 2 already split
    // into scale/sum/divide sub-stages, WNS was still -14.469ns, and the
    // failing path was num_v1_2b_reg -> v1_2_reg -- Stage 2c's /6 division,
    // ALONE in its own cycle with nothing else sharing it, was itself
    // still too slow (18.5ns, 36 logic levels, 25 CARRY4s). The prior
    // comment's assumption ("constant-divisor division ... NOT the same
    // cost/timing class as a runtime variable divide") is true relative to
    // a real divider, but Verilog's `/` by a non-power-of-2 constant still
    // synthesizes to essentially a multiply-by-reciprocal-constant + shift
    // internally -- structurally the same shape as the Horner multiplies,
    // which needed their OWN registered output stage (see the DSP48-fix
    // entry in project memory) rather than being combined with a
    // shift+add in the same cycle. This division was never given that
    // same treatment. /2 (v2) is exempt -- a power-of-2 divisor is just a
    // plain arithmetic right-shift, zero logic, not a real division in
    // hardware at all.
    //
    // Fix: hand-expand the /6 reciprocal-multiply for v1 and v3 into its
    // own registered stage (2c), separate from the final shift (2d) --
    // same "register the raw multiply, shift+finalize next cycle" pattern
    // as every multiply in this module. RECIP6=174763, SHIFT6=20 is a
    // 20-bit fixed-point approximation of 1/6 (174763/2^20 = 0.1666670...
    // vs exact 0.1666667, relative error ~2e-6 -- utterly negligible next
    // to the cubic-vs-sine approximation error the SIM gate already
    // tolerates).
    // -----------------------------------------------------------------
    localparam integer RECIP6 = 174763;   // round(2^20 / 6)
    localparam integer SHIFT6 = 20;
    localparam integer RECIPW = NUM_WIDTH + SHIFT6 + 1;  // natural width of num*RECIP6

    // Real-hardware bug found and fixed (2026-08-09), a SIXTH instance,
    // caught on the SAME rebuild as the Horner hi/lo split fix (see that
    // fix's comment for the full DSP48E1-operand-limit explanation): once
    // the three Horner multiplies stopped being the worst path, the exact
    // same problem showed up here instead -- recip_v3_2c (DSP48-to-DSP48,
    // PCIN cascade) -- because num_v1_2b/num_v3_2b are also NUM_WIDTH=28
    // bits, past the 25-bit single-DSP48 "A" operand limit, same as v3_2
    // was. Missed this pair of multiplies when applying the hi/lo split
    // the first time (only the three Horner-stage multiplies got it).
    // Same fix, same LOBITS=15 split point, applied here too -- except the
    // second operand (RECIP6) is a compile-time CONSTANT, not a variable
    // register, so there's no second operand to split, just the one wide
    // numerator.
    localparam integer RCLOBITS   = 15;
    localparam integer RCHI_WIDTH = NUM_WIDTH - RCLOBITS;  // 13
    localparam integer RC_RECIPW  = 18;  // bits needed for RECIP6=174763 (< 2^18)

    // ---- Stage 2c1: split num_v1_2b/num_v3_2b into hi/lo. ----
    (* srl_style = "register" *) reg signed [RCHI_WIDTH-1:0] v1hi_2c1, v3hi_2c1;
    (* srl_style = "register" *) reg        [RCLOBITS-1:0]   v1lo_2c1, v3lo_2c1;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]  v0_2c1, v2_2c1;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]   mu_2c1;
    (* srl_style = "register" *) reg                         valid_2c1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            v1hi_2c1 <= {RCHI_WIDTH{1'b0}};
            v3hi_2c1 <= {RCHI_WIDTH{1'b0}};
            v1lo_2c1 <= {RCLOBITS{1'b0}};
            v3lo_2c1 <= {RCLOBITS{1'b0}};
            v0_2c1 <= {NUM_WIDTH{1'b0}};
            v2_2c1 <= {NUM_WIDTH{1'b0}};
            mu_2c1    <= {MU_WIDTH{1'b0}};
            valid_2c1 <= 1'b0;
        end else begin
            valid_2c1 <= valid_2b;
            mu_2c1    <= mu_2b;
            v1hi_2c1 <= num_v1_2b >>> RCLOBITS;
            v3hi_2c1 <= num_v3_2b >>> RCLOBITS;
            v1lo_2c1 <= num_v1_2b[RCLOBITS-1:0];
            v3lo_2c1 <= num_v3_2b[RCLOBITS-1:0];
            v0_2c1 <= v0_2b;
            v2_2c1 <= num_v2_2b >>> 1;   // /2, exact, trivially fast
        end
    end

    // ---- Stage 2c2: the partial-product multiplies against the RECIP6
    // constant, each single-DSP48-safe. ----
    (* srl_style = "register" *) reg signed [RCHI_WIDTH+RC_RECIPW-1:0] v1ph_2c2, v3ph_2c2;
    (* srl_style = "register" *) reg signed [RCLOBITS+RC_RECIPW:0]     v1pl_2c2, v3pl_2c2;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]            v0_2c2, v2_2c2;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]             mu_2c2;
    (* srl_style = "register" *) reg                                   valid_2c2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            v1ph_2c2 <= {(RCHI_WIDTH+RC_RECIPW){1'b0}};
            v3ph_2c2 <= {(RCHI_WIDTH+RC_RECIPW){1'b0}};
            v1pl_2c2 <= {(RCLOBITS+RC_RECIPW+1){1'b0}};
            v3pl_2c2 <= {(RCLOBITS+RC_RECIPW+1){1'b0}};
            v0_2c2 <= {NUM_WIDTH{1'b0}};
            v2_2c2 <= {NUM_WIDTH{1'b0}};
            mu_2c2    <= {MU_WIDTH{1'b0}};
            valid_2c2 <= 1'b0;
        end else begin
            valid_2c2 <= valid_2c1;
            mu_2c2    <= mu_2c1;
            v1ph_2c2 <= v1hi_2c1 * RECIP6;
            v3ph_2c2 <= v3hi_2c1 * RECIP6;
            v1pl_2c2 <= $signed({1'b0, v1lo_2c1}) * RECIP6;
            v3pl_2c2 <= $signed({1'b0, v3lo_2c1}) * RECIP6;
            v0_2c2 <= v0_2c1;
            v2_2c2 <= v2_2c1;
        end
    end

    // ---- Stage 2c: recombine (shift+add, safe) into the same
    // "recip_v1_2c"/"recip_v3_2c" this module always had. ----
    reg signed [RECIPW-1:0]   recip_v1_2c, recip_v3_2c;
    reg signed [NUM_WIDTH-1:0] v0_2c, v2_2c;
    (* srl_style = "register" *) reg [MU_WIDTH-1:0] mu_2c;
    (* srl_style = "register" *) reg                valid_2c;

    always @(posedge aclk) begin
        if (!aresetn) begin
            recip_v1_2c <= {RECIPW{1'b0}};
            recip_v3_2c <= {RECIPW{1'b0}};
            v0_2c <= {NUM_WIDTH{1'b0}};
            v2_2c <= {NUM_WIDTH{1'b0}};
            mu_2c    <= {MU_WIDTH{1'b0}};
            valid_2c <= 1'b0;
        end else begin
            valid_2c <= valid_2c2;
            mu_2c    <= mu_2c2;
            recip_v1_2c <= (v1ph_2c2 <<< RCLOBITS) + v1pl_2c2;
            recip_v3_2c <= (v3ph_2c2 <<< RCLOBITS) + v3pl_2c2;
            v0_2c <= v0_2c2;
            v2_2c <= v2_2c2;
        end
    end

    // ---- Stage 2d: finish the /6 division (shift down the registered
    // reciprocal-multiply -- itself just a shift, no further multiply, so
    // safe to finalize here), forward v0/v2/mu/valid.
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
            valid_d2 <= valid_2c;
            mu_d2    <= mu_2c;
            v0_2 <= v0_2c;
            v1_2 <= recip_v1_2c >>> SHIFT6;
            v2_2 <= v2_2c;
            v3_2 <= recip_v3_2c >>> SHIFT6;
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

    // Real-hardware bug found and fixed (2026-08-09), a FIFTH instance of
    // the multiply-timing lesson, but a genuinely different mechanism this
    // time: with every earlier fix applied, WNS was down to -1.665ns and
    // the failing path (mult_50/CLK -> mult_5_reg/PCIN) was DSP48-to-DSP48
    // -- both endpoints real DSP48E1 primitives, "Logic Levels: 0", 99.95%
    // of the delay inside the DSP fabric itself. Every earlier fix worked
    // (multiplies genuinely map to DSP48s now); this is DSP48E1's own
    // native operand limit (25x18 signed) being exceeded -- v3_2 is
    // NUM_WIDTH=28 bits, acc_3/acc_4 are ACC_WIDTH=30 bits, both wider
    // than the 25-bit "A" input a single DSP48E1 can take, forcing a
    // 2-DSP cascade via the dedicated PCIN/PCOUT path. That cascade route
    // is only fast when the two DSP48 tiles land immediately adjacent in
    // placement; here it didn't, and a different implementation strategy
    // (Performance_ExplorePostRoutePhysOpt) made no real difference
    // (-1.668 to -1.821ns range) -- Vivado's own physopt log said as much:
    // "Post-Route Physical Optimization is most effective when WNS is
    // above -0.5ns". Shrinking ACC_WIDTH to fit under 25 bits was
    // considered and rejected -- the Horner accumulator's true worst-case
    // magnitude needs ~27 bits for correctness margin, already past the
    // single-DSP48 threshold, so trimming width further risks silent
    // overflow rather than fixing anything.
    //
    // Fix: split each wide operand (v3_2, acc_3, acc_4) into hi/lo halves
    // at bit 15, each half safely under DSP48's 25-bit limit on its own,
    // compute both partial products in dedicated single-DSP multiplies,
    // then recombine (shift+add, not a multiply -- safe to combine with
    // other logic, unlike every multiply in this module). This is the
    // standard technique for a multiply wider than one DSP48 tile, done
    // explicitly in RTL instead of trusting Vivado's automatic cascade
    // inference to place it well.
    localparam integer LOBITS     = 15;                 // split point: low LOBITS bits (unsigned), rest (signed) is "hi"
    localparam integer LO_SWIDTH  = LOBITS + 1;          // lo part zero-extended into a signed container
    localparam integer V3HI_WIDTH  = NUM_WIDTH - LOBITS;  // 13 -- comfortably under the 25-bit DSP48 "A" limit
    localparam integer ACCHI_WIDTH = ACC_WIDTH - LOBITS;  // 15 -- likewise

    // srl_style="register" on every pure "carry this value forward N
    // cycles unchanged" signal below: a second real-hardware bug found and
    // fixed (2026-08-02) -- Vivado's synthesizer opportunistically
    // converts such forwarding chains into SRL16/32 primitives (a
    // space-saving optimization) that then placed/routed badly against
    // nearby CARRY4-heavy multiply logic. Forcing plain-flip-flop
    // registers is the standard, documented fix.

    // ---- Stage 3a1: split v3_2 into hi (signed)/lo (unsigned magnitude) ----
    (* srl_style = "register" *) reg signed [V3HI_WIDTH-1:0] v3hi_3a1;
    (* srl_style = "register" *) reg        [LOBITS-1:0]     v3lo_3a1;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]   v2_3a1, v1_3a1, v0_3a1;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]    mu_3a1;
    (* srl_style = "register" *) reg                          valid_3a1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            v3hi_3a1 <= {V3HI_WIDTH{1'b0}};
            v3lo_3a1 <= {LOBITS{1'b0}};
            v2_3a1 <= {NUM_WIDTH{1'b0}};
            v1_3a1 <= {NUM_WIDTH{1'b0}};
            v0_3a1 <= {NUM_WIDTH{1'b0}};
            mu_3a1    <= {MU_WIDTH{1'b0}};
            valid_3a1 <= 1'b0;
        end else begin
            valid_3a1 <= valid_d2;
            mu_3a1    <= mu_d2;
            v3hi_3a1 <= v3_2 >>> LOBITS;
            v3lo_3a1 <= v3_2[LOBITS-1:0];
            v2_3a1 <= v2_2;
            v1_3a1 <= v1_2;
            v0_3a1 <= v0_2;
        end
    end

    // ---- Stage 3a2: the two single-DSP48-safe partial-product multiplies ----
    // mu is forwarded (unused by this stage's own logic) so stage 4a1 gets
    // the SAME window's mu, not a later, re-shifted one -- see the
    // mu-forwarding note above stage 3a1.
    (* srl_style = "register" *) reg signed [V3HI_WIDTH+MULW-1:0]   ph_3a2;
    (* srl_style = "register" *) reg signed [LO_SWIDTH+MULW-1:0]    pl_3a2;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]         v2_3a2, v1_3a2, v0_3a2;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]          mu_3a2;
    (* srl_style = "register" *) reg                                valid_3a2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            ph_3a2 <= {(V3HI_WIDTH+MULW){1'b0}};
            pl_3a2 <= {(LO_SWIDTH+MULW){1'b0}};
            v2_3a2 <= {NUM_WIDTH{1'b0}};
            v1_3a2 <= {NUM_WIDTH{1'b0}};
            v0_3a2 <= {NUM_WIDTH{1'b0}};
            mu_3a2    <= {MU_WIDTH{1'b0}};
            valid_3a2 <= 1'b0;
        end else begin
            valid_3a2 <= valid_3a1;
            mu_3a2    <= mu_3a1;
            ph_3a2 <= v3hi_3a1 * $signed({1'b0, mu_3a1});
            pl_3a2 <= $signed({1'b0, v3lo_3a1}) * $signed({1'b0, mu_3a1});
            v2_3a2 <= v2_3a1;
            v1_3a2 <= v1_3a1;
            v0_3a2 <= v0_3a1;
        end
    end

    // ---- Stage 3a3: recombine (shift+add, not a multiply -- safe to
    // combine) into the same "mult_3" this module always had. mu still
    // just forwarded -- not needed again until stage 4a2. ----
    (* srl_style = "register" *) reg signed [PROD3_WIDTH-1:0] mult_3;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]   v2_3a, v1_3a, v0_3a;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]    mu_3a3;
    (* srl_style = "register" *) reg                          valid_3a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_3 <= {PROD3_WIDTH{1'b0}};
            v2_3a  <= {NUM_WIDTH{1'b0}};
            v1_3a  <= {NUM_WIDTH{1'b0}};
            v0_3a  <= {NUM_WIDTH{1'b0}};
            mu_3a3 <= {MU_WIDTH{1'b0}};
            valid_3a <= 1'b0;
        end else begin
            valid_3a <= valid_3a2;
            mu_3a3   <= mu_3a2;
            mult_3   <= (ph_3a2 <<< LOBITS) + pl_3a2;
            v2_3a    <= v2_3a2;
            v1_3a    <= v1_3a2;
            v0_3a    <= v0_3a2;
        end
    end

    // ---- Stage 3b: acc_3 = (mult_3 >>> MU_WIDTH) + v2. mu still forwarded. ----
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
            mu_3b <= mu_3a3;
            acc_3 <= (mult_3 >>> MU_WIDTH) + v2_3a;
            v1_3b <= v1_3a;
            v0_3b <= v0_3a;
        end
    end

    // ---- Stage 4a1/4a2/4a3: same hi/lo split treatment for acc_3*mu ----
    (* srl_style = "register" *) reg signed [ACCHI_WIDTH-1:0] acc3hi_4a1;
    (* srl_style = "register" *) reg        [LOBITS-1:0]      acc3lo_4a1;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]   v1_4a1, v0_4a1;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]    mu_4a1;
    (* srl_style = "register" *) reg                          valid_4a1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc3hi_4a1 <= {ACCHI_WIDTH{1'b0}};
            acc3lo_4a1 <= {LOBITS{1'b0}};
            v1_4a1 <= {NUM_WIDTH{1'b0}};
            v0_4a1 <= {NUM_WIDTH{1'b0}};
            mu_4a1    <= {MU_WIDTH{1'b0}};
            valid_4a1 <= 1'b0;
        end else begin
            valid_4a1 <= valid_3b;
            mu_4a1    <= mu_3b;
            acc3hi_4a1 <= acc_3 >>> LOBITS;
            acc3lo_4a1 <= acc_3[LOBITS-1:0];
            v1_4a1 <= v1_3b;
            v0_4a1 <= v0_3b;
        end
    end

    (* srl_style = "register" *) reg signed [ACCHI_WIDTH+MULW-1:0] ph_4a2;
    (* srl_style = "register" *) reg signed [LO_SWIDTH+MULW-1:0]   pl_4a2;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]        v1_4a2, v0_4a2;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]         mu_4a2;
    (* srl_style = "register" *) reg                               valid_4a2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            ph_4a2 <= {(ACCHI_WIDTH+MULW){1'b0}};
            pl_4a2 <= {(LO_SWIDTH+MULW){1'b0}};
            v1_4a2 <= {NUM_WIDTH{1'b0}};
            v0_4a2 <= {NUM_WIDTH{1'b0}};
            mu_4a2    <= {MU_WIDTH{1'b0}};
            valid_4a2 <= 1'b0;
        end else begin
            valid_4a2 <= valid_4a1;
            mu_4a2    <= mu_4a1;
            ph_4a2 <= acc3hi_4a1 * $signed({1'b0, mu_4a1});
            pl_4a2 <= $signed({1'b0, acc3lo_4a1}) * $signed({1'b0, mu_4a1});
            v1_4a2 <= v1_4a1;
            v0_4a2 <= v0_4a1;
        end
    end

    (* srl_style = "register" *) reg signed [PROD_WIDTH-1:0] mult_4;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]  v1_4a, v0_4a;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]   mu_4a3;
    (* srl_style = "register" *) reg                         valid_4a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_4 <= {PROD_WIDTH{1'b0}};
            v1_4a  <= {NUM_WIDTH{1'b0}};
            v0_4a  <= {NUM_WIDTH{1'b0}};
            mu_4a3 <= {MU_WIDTH{1'b0}};
            valid_4a <= 1'b0;
        end else begin
            valid_4a <= valid_4a2;
            mu_4a3   <= mu_4a2;
            mult_4   <= (ph_4a2 <<< LOBITS) + pl_4a2;
            v1_4a    <= v1_4a2;
            v0_4a    <= v0_4a2;
        end
    end

    // ---- Stage 4b: acc_4 = (mult_4 >>> MU_WIDTH) + v1. mu still forwarded. ----
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
            mu_4b <= mu_4a3;
            acc_4 <= (mult_4 >>> MU_WIDTH) + v1_4a;
            v0_4b <= v0_4a;
        end
    end

    // ---- Stage 5a1/5a2/5a3: same hi/lo split treatment for acc_4*mu.
    // mu not needed past 5a2's consumption -- nothing forwards it further. ----
    (* srl_style = "register" *) reg signed [ACCHI_WIDTH-1:0] acc4hi_5a1;
    (* srl_style = "register" *) reg        [LOBITS-1:0]      acc4lo_5a1;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]   v0_5a1;
    (* srl_style = "register" *) reg        [MU_WIDTH-1:0]    mu_5a1;
    (* srl_style = "register" *) reg                          valid_5a1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            acc4hi_5a1 <= {ACCHI_WIDTH{1'b0}};
            acc4lo_5a1 <= {LOBITS{1'b0}};
            v0_5a1 <= {NUM_WIDTH{1'b0}};
            mu_5a1    <= {MU_WIDTH{1'b0}};
            valid_5a1 <= 1'b0;
        end else begin
            valid_5a1 <= valid_4b;
            mu_5a1    <= mu_4b;
            acc4hi_5a1 <= acc_4 >>> LOBITS;
            acc4lo_5a1 <= acc_4[LOBITS-1:0];
            v0_5a1 <= v0_4b;
        end
    end

    (* srl_style = "register" *) reg signed [ACCHI_WIDTH+MULW-1:0] ph_5a2;
    (* srl_style = "register" *) reg signed [LO_SWIDTH+MULW-1:0]   pl_5a2;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]        v0_5a2;
    (* srl_style = "register" *) reg                               valid_5a2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            ph_5a2 <= {(ACCHI_WIDTH+MULW){1'b0}};
            pl_5a2 <= {(LO_SWIDTH+MULW){1'b0}};
            v0_5a2 <= {NUM_WIDTH{1'b0}};
            valid_5a2 <= 1'b0;
        end else begin
            valid_5a2 <= valid_5a1;
            ph_5a2 <= acc4hi_5a1 * $signed({1'b0, mu_5a1});
            pl_5a2 <= $signed({1'b0, acc4lo_5a1}) * $signed({1'b0, mu_5a1});
            v0_5a2 <= v0_5a1;
        end
    end

    (* srl_style = "register" *) reg signed [PROD_WIDTH-1:0] mult_5;
    (* srl_style = "register" *) reg signed [NUM_WIDTH-1:0]  v0_5a;
    (* srl_style = "register" *) reg                         valid_5a;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_5 <= {PROD_WIDTH{1'b0}};
            v0_5a  <= {NUM_WIDTH{1'b0}};
            valid_5a <= 1'b0;
        end else begin
            valid_5a <= valid_5a2;
            mult_5   <= (ph_5a2 <<< LOBITS) + pl_5a2;
            v0_5a    <= v0_5a2;
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
