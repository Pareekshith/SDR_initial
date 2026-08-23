`timescale 1ns / 1ps
//
// tb_gmsk_step2e_loop_filter -- Sub-step E SIM gate.
//
// Two DUT instances, matching gen_test_vectors.py's own two-phase split:
//   dut     -- production illustrative gains (KP_INT=1/KP_SHIFT=2,
//              KI_INT=1/KI_SHIFT=2), driven with a realistic mix of small
//              real-captured-range e[n] values (both signs). Confirms
//              normal accumulation is correct and the integrator's own
//              GUARD_BITS precision genuinely lets small increments
//              accumulate instead of truncating to zero every symbol.
//   dut_sat -- SAME arithmetic/clamp RTL, just instantiated with a much
//              larger Ki_INT (see gen_test_vectors.py's KI_INT_SAT
//              comment) so both saturation rails are reachable within a
//              practical number of test vectors -- the production dut's
//              own gains would need ~2.6e5 symbols to ever reach
//              INTEG_MAX, not a realistic testbench length. This instance
//              is what actually exercises the saturating-add fix (a real
//              bug -- Verilog concatenation being unsigned by default,
//              silently corrupting the clamp comparisons -- caught by
//              re-reading the RTL and fixed before this testbench was
//              written; this run is what proves the fix, not just trusts
//              the re-reading).
//
// Capture uses the PROVEN self-synchronizing pattern this project's
// multi-stage-pipeline testbenches already use (gmsk_step2d_gardner_ted,
// gmsk_step2b2_nco): a separate process captures (adj_out, integrator's
// externally-unobservable state is NOT checked directly -- only adj_out,
// which is the module's real interface) whenever adj_valid pulses,
// independent of drive timing or exact pipeline depth.
//
module tb_gmsk_step2e_loop_filter;

    localparam integer IN_WIDTH     = 32;
    localparam integer OUT_WIDTH    = 32;
    localparam integer GAIN_WIDTH   = 18;
    localparam integer LOBITS       = 16;
    localparam integer GUARD_BITS   = 16;

    localparam integer N_PHASE1 = 200;
    localparam integer N_PHASE2 = 160;
    localparam integer GAP_CYCLES = 3;
    localparam integer DRAIN_CYCLES = 20;  // comfortably more than this 6-stage pipeline needs to flush (5->6 after the 2026-08-24 timing fix split Stage 5 into 5a/5b)

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg aresetn = 1'b0;

    // ---- dut (production gains) ----
    reg  signed [IN_WIDTH-1:0]  p1_e_mem      [0:N_PHASE1-1];
    reg  signed [OUT_WIDTH-1:0] p1_exp_adj    [0:N_PHASE1-1];
    reg  signed [OUT_WIDTH-1:0] p1_cap_adj    [0:N_PHASE1-1];

    reg                          s_axis_tvalid;
    reg  signed [IN_WIDTH-1:0]   s_axis_tdata;
    wire                         adj_valid;
    wire signed [OUT_WIDTH-1:0]  adj_out;

    gmsk_step2e_loop_filter #(
        .IN_WIDTH   (IN_WIDTH),
        .OUT_WIDTH  (OUT_WIDTH),
        .GAIN_WIDTH (GAIN_WIDTH),
        .LOBITS     (LOBITS),
        .GUARD_BITS (GUARD_BITS),
        .KP_INT     (1),
        .KP_SHIFT   (2),
        .KI_INT     (1),
        .KI_SHIFT   (2)
    ) dut (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (),
        .s_axis_tdata  (s_axis_tdata),
        .adj_valid     (adj_valid),
        .adj_out       (adj_out)
    );

    // ---- dut_sat (saturation stress: much larger Ki_INT) ----
    reg  signed [IN_WIDTH-1:0]  p2_e_mem      [0:N_PHASE2-1];
    reg  signed [OUT_WIDTH-1:0] p2_exp_adj    [0:N_PHASE2-1];
    reg  signed [OUT_WIDTH-1:0] p2_cap_adj    [0:N_PHASE2-1];

    reg                          s_axis_tvalid_sat;
    reg  signed [IN_WIDTH-1:0]   s_axis_tdata_sat;
    wire                         adj_valid_sat;
    wire signed [OUT_WIDTH-1:0]  adj_out_sat;

    gmsk_step2e_loop_filter #(
        .IN_WIDTH   (IN_WIDTH),
        .OUT_WIDTH  (OUT_WIDTH),
        .GAIN_WIDTH (GAIN_WIDTH),
        .LOBITS     (LOBITS),
        .GUARD_BITS (GUARD_BITS),
        .KP_INT     (1),
        .KP_SHIFT   (2),
        .KI_INT     (8192),
        .KI_SHIFT   (2)
    ) dut_sat (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid_sat),
        .s_axis_tready (),
        .s_axis_tdata  (s_axis_tdata_sat),
        .adj_valid     (adj_valid_sat),
        .adj_out       (adj_out_sat)
    );

    initial begin
        $readmemh("phase1_e_in.hex",         p1_e_mem);
        $readmemh("phase1_expected_adj.hex", p1_exp_adj);
        $readmemh("phase2_e_in.hex",         p2_e_mem);
        $readmemh("phase2_expected_adj.hex", p2_exp_adj);
    end

    // Capture processes -- self-synchronizing on each DUT's own adj_valid,
    // independent of drive timing/exact pipeline depth.
    integer p1_cap_idx, p2_cap_idx;

    initial begin
        p1_cap_idx = 0;
        forever begin
            @(posedge clk);
            if (adj_valid && p1_cap_idx < N_PHASE1) begin
                p1_cap_adj[p1_cap_idx] = adj_out;
                p1_cap_idx = p1_cap_idx + 1;
            end
        end
    end

    initial begin
        p2_cap_idx = 0;
        forever begin
            @(posedge clk);
            if (adj_valid_sat && p2_cap_idx < N_PHASE2) begin
                p2_cap_adj[p2_cap_idx] = adj_out_sat;
                p2_cap_idx = p2_cap_idx + 1;
            end
        end
    end

    // Driver process -- both DUTs driven in lockstep off the same reset
    // and clock (independent input streams, no interaction between them;
    // running both at once just keeps the testbench short).
    integer k;
    initial begin
        s_axis_tvalid     = 1'b0;
        s_axis_tdata      = {IN_WIDTH{1'b0}};
        s_axis_tvalid_sat = 1'b0;
        s_axis_tdata_sat  = {IN_WIDTH{1'b0}};

        aresetn = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        aresetn = 1'b1;
        @(posedge clk);
        #1;

        for (k = 0; k < N_PHASE1 || k < N_PHASE2; k = k + 1) begin
            if (k < N_PHASE1) begin
                s_axis_tdata  = p1_e_mem[k];
                s_axis_tvalid = 1'b1;
            end
            if (k < N_PHASE2) begin
                s_axis_tdata_sat  = p2_e_mem[k];
                s_axis_tvalid_sat = 1'b1;
            end
            @(posedge clk);
            #1;
            s_axis_tvalid     = 1'b0;
            s_axis_tvalid_sat = 1'b0;
            repeat (GAP_CYCLES) @(posedge clk);
            #1;
        end

        repeat (DRAIN_CYCLES) @(posedge clk);
        #1;

        if (p1_cap_idx !== N_PHASE1)
            $display("WARNING: dut captured %0d outputs, expected %0d -- pipeline may not have fully drained",
                      p1_cap_idx, N_PHASE1);
        if (p2_cap_idx !== N_PHASE2)
            $display("WARNING: dut_sat captured %0d outputs, expected %0d -- pipeline may not have fully drained",
                      p2_cap_idx, N_PHASE2);

        check_all;
    end

    task check_all;
        integer i, errors1, errors2;
        begin
            errors1 = 0;
            for (i = 0; i < N_PHASE1 && i < p1_cap_idx; i = i + 1) begin
                if (p1_cap_adj[i] !== p1_exp_adj[i]) begin
                    errors1 = errors1 + 1;
                    if (errors1 <= 20)
                        $display("FAIL(dut):     n=%0d got=%0d expected=%0d", i, p1_cap_adj[i], p1_exp_adj[i]);
                end
            end
            $display("dut (production gains): checked %0d of %0d, %0d errors", p1_cap_idx, N_PHASE1, errors1);

            errors2 = 0;
            for (i = 0; i < N_PHASE2 && i < p2_cap_idx; i = i + 1) begin
                if (p2_cap_adj[i] !== p2_exp_adj[i]) begin
                    errors2 = errors2 + 1;
                    if (errors2 <= 20)
                        $display("FAIL(dut_sat): n=%0d got=%0d expected=%0d", i, p2_cap_adj[i], p2_exp_adj[i]);
                end
            end
            $display("dut_sat (saturation stress): checked %0d of %0d, %0d errors", p2_cap_idx, N_PHASE2, errors2);

            if (errors1 == 0 && errors2 == 0 && p1_cap_idx == N_PHASE1 && p2_cap_idx == N_PHASE2)
                $display("TEST PASSED");
            else
                $display("TEST FAILED");

            $finish;
        end
    endtask

endmodule
