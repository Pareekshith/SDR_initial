`timescale 1ns / 1ps
//
// tb_gmsk_step2a_interpolator -- Sub-step A SIM gate.
//
// Feeds the sine-wave test vectors from gen_test_vectors.py through the DUT
// at a few fixed mu values and self-checks each interpolated output against
// the analytically-exact expected value computed in Python (which mirrors
// the RTL's own delay-line indexing, so expected[] is already in the exact
// order the RTL will emit -- see the generator's header comment).
//
// GAP_CYCLES: drives sparse (non-back-to-back) valid pulses, same lesson
// gmsk_step1_discriminator's testbench learned the hard way (see its own
// GAP_CYCLES comment) -- a delay line that only looks right under
// back-to-back valid inputs can hide a real bug that only shows up with
// idle gaps between samples, which is what real hardware always has.
//
module tb_gmsk_step2a_interpolator;

    localparam integer IN_WIDTH    = 24;
    localparam integer OUT_WIDTH   = 24;
    localparam integer MU_WIDTH    = 16;
    localparam integer NUM_SAMPLES = 800;   // 4 mu phases x 200 samples (gen_test_vectors.py)
    localparam integer GAP_CYCLES  = 3;
    localparam integer SETTLE_SAMPLES = 10; // skip the first few until the delay line is fully real signal

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock -- arbitrary, per-clock streaming test

    reg aresetn = 1'b0;

    reg  signed [IN_WIDTH-1:0]  input_mem    [0:NUM_SAMPLES-1];
    reg         [MU_WIDTH-1:0]  mu_mem       [0:NUM_SAMPLES-1];
    reg  signed [OUT_WIDTH-1:0] expected_mem [0:NUM_SAMPLES-1];
    reg  signed [OUT_WIDTH-1:0] captured     [0:NUM_SAMPLES-1];

    reg                          s_axis_tvalid;
    wire                         s_axis_tready;
    reg  signed [IN_WIDTH-1:0]   s_axis_tdata;
    reg         [MU_WIDTH-1:0]   mu_in;
    wire                         m_axis_tvalid;
    wire signed [OUT_WIDTH-1:0]  m_axis_tdata;

    gmsk_step2a_interpolator #(
        .IN_WIDTH  (IN_WIDTH),
        .OUT_WIDTH (OUT_WIDTH),
        .MU_WIDTH  (MU_WIDTH)
    ) dut (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .mu_in         (mu_in),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (1'b1),
        .m_axis_tdata  (m_axis_tdata)
    );

    initial begin
        $readmemh("input.hex", input_mem);
        $readmemh("mu.hex", mu_mem);
        $readmemh("expected.hex", expected_mem);
    end

    // Drive one sample every (1 + GAP_CYCLES) clocks once out of reset.
    integer idx, g;
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = {IN_WIDTH{1'b0}};
        mu_in         = {MU_WIDTH{1'b0}};
        repeat (5) @(posedge clk);
        aresetn = 1'b1;
        @(posedge clk);
        for (idx = 0; idx < NUM_SAMPLES; idx = idx + 1) begin
            s_axis_tdata  = input_mem[idx];
            mu_in         = mu_mem[idx];
            s_axis_tvalid = 1'b1;
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            for (g = 0; g < GAP_CYCLES; g = g + 1)
                @(posedge clk);
        end
    end

    // Capture: self-synchronizing to m_axis_tvalid pulses, order-preserving
    // -- every valid input produces exactly one valid output, later, in the
    // same order (same pattern as gmsk_step1_discriminator's testbench).
    integer cap_idx;
    initial begin
        cap_idx = 0;
        forever begin
            @(posedge clk);
            if (aresetn && m_axis_tvalid && cap_idx < NUM_SAMPLES) begin
                captured[cap_idx] = m_axis_tdata;
                cap_idx = cap_idx + 1;
            end
        end
    end

    // Analysis.
    integer i;
    integer errors;
    real dev, max_dev;
    real abs_tol;
    localparam real ABS_TOL = 1000.0;  // ~0.33% of AMPLITUDE=300000 -- observed
                                        // max deviation is ~607 (cubic-vs-sine
                                        // approximation error), so this still
                                        // has real margin without being a no-op

    initial begin
        errors = 0;
        max_dev = 0.0;
        wait (cap_idx >= NUM_SAMPLES);
        repeat (10) @(posedge clk);

        for (i = SETTLE_SAMPLES; i < NUM_SAMPLES; i = i + 1) begin
            dev = captured[i] - expected_mem[i];
            if (dev < 0) dev = -dev;
            if (dev > max_dev) max_dev = dev;
            if (dev > ABS_TOL) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL: sample %0d captured=%0d expected=%0d dev=%.1f",
                              i, captured[i], expected_mem[i], dev);
            end
        end

        $display("Max deviation across %0d checked samples: %.1f (tolerance %.1f)",
                  NUM_SAMPLES - SETTLE_SAMPLES, max_dev, ABS_TOL);

        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors)", errors);

        $finish;
    end

endmodule
