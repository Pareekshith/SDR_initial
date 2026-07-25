`timescale 1ns / 1ps
//
// gmsk_step1_discriminator — Step 1: frequency discriminator (see
// docs/step1_discriminator.html and project_fpga_gmsk_plan memory for the
// full design rationale).
//
// GMSK/FSK carries data in how fast the phase is rotating, not in raw I/Q.
// This block turns a complex baseband sample stream into a per-sample
// instantaneous-frequency estimate using the standard "delay-and-conjugate-
// multiply" quadrature FM demodulator trick instead of a CORDIC:
//
//   z[n]  = I[n] + jQ[n]
//   Im{ z[n] * conj(z[n-1]) } = Q[n]*I[n-1] - I[n]*Q[n-1]  ~ sin(dtheta[n])
//
// Only the imaginary part is computed (2 multiplies + 1 subtract), since the
// real part is never consumed downstream — no point building the other two
// multiplies just to discard the result.
//
// Interface convention: AXI4-Stream, one complex sample in -> one
// discriminator sample out, every clock, no rate change. TDATA packs the
// input sample as {Q[IQ_WIDTH-1:0], I[IQ_WIDTH-1:0]}, matching the packing
// ADI's util_cpack2/util_upack2 cores use for a single-channel complex
// stream. IQ_WIDTH defaults to 16 to match the AD9361 RX chain's native
// sign-extended word width (see axi_ad9361_rx_channel.v) — confirm against
// the actual axi_ad9361 output width when this is wired into the real block
// design (Step 4 integration), since this module was written/simulated
// standalone before that wiring exists.
//
// This block assumes a fixed-rate streaming pipeline: every stage in the RX
// fabric chain runs at the same sample clock with no framing/backpressure,
// so s_axis_tready is tied high rather than derived from m_axis_tready —
// there is no scenario in this fixed-rate chain where downstream would need
// to stall it.
//
module gmsk_step1_discriminator #
(
    parameter integer IQ_WIDTH  = 16,                  // native signed I/Q width
    parameter integer OUT_WIDTH = 18                   // discriminator output width
)
(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire [2*IQ_WIDTH-1:0]         s_axis_tdata,   // {Q, I}

    output reg                           m_axis_tvalid,
    input  wire                          m_axis_tready,
    output reg  signed [OUT_WIDTH-1:0]   m_axis_tdata    // discriminator out
);

    // Full-precision product width: two IQ_WIDTH-bit signed multiplies
    // summed needs one extra guard bit beyond 2*IQ_WIDTH to avoid overflow.
    localparam integer PROD_WIDTH  = 2*IQ_WIDTH + 1;
    localparam integer TRUNC_SHIFT = PROD_WIDTH - OUT_WIDTH;

    wire signed [IQ_WIDTH-1:0] i_in = s_axis_tdata[IQ_WIDTH-1:0];
    wire signed [IQ_WIDTH-1:0] q_in = s_axis_tdata[2*IQ_WIDTH-1:IQ_WIDTH];

    assign s_axis_tready = 1'b1;

    // -----------------------------------------------------------------
    // Stage 0: 1-sample delay register -> holds z[n-1] for the multiply
    // that runs the following cycle.
    // -----------------------------------------------------------------
    reg signed [IQ_WIDTH-1:0] i_prev, q_prev;
    reg                       valid_d0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            i_prev   <= {IQ_WIDTH{1'b0}};
            q_prev   <= {IQ_WIDTH{1'b0}};
            valid_d0 <= 1'b0;
        end else begin
            valid_d0 <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                i_prev <= i_in;
                q_prev <= q_in;
            end
        end
    end

    // -----------------------------------------------------------------
    // Stage 1: the two multiplies this block actually needs (real part of
    // the complex product is never computed).
    // -----------------------------------------------------------------
    reg signed [2*IQ_WIDTH-1:0] mult_qi, mult_iq;
    reg                         valid_d1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            mult_qi  <= {2*IQ_WIDTH{1'b0}};
            mult_iq  <= {2*IQ_WIDTH{1'b0}};
            valid_d1 <= 1'b0;
        end else begin
            valid_d1 <= valid_d0;
            mult_qi  <= q_in * i_prev;   // Q[n]  * I[n-1]
            mult_iq  <= i_in * q_prev;   // I[n]  * Q[n-1]
        end
    end

    // -----------------------------------------------------------------
    // Stage 2: subtract, then truncate down to OUT_WIDTH so precision
    // doesn't grow unbounded through the rest of the RX chain. Keeps the
    // top OUT_WIDTH bits of the full-precision product (arithmetic
    // right-shift), matching how the rest of this fixed-point pipeline
    // rescales after a multiply.
    // -----------------------------------------------------------------
    wire signed [PROD_WIDTH-1:0] imag_full = mult_qi - mult_iq;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {OUT_WIDTH{1'b0}};
        end else begin
            m_axis_tvalid <= valid_d1;
            m_axis_tdata  <= imag_full >>> TRUNC_SHIFT;
        end
    end

endmodule
