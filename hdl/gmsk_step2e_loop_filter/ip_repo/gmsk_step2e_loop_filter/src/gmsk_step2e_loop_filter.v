`timescale 1ns / 1ps
//
// gmsk_step2e_loop_filter -- Sub-step E: proportional-plus-integrator (PI)
// loop filter, standalone. See docs/step2e_loop_filter.html for the full
// derivation/intuition (why a plain low-pass isn't enough, the PI block
// diagram, the closed-loop ring diagram, the Bn*T/zeta gain-design theory)
// and project_fpga_gmsk_plan memory for the sub-step breakdown this
// belongs to (A = interpolator, done; B2 = dual-threshold NCO, done; D =
// Gardner TED, done; E = this module; F = wiring A+B2+D+E together into
// the actual closed loop, not yet done).
//
//   adj_out[n]       = Kp*e[n] + integrator[n]
//   integrator[n+1]  = integrator[n] + Ki*e[n]
//
// e[n] arrives once per symbol from gmsk_step2d_gardner_ted's m_axis
// (s_axis_tvalid/s_axis_tdata here). adj_out is NOT an AXI4-Stream output
// -- it's a plain, continuously-held signed register, same category as
// gmsk_step2b2_nco's own step_in/adj_in ports (a real permanent value, not
// a bus interface) -- adj_out is meant to wire straight into that NCO's
// adj_in. adj_valid pulses for exactly one cycle whenever adj_out has just
// been updated with a fresh symbol's correction -- purely for ILA/testbench
// observability, the same role gmsk_step2b2_nco's own `strobe` plays for a
// downstream port (gmsk_step2a_interpolator's mu_in) that itself has no
// valid concept.
//
// Why PI, not a plain low-pass: a low-pass/leaky-integrator-alone structure
// can only produce a nonzero output while still RECEIVING a nonzero input,
// so it can never fully cancel a genuine constant clock-rate offset (real
// TX/RX crystal mismatch) without a permanent residual error. The integral
// term here is what lets the loop settle at whatever constant adj_out
// value exactly cancels a real frequency offset, and hold it indefinitely
// even once e[n] itself has been driven back to (near) zero -- see the
// docs page's interactive demo for a direct visual of this vs. a
// proportional-only comparison.
//
// Fixed-point design (verified numerically in sim/design_loop_filter.py
// before writing this RTL, same discipline every earlier sub-step used):
//   - e[n] is IN_WIDTH=32 signed, matching gmsk_step2d_gardner_ted's
//     OUT_WIDTH exactly.
//   - adj_out is OUT_WIDTH=32 signed Q32, matching gmsk_step2b2_nco's
//     STEP_WIDTH/adj_in exactly (STEP_NOMINAL=2^30 there, for LOG2_SPS=2).
//   - Kp/Ki are small fixed GAIN_WIDTH-bit signed constants (comfortably
//     fit DSP48E1's 18-bit "B" operand directly, no split needed for the
//     gain operand) -- e[n] itself is the "too wide" operand here and gets
//     hi/lo split at LOBITS instead (the OPPOSITE split assignment from
//     gmsk_step2d_gardner_ted's own diff/y_mid multiply, where the gain-like
//     operand was the one that needed splitting -- here it's the signal
//     operand that's wide and the gain that's narrow).
//   - KP_INT/KI_INT are ILLUSTRATIVE DEFAULTS, not tuned final values --
//     the real detector gain (how much e[n] moves per unit real timing
//     error) is signal-amplitude-dependent and genuinely unknown until
//     characterized against real hardware captures, exactly as
//     docs/step2e_loop_filter.html's own callout says. Real captured e[n]
//     so far (2026-08-23, iladata1.csv, near-zero-mu/unlocked) ranged
//     -10..+71 -- these defaults were chosen so that range produces a
//     genuinely nonzero, non-overflowing correction, not tuned to any
//     particular Bn*T/zeta.
//   - The integrator is WIDER than adj_out by GUARD_BITS of extra
//     fractional precision (INTEG_WIDTH = OUT_WIDTH + GUARD_BITS), same
//     "wide accumulator, expose only the top bits" pattern
//     gmsk_step2b2_nco's own phase accumulator already uses. Without this,
//     a small Ki*e[n] increment can truncate to exactly zero every single
//     symbol and the integral term would never move at all -- caught
//     exactly this failure mode once already, in the docs page's own
//     interactive demo, before it ever reached RTL.
//   - Both the integrator update and the final adj_out sum use SATURATING
//     (clamped, not wrapped) arithmetic. Verified numerically that a
//     plausible (not even pathological) misconfiguration -- a somewhat
//     large Ki gain sustained against a large e[n] -- can overflow a
//     48-bit integrator in as few as ~256 symbols; a silent wraparound
//     there would flip a large correction's sign and could actively
//     destabilize the NCO, which is a materially worse failure mode than
//     the many OTHER documented-but-unenforced preconditions elsewhere in
//     this project (e.g. Gardner's own ON/MID alternation) -- worth the
//     extra logic here specifically because of how bad silent wraparound
//     would be, not applied as a blanket policy.
//
module gmsk_step2e_loop_filter #
(
    parameter integer IN_WIDTH    = 32,  // matches gmsk_step2d_gardner_ted's OUT_WIDTH
    parameter integer OUT_WIDTH   = 32,  // matches gmsk_step2b2_nco's STEP_WIDTH (adj_in)
    parameter integer GAIN_WIDTH  = 18,  // Kp_INT/Ki_INT width -- fits DSP48E1's 18-bit "B" operand directly
    parameter integer LOBITS      = 16,  // e[n] hi/lo split point -- clean half of a 32-bit operand
    parameter integer GUARD_BITS  = 16,  // integrator's extra low-end fractional precision beyond OUT_WIDTH

    // Illustrative gain defaults -- see header. Effective gain = INT / 2^SHIFT.
    parameter signed [GAIN_WIDTH-1:0] KP_INT   = 1,
    parameter integer                 KP_SHIFT = 2,
    parameter signed [GAIN_WIDTH-1:0] KI_INT   = 1,
    parameter integer                 KI_SHIFT = 2
)
(
    input  wire                        aclk,
    input  wire                        aresetn,

    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    input  wire signed [IN_WIDTH-1:0]  s_axis_tdata,    // e[n] from gmsk_step2d_gardner_ted's m_axis_tdata

    output reg                         adj_valid,       // pulses one cycle whenever adj_out has just updated -- debug/ILA only, NOT required by gmsk_step2b2_nco's adj_in
    output reg  signed [OUT_WIDTH-1:0] adj_out          // -> gmsk_step2b2_nco's adj_in directly
);

    assign s_axis_tready = 1'b1;

    localparam integer HI_WIDTH     = IN_WIDTH - LOBITS;        // 16 for the defaults
    localparam integer LO_SWIDTH    = LOBITS + 1;               // 17 for the defaults, zero-extended into a signed container
    localparam integer PRODW        = IN_WIDTH + GAIN_WIDTH;    // exact natural width of e[n] * gain (50 for the defaults)
    localparam integer INTEG_WIDTH  = OUT_WIDTH + GUARD_BITS;   // 48 for the defaults

    localparam signed [INTEG_WIDTH-1:0] INTEG_MAX = {1'b0, {(INTEG_WIDTH-1){1'b1}}};
    localparam signed [INTEG_WIDTH-1:0] INTEG_MIN = {1'b1, {(INTEG_WIDTH-1){1'b0}}};
    localparam signed [OUT_WIDTH-1:0]   ADJ_MAX   = {1'b0, {(OUT_WIDTH-1){1'b1}}};
    localparam signed [OUT_WIDTH-1:0]   ADJ_MIN   = {1'b1, {(OUT_WIDTH-1){1'b0}}};

    // -----------------------------------------------------------------
    // Stage 1: split e[n] into hi (signed, arithmetic-shifted)/lo
    // (unsigned magnitude, zero-extended for the multiply) halves.
    // -----------------------------------------------------------------
    (* srl_style = "register" *) reg signed [HI_WIDTH-1:0]  e_hi_1;
    (* srl_style = "register" *) reg        [LOBITS-1:0]    e_lo_1;
    (* srl_style = "register" *) reg                        valid_1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            e_hi_1  <= {HI_WIDTH{1'b0}};
            e_lo_1  <= {LOBITS{1'b0}};
            valid_1 <= 1'b0;
        end else begin
            valid_1 <= s_axis_tvalid;
            e_hi_1  <= s_axis_tdata >>> LOBITS;
            e_lo_1  <= s_axis_tdata[LOBITS-1:0];
        end
    end

    // -----------------------------------------------------------------
    // Stage 2: four single-DSP48-safe partial-product multiplies
    // (Kp*hi, Kp*lo, Ki*hi, Ki*lo), registered-out immediately -- same
    // "nothing else shares this cycle" discipline gmsk_step2d_gardner_ted's
    // own multiply stage uses, which reliably gets Vivado to infer real
    // DSP48s.
    // -----------------------------------------------------------------
    (* srl_style = "register" *) reg signed [HI_WIDTH+GAIN_WIDTH-1:0]    kp_ph_2;
    (* srl_style = "register" *) reg signed [LO_SWIDTH+GAIN_WIDTH-1:0]   kp_pl_2;
    (* srl_style = "register" *) reg signed [HI_WIDTH+GAIN_WIDTH-1:0]    ki_ph_2;
    (* srl_style = "register" *) reg signed [LO_SWIDTH+GAIN_WIDTH-1:0]   ki_pl_2;
    (* srl_style = "register" *) reg                                    valid_2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            kp_ph_2 <= {(HI_WIDTH+GAIN_WIDTH){1'b0}};
            kp_pl_2 <= {(LO_SWIDTH+GAIN_WIDTH){1'b0}};
            ki_ph_2 <= {(HI_WIDTH+GAIN_WIDTH){1'b0}};
            ki_pl_2 <= {(LO_SWIDTH+GAIN_WIDTH){1'b0}};
            valid_2 <= 1'b0;
        end else begin
            valid_2 <= valid_1;
            kp_ph_2 <= e_hi_1 * KP_INT;
            kp_pl_2 <= $signed({1'b0, e_lo_1}) * KP_INT;
            ki_ph_2 <= e_hi_1 * KI_INT;
            ki_pl_2 <= $signed({1'b0, e_lo_1}) * KI_INT;
        end
    end

    // -----------------------------------------------------------------
    // Stage 3: recombine (shift+add, not a multiply -- safe to combine)
    // into the exact natural-width products e[n]*Kp and e[n]*Ki.
    // -----------------------------------------------------------------
    reg signed [PRODW-1:0] kp_prod_3;
    reg signed [PRODW-1:0] ki_prod_3;
    reg                    valid_3;

    always @(posedge aclk) begin
        if (!aresetn) begin
            kp_prod_3 <= {PRODW{1'b0}};
            ki_prod_3 <= {PRODW{1'b0}};
            valid_3   <= 1'b0;
        end else begin
            valid_3   <= valid_2;
            kp_prod_3 <= (kp_ph_2 <<< LOBITS) + kp_pl_2;
            ki_prod_3 <= (ki_ph_2 <<< LOBITS) + ki_pl_2;
        end
    end

    // -----------------------------------------------------------------
    // Stage 4: apply each term's own shift. kp_term lands directly in
    // OUT_WIDTH-domain precision (the proportional term never needs to
    // "remember" sub-LSB amounts). ki_inc is shifted by KI_SHIFT only
    // (NOT all the way down to OUT_WIDTH) so it lands in the wider
    // INTEG_WIDTH domain, retaining GUARD_BITS of extra fractional
    // precision -- see header for why this matters.
    // -----------------------------------------------------------------
    reg signed [OUT_WIDTH-1:0]   kp_term_4;
    reg signed [INTEG_WIDTH-1:0] ki_inc_4;
    reg                          valid_4;

    always @(posedge aclk) begin
        if (!aresetn) begin
            kp_term_4 <= {OUT_WIDTH{1'b0}};
            ki_inc_4  <= {INTEG_WIDTH{1'b0}};
            valid_4   <= 1'b0;
        end else begin
            valid_4   <= valid_3;
            kp_term_4 <= kp_prod_3 >>> KP_SHIFT;
            ki_inc_4  <= ki_prod_3 >>> KI_SHIFT;
        end
    end

    // -----------------------------------------------------------------
    // Stage 5 (final): the persistent integrator state itself -- NOT part
    // of the per-symbol pipeline, just read/updated once per symbol at
    // this final stage. adj_out's sum reads the integrator's CURRENT
    // (pre-update) value -- correct by construction, since both the read
    // (via the RHS of the adj_out assignment) and the integrator's own
    // non-blocking update happen in the same always block/same cycle,
    // same "don't split a value's use and its own update" discipline
    // gmsk_step2d_gardner_ted's header already established. Both the
    // integrator update and the final sum saturate rather than wrap --
    // see header for why that's worth the extra logic here specifically.
    // -----------------------------------------------------------------
    reg signed [INTEG_WIDTH-1:0] integrator;

    // NOTE: Verilog concatenation ({a,b}) is ALWAYS unsigned, regardless of
    // the signedness of its pieces or of the net it's assigned to -- a
    // classic gotcha, and a real one here: the additions below are safe
    // either way (manually sign-extending by one guard bit before an
    // unsigned add still produces the bit-correct two's-complement sum),
    // but the SATURATION COMPARISONS are not safe without an explicit
    // $signed(...) cast on every concatenation -- an unguarded `wide_signed
    // > {1'b0, SOME_MAX}` silently becomes an UNSIGNED comparison the
    // moment one side is a bare concatenation, which would corrupt the
    // clamp logic exactly the safety net above exists to get right. Caught
    // by re-reading this block before trusting it, not by the SIM gate.
    wire signed [INTEG_WIDTH:0] integ_sum_wide =
        $signed({integrator[INTEG_WIDTH-1], integrator}) +
        $signed({ki_inc_4[INTEG_WIDTH-1], ki_inc_4});
    wire signed [INTEG_WIDTH-1:0] integ_next =
        (integ_sum_wide > $signed({1'b0, INTEG_MAX})) ? INTEG_MAX :
        (integ_sum_wide < $signed({1'b1, INTEG_MIN})) ? INTEG_MIN :
        integ_sum_wide[INTEG_WIDTH-1:0];

    wire signed [OUT_WIDTH-1:0]  integ_top = integrator >>> GUARD_BITS;
    wire signed [OUT_WIDTH:0]    adj_sum_wide =
        $signed({kp_term_4[OUT_WIDTH-1], kp_term_4}) +
        $signed({integ_top[OUT_WIDTH-1], integ_top});
    wire signed [OUT_WIDTH-1:0]  adj_next =
        (adj_sum_wide > $signed({1'b0, ADJ_MAX})) ? ADJ_MAX :
        (adj_sum_wide < $signed({1'b1, ADJ_MIN})) ? ADJ_MIN :
        adj_sum_wide[OUT_WIDTH-1:0];

    always @(posedge aclk) begin
        if (!aresetn) begin
            integrator <= {INTEG_WIDTH{1'b0}};
            adj_out    <= {OUT_WIDTH{1'b0}};
            adj_valid  <= 1'b0;
        end else begin
            adj_valid <= valid_4;
            if (valid_4) begin
                adj_out    <= adj_next;
                integrator <= integ_next;
            end
        end
    end

endmodule
