`timescale 1ns / 1ps
//
// tb_gmsk_step2b2_nco -- Sub-step B2 SIM gate.
//
// Structurally identical to gmsk_step2b_nco's own proven testbench (this
// DUT is likewise a single registered stage, no multi-stage pipeline, so
// that pattern applies directly -- unlike gmsk_step2d_gardner_ted, which
// needed the different self-synchronizing capture pattern for its 5-stage
// pipeline). Single drive+check process, `#1` settle delay after every
// `@(posedge clk)` before reading any DUT signal, and a `#1` landing after
// every gap-wait before the next iteration's blocking assignments -- both
// specifically to avoid the two same-edge races gmsk_step2b_nco's own
// testbench hit and documented (see that testbench's header for the full
// account).
//
module tb_gmsk_step2b2_nco;

    localparam integer STEP_WIDTH  = 32;
    localparam integer MU_WIDTH    = 16;
    localparam integer LOG2_SPS    = 2;
    localparam integer NUM_SAMPLES = 3000;  // 3 phases x 1000 samples (gen_test_vectors.py)
    localparam integer GAP_CYCLES  = 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock -- arbitrary, per-clock streaming test

    reg aresetn = 1'b0;

    reg  [STEP_WIDTH-1:0]        step_mem            [0:NUM_SAMPLES-1];
    reg  [STEP_WIDTH-1:0]        adj_mem             [0:NUM_SAMPLES-1];
    reg                          expected_strobe_mem [0:NUM_SAMPLES-1];
    reg                          expected_ismid_mem  [0:NUM_SAMPLES-1];
    reg  [MU_WIDTH-1:0]          expected_mu_mem     [0:NUM_SAMPLES-1];

    reg                          sample_valid;
    reg  [STEP_WIDTH-1:0]        step_in;
    reg  signed [STEP_WIDTH-1:0] adj_in;

    wire                         strobe;
    wire                         is_midpoint;
    wire [MU_WIDTH-1:0]          mu_out;

    gmsk_step2b2_nco #(
        .STEP_WIDTH (STEP_WIDTH),
        .MU_WIDTH   (MU_WIDTH),
        .LOG2_SPS   (LOG2_SPS)
    ) dut (
        .aclk         (clk),
        .aresetn      (aresetn),
        .sample_valid (sample_valid),
        .step_in      (step_in),
        .adj_in       (adj_in),
        .strobe       (strobe),
        .is_midpoint  (is_midpoint),
        .mu_out       (mu_out)
    );

    initial begin
        $readmemh("step.hex", step_mem);
        $readmemh("adj.hex", adj_mem);
        $readmemb("expected_strobe.hex", expected_strobe_mem);
        $readmemb("expected_ismid.hex", expected_ismid_mem);
        $readmemh("expected_mu.hex", expected_mu_mem);
    end

    integer drive_idx;
    integer strobe_errors, ismid_errors, mu_errors;
    integer on_count, mid_count;

    initial begin
        sample_valid  = 1'b0;
        step_in       = {STEP_WIDTH{1'b0}};
        adj_in        = {STEP_WIDTH{1'b0}};
        strobe_errors = 0;
        ismid_errors  = 0;
        mu_errors     = 0;
        on_count      = 0;
        mid_count     = 0;

        repeat (5) @(posedge clk);
        #1;
        aresetn = 1'b1;
        @(posedge clk);
        #1;

        for (drive_idx = 0; drive_idx < NUM_SAMPLES; drive_idx = drive_idx + 1) begin
            step_in      = step_mem[drive_idx];
            adj_in       = adj_mem[drive_idx];
            sample_valid = 1'b1;
            @(posedge clk);
            #1;
            sample_valid = 1'b0;

            if (strobe !== expected_strobe_mem[drive_idx]) begin
                strobe_errors = strobe_errors + 1;
                if (strobe_errors <= 20)
                    $display("FAIL(strobe): sample %0d got=%0b expected=%0b",
                              drive_idx, strobe, expected_strobe_mem[drive_idx]);
            end
            // is_midpoint/mu_out are only meaningful (per the AXI-stream-like
            // convention every module in this project uses) on cycles where
            // strobe itself is asserted -- check them gated on strobe, same
            // as gmsk_step2a_interpolator's own m_axis_tdata-only-valid-when-
            // m_axis_tvalid convention.
            if (strobe) begin
                if (is_midpoint !== expected_ismid_mem[drive_idx]) begin
                    ismid_errors = ismid_errors + 1;
                    if (ismid_errors <= 20)
                        $display("FAIL(is_midpoint): sample %0d got=%0b expected=%0b",
                                  drive_idx, is_midpoint, expected_ismid_mem[drive_idx]);
                end
                if (mu_out !== expected_mu_mem[drive_idx]) begin
                    mu_errors = mu_errors + 1;
                    if (mu_errors <= 20)
                        $display("FAIL(mu): sample %0d got=%0d expected=%0d",
                                  drive_idx, mu_out, expected_mu_mem[drive_idx]);
                end
                if (is_midpoint) mid_count = mid_count + 1;
                else on_count = on_count + 1;
            end

            repeat (GAP_CYCLES) @(posedge clk);
            #1;
        end

        $display("Checked %0d samples: %0d on-time strobes, %0d mid-point strobes.",
                  NUM_SAMPLES, on_count, mid_count);
        if (strobe_errors == 0 && ismid_errors == 0 && mu_errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d strobe errors, %0d is_midpoint errors, %0d mu errors)",
                      strobe_errors, ismid_errors, mu_errors);

        $finish;
    end

endmodule
