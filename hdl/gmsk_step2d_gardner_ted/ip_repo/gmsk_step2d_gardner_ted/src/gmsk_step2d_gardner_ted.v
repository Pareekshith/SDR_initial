`timescale 1ns / 1ps
//
// gmsk_step2d_gardner_ted -- Sub-step D: Gardner timing-error detector,
// standalone. See docs/rx_roadmap.html Step 3 and project_fpga_gmsk_plan
// memory for the full sub-step breakdown this belongs to (A = interpolator
// core, done + hardware-validated; B = NCO/phase accumulator, done +
// hardware-validated; D = this module; F = the closed loop wiring
// A+B+D+loop-filter together, not yet built).
//
// Gardner's algorithm (Gardner 1986; also in Mengali & D'Andrea) measures
// how far off the current sampling instant is from the true symbol center,
// using THREE interpolated samples per symbol period: the on-time sample
// from the symbol just decided, the on-time sample from the symbol before
// that, and one extra sample taken exactly HALFWAY between them (the
// "mid-point"). The classic error formula:
//
//   e[n] = (y_on[n] - y_on[n-1]) * y_mid[n]
//
// Intuition: y_mid sits where the signal is doing the most changing (the
// transition between two symbols), so its value is a good proxy for "which
// direction and how fast the signal was moving right at that instant." If
// the true symbol boundary already passed by the time y_mid was sampled,
// the sign of that motion correlates with whether the *current* on-time
// sample was measured too late or too early -- multiplying by (y_on[n] -
// y_on[n-1]) turns that raw "which way was it moving" reading into a
// signed error whose sign says which direction to nudge the sampling
// instant, and it's naturally near-zero on average once locked (right at
// the symbol center, the signal simply isn't changing much between
// consecutive on-time samples relative to how much it's changing at the
// mid-point crossing -- see docs/step2d_gardner_ted.html for the intuitive
// walkthrough and interactive demo).
//
// Sub-step context: this module does NOT compute y_on/y_mid itself --
// those come from gmsk_step2a_interpolator, evaluated at two different mu
// values one symbol-half apart. It also does NOT drive an NCO's adj_in --
// that's the loop filter (not yet built) sitting between this module's
// output and gmsk_step2b_nco's adj_in, sub-step E's job. This sub-step is
// purely the arithmetic core, exercised standalone against externally
// supplied ON/MID sample values (same "build the real core now, test with
// synthetic stimulus first" philosophy every earlier sub-step in this
// project used).
//
// Input protocol (not enforced in hardware, documented here and relied on
// by the SIM gate): samples arrive in strict alternating order, tagged by
// is_midpoint --
//   ON(n-1), MID(n-1/2), ON(n), MID(n+1/2), ON(n+1), ...
// i.e. each MID sample is expected between the two ON samples whose
// difference it will be multiplied against. In the eventual closed loop
// (sub-step F) this alternation is what an NCO producing TWO strobes per
// symbol (one on-time, one at the half-symbol point) naturally provides --
// out of scope for this standalone sub-step, which just assumes the
// caller/testbench already delivers samples in this order.
//
// No AXI4-Stream naming for is_midpoint (a plain sideband tag, sampled the
// same cycle as s_axis_tdata) -- same category as the interpolator's own
// mu_in and the NCO's step_in/adj_in: a real, permanent port, just not a
// bus interface.
//
// DSP48E1 width note: this is the SAME lesson gmsk_step2a_interpolator's
// six real-hardware timing bugs already taught this project (registered-
// in/registered-out around every multiply, split any operand wider than
// DSP48E1's 18-bit "B" limit into hi/lo halves before multiplying) --
// applied here from the start instead of rediscovered the hard way. diff
// (IN_WIDTH+1 bits) fits the 25-bit "A" operand whole; y_mid (IN_WIDTH
// bits) is the one that needs splitting since it can exceed the 18-bit "B"
// limit for IN_WIDTH>18 (true for this project's IN_WIDTH=24 default).
//
module gmsk_step2d_gardner_ted #
(
    parameter integer IN_WIDTH  = 24,  // matches gmsk_step2a_interpolator's OUT_WIDTH
    parameter integer OUT_WIDTH = 32,  // must be a multiple of 8 (AXI4-Stream TDATA rule)
    parameter integer LOBITS    = 15   // hi/lo split point for the y_mid operand, same split point gmsk_step2a_interpolator uses throughout
)
(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire signed [IN_WIDTH-1:0]    s_axis_tdata,   // interpolated sample value -- either an on-time or mid-point sample, per is_midpoint
    input  wire                          is_midpoint,     // 1 = this sample is the mid-symbol point, 0 = on-time point. Strict ON,MID,ON,MID,... alternation expected, see header.

    output reg                           m_axis_tvalid,   // pulses once per ON-TIME sample consumed (i.e. once per symbol) -- Gardner error is only meaningful at symbol rate
    input  wire                          m_axis_tready,
    output reg  signed [OUT_WIDTH-1:0]   m_axis_tdata     // e[n] = (y_on[n]-y_on[n-1]) * y_mid[n], truncated to OUT_WIDTH -- see TRUNC_SHIFT below
);

    assign s_axis_tready = 1'b1;

    localparam integer DIFF_WIDTH = IN_WIDTH + 1;                 // y_on[n]-y_on[n-1], natural guard bit for a subtract
    localparam integer HI_WIDTH   = IN_WIDTH - LOBITS;             // 9 for the defaults -- y_mid's hi half, comfortably under the 18-bit "B" limit
    localparam integer LO_SWIDTH  = LOBITS + 1;                    // y_mid's lo half, zero-extended into a signed container for the multiply
    localparam integer PRODW      = DIFF_WIDTH + IN_WIDTH;         // exact natural width of diff * y_mid (25+24=49 for the defaults) -- no padding, see header's DSP48 note
    localparam integer TRUNC_SHIFT = PRODW - OUT_WIDTH;            // same truncate-to-OUT_WIDTH pattern gmsk_step1_discriminator uses

    // -----------------------------------------------------------------
    // Stage 1: tag-dispatch. On a MID sample, just latch it (nothing else
    // changes). On an ON-TIME sample, compute the on-time difference
    // against the PREVIOUS on-time sample, forward the mid value latched
    // since that previous on-time sample, and update the on-time history
    // for next time -- all atomically in the same branch, same "avoid the
    // exact bug class gmsk_step1_discriminator hit on real hardware"
    // discipline every delay-line-holding module in this project uses
    // (never split a value's use and its own update across two
    // separately-timed always-block branches).
    // -----------------------------------------------------------------
    reg signed [IN_WIDTH-1:0]   y_on_prev;
    reg signed [IN_WIDTH-1:0]   mid_latched;

    reg signed [DIFF_WIDTH-1:0] diff_1;
    reg signed [IN_WIDTH-1:0]   mid_1;
    reg                         valid_1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            y_on_prev   <= {IN_WIDTH{1'b0}};
            mid_latched <= {IN_WIDTH{1'b0}};
            diff_1      <= {DIFF_WIDTH{1'b0}};
            mid_1       <= {IN_WIDTH{1'b0}};
            valid_1     <= 1'b0;
        end else begin
            valid_1 <= 1'b0;  // default: pulses only for the one cycle below
            if (s_axis_tvalid) begin
                if (is_midpoint) begin
                    mid_latched <= s_axis_tdata;
                end else begin
                    diff_1    <= s_axis_tdata - y_on_prev;
                    mid_1     <= mid_latched;
                    y_on_prev <= s_axis_tdata;
                    valid_1   <= 1'b1;
                end
            end
        end
    end

    // -----------------------------------------------------------------
    // Stage 2: split mid_1 into hi (signed, arithmetic-shifted, naturally
    // signed already)/lo (unsigned magnitude) halves. diff is forwarded
    // whole -- it already fits DSP48E1's 25-bit "A" operand, no split
    // needed.
    // -----------------------------------------------------------------
    (* srl_style = "register" *) reg signed [HI_WIDTH-1:0]   mid_hi_2;
    (* srl_style = "register" *) reg        [LOBITS-1:0]     mid_lo_2;
    (* srl_style = "register" *) reg signed [DIFF_WIDTH-1:0] diff_2;
    (* srl_style = "register" *) reg                         valid_2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mid_hi_2 <= {HI_WIDTH{1'b0}};
            mid_lo_2 <= {LOBITS{1'b0}};
            diff_2   <= {DIFF_WIDTH{1'b0}};
            valid_2  <= 1'b0;
        end else begin
            valid_2  <= valid_1;
            mid_hi_2 <= mid_1 >>> LOBITS;
            mid_lo_2 <= mid_1[LOBITS-1:0];
            diff_2   <= diff_1;
        end
    end

    // -----------------------------------------------------------------
    // Stage 3: the two single-DSP48-safe partial-product multiplies,
    // registered-out immediately (nothing else shares this cycle) -- the
    // exact pattern that reliably gets Vivado to infer real DSP48s,
    // learned the hard way on gmsk_step2a_interpolator.
    // -----------------------------------------------------------------
    (* srl_style = "register" *) reg signed [DIFF_WIDTH+HI_WIDTH-1:0]  ph_3;
    (* srl_style = "register" *) reg signed [DIFF_WIDTH+LO_SWIDTH-1:0] pl_3;
    (* srl_style = "register" *) reg                                  valid_3;

    always @(posedge aclk) begin
        if (!aresetn) begin
            ph_3    <= {(DIFF_WIDTH+HI_WIDTH){1'b0}};
            pl_3    <= {(DIFF_WIDTH+LO_SWIDTH){1'b0}};
            valid_3 <= 1'b0;
        end else begin
            valid_3 <= valid_2;
            ph_3    <= diff_2 * mid_hi_2;
            pl_3    <= diff_2 * $signed({1'b0, mid_lo_2});
        end
    end

    // -----------------------------------------------------------------
    // Stage 4: recombine (shift+add, not a multiply -- safe to combine
    // with other logic, unlike every multiply above) into the exact
    // natural-width product diff*y_mid.
    // -----------------------------------------------------------------
    reg signed [PRODW-1:0] prod_4;
    reg                    valid_4;

    always @(posedge aclk) begin
        if (!aresetn) begin
            prod_4  <= {PRODW{1'b0}};
            valid_4 <= 1'b0;
        end else begin
            valid_4 <= valid_3;
            prod_4  <= (ph_3 <<< LOBITS) + pl_3;
        end
    end

    // -----------------------------------------------------------------
    // Stage 5: truncate to OUT_WIDTH, same TRUNC_SHIFT pattern
    // gmsk_step1_discriminator uses (right-shift then let the narrower
    // target register keep only the low OUT_WIDTH bits). Sized for
    // full-scale worst case, same conservative starting point the
    // discriminator's own OUT_WIDTH originally used -- worth revisiting
    // once real signal amplitudes through this stage are known, same
    // evolution the discriminator itself went through (see project
    // memory, "Discriminator OUT_WIDTH widened 16->24").
    // -----------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {OUT_WIDTH{1'b0}};
        end else begin
            m_axis_tvalid <= valid_4;
            m_axis_tdata  <= prod_4 >>> TRUNC_SHIFT;
        end
    end

endmodule
