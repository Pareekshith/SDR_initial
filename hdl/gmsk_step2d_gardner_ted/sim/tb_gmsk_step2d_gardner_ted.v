`timescale 1ns / 1ps
//
// tb_gmsk_step2d_gardner_ted -- Sub-step D SIM gate.
//
// Drives the ON/MID sample sequence from gen_test_vectors.py through the
// DUT with gapped (non-back-to-back) valid pulses -- same lesson every
// earlier testbench in this project learned (see gmsk_step1_discriminator's
// and gmsk_step2a_interpolator's own GAP_CYCLES comments).
//
// Capture/check uses the PROVEN self-synchronizing pattern
// gmsk_step1_discriminator's and gmsk_step2a_interpolator's testbenches
// already use successfully: a separate `forever @(posedge clk)` process
// captures m_axis_tdata into an array, in order, every cycle m_axis_tvalid
// pulses -- completely independent of drive timing. This is NOT the same
// as the hand-rolled "delayed valid marker" pattern that raced in an
// earlier version of gmsk_step2b_nco's testbench: here we only ever read
// the DUT's OWN (tvalid,tdata) pair, both updated via NBA in the SAME
// always block at the SAME edge, so they're always mutually consistent by
// construction -- there is no cross-process timing assumption to get
// wrong. An earlier version of THIS testbench mistakenly reused
// gmsk_step2b_nco's simpler single-process "check one cycle after driving"
// pattern, which only worked there because that DUT was a single register
// stage; THIS DUT is a 5-stage pipeline (tag-dispatch -> split -> multiply
// -> recombine -> truncate), so a fixed 1-cycle assumption was wrong from
// the start -- self-synchronizing on m_axis_tvalid sidesteps needing to
// know the exact latency at all.
//
// Three back-to-back epsilon scenarios (locked, +eps, -eps), each preceded
// by a real aresetn pulse and followed by enough drain cycles for the
// pipeline to fully flush before the NEXT scenario's reset -- unlike
// gmsk_step2a_interpolator's mu-phase transitions (which deliberately did
// NOT reset between phases, since the physical delay line genuinely
// carries over), each Gardner scenario here is a physically DISTINCT
// timing condition with its own y_on_prev/mid_latched history that should
// NOT carry over -- gen_test_vectors.py's own reference model resets per
// scenario too, matching this.
//
module tb_gmsk_step2d_gardner_ted;

    localparam integer IN_WIDTH    = 24;
    localparam integer OUT_WIDTH   = 32;
    localparam integer LOBITS      = 15;
    localparam integer N_SCENARIOS = 3;
    localparam integer N_SYMBOLS   = 60;
    // Per scenario: 1 (ON(0)) + N_SYMBOLS*2 (MID,ON pairs) input samples,
    // producing 1+N_SYMBOLS real output pulses (one per ON-TIME sample).
    localparam integer SAMPLES_PER_SCENARIO = 1 + N_SYMBOLS * 2;
    localparam integer OUTPUTS_PER_SCENARIO = 1 + N_SYMBOLS;
    localparam integer NUM_SAMPLES = N_SCENARIOS * SAMPLES_PER_SCENARIO;
    localparam integer NUM_OUTPUTS = N_SCENARIOS * OUTPUTS_PER_SCENARIO;
    localparam integer GAP_CYCLES  = 3;
    localparam integer DRAIN_CYCLES = 20;  // comfortably more than the 5-stage pipeline needs to fully flush

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock -- arbitrary, per-clock streaming test

    reg aresetn = 1'b0;

    reg  signed [IN_WIDTH-1:0]  tdata_mem    [0:NUM_SAMPLES-1];
    reg                         ismid_mem    [0:NUM_SAMPLES-1];
    reg  signed [OUT_WIDTH-1:0] expected_mem [0:NUM_OUTPUTS-1];
    reg  signed [OUT_WIDTH-1:0] captured_mem [0:NUM_OUTPUTS-1];

    reg                          s_axis_tvalid;
    wire                         s_axis_tready;
    reg  signed [IN_WIDTH-1:0]   s_axis_tdata;
    reg                          is_midpoint;

    wire                         m_axis_tvalid;
    wire signed [OUT_WIDTH-1:0]  m_axis_tdata;

    gmsk_step2d_gardner_ted #(
        .IN_WIDTH  (IN_WIDTH),
        .OUT_WIDTH (OUT_WIDTH),
        .LOBITS    (LOBITS)
    ) dut (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .is_midpoint   (is_midpoint),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (1'b1),
        .m_axis_tdata  (m_axis_tdata)
    );

    initial begin
        $readmemh("tdata.hex", tdata_mem);
        $readmemb("is_midpoint.hex", ismid_mem);
        $readmemh("expected_ontime.hex", expected_mem);
    end

    // Capture process -- self-synchronizing on m_axis_tvalid, in order,
    // across the whole run including all three scenarios (aresetn low
    // periods naturally produce no pulses, so scenario boundaries just
    // fall out of the sequence with no special-casing needed here).
    integer cap_idx;
    initial begin
        cap_idx = 0;
        forever begin
            @(posedge clk);
            if (m_axis_tvalid && cap_idx < NUM_OUTPUTS) begin
                captured_mem[cap_idx] = m_axis_tdata;
                cap_idx = cap_idx + 1;
            end
        end
    end

    // Driver process.
    integer scenario, k, drive_idx;
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = {IN_WIDTH{1'b0}};
        is_midpoint   = 1'b0;
        drive_idx     = 0;

        for (scenario = 0; scenario < N_SCENARIOS; scenario = scenario + 1) begin
            aresetn = 1'b0;
            repeat (5) @(posedge clk);
            #1;
            aresetn = 1'b1;
            @(posedge clk);
            #1;

            for (k = 0; k < SAMPLES_PER_SCENARIO; k = k + 1) begin
                s_axis_tdata  = tdata_mem[drive_idx];
                is_midpoint   = ismid_mem[drive_idx];
                s_axis_tvalid = 1'b1;
                @(posedge clk);
                #1;
                s_axis_tvalid = 1'b0;
                drive_idx = drive_idx + 1;
                repeat (GAP_CYCLES) @(posedge clk);
                #1;
            end

            repeat (DRAIN_CYCLES) @(posedge clk);
            #1;
        end

        // Give the capture process one more cycle to register the very
        // last pulse (it triggers on the SAME edge as this process's last
        // @(posedge clk), but drains via the drain-cycle wait above anyway).
        @(posedge clk);
        #1;

        if (cap_idx !== NUM_OUTPUTS)
            $display("WARNING: captured %0d outputs, expected %0d -- pipeline may not have fully drained",
                      cap_idx, NUM_OUTPUTS);

        check_all;
    end

    task check_all;
        integer i, errors;
        real scenario_sum;
        integer scenario_n, scenario_of_i, base;
        begin
            errors = 0;
            for (i = 0; i < NUM_OUTPUTS && i < cap_idx; i = i + 1) begin
                if (captured_mem[i] !== expected_mem[i]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("FAIL: output %0d got=%0d expected=%0d",
                                  i, captured_mem[i], expected_mem[i]);
                end
            end

            // Per-scenario average printout -- physical sanity cross-check,
            // mirrors gen_test_vectors.py's own printout, not a pass/fail gate.
            for (scenario_of_i = 0; scenario_of_i < N_SCENARIOS; scenario_of_i = scenario_of_i + 1) begin
                base = scenario_of_i * OUTPUTS_PER_SCENARIO;
                scenario_sum = 0.0;
                scenario_n = 0;
                for (i = 4; i < OUTPUTS_PER_SCENARIO; i = i + 1) begin  // skip first few (settle), same margin as the generator
                    scenario_sum = scenario_sum + $itor(captured_mem[base + i]);
                    scenario_n = scenario_n + 1;
                end
                if (scenario_n > 0)
                    $display("Scenario %0d: avg error over %0d symbols = %.1f",
                              scenario_of_i, scenario_n, scenario_sum / scenario_n);
            end

            $display("Checked %0d of %0d expected outputs.", cap_idx, NUM_OUTPUTS);
            if (errors == 0 && cap_idx == NUM_OUTPUTS)
                $display("TEST PASSED");
            else
                $display("TEST FAILED (%0d data errors, captured %0d of %0d)",
                          errors, cap_idx, NUM_OUTPUTS);

            $finish;
        end
    endtask

endmodule
