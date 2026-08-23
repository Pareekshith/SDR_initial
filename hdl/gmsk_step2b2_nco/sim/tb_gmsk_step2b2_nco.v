`timescale 1ns / 1ps
//
// tb_gmsk_step2b2_nco -- Sub-step B2 SIM gate.
//
// Rewritten 2026-08-24 when the RTL fix (splitting the accumulate/decide
// logic into two pipeline stages to close a real timing violation -- see
// gmsk_step2b2_nco.v's own header) changed this module's sample_valid-to-
// strobe latency from 1 cycle to 2. The ORIGINAL version of this testbench
// used the single-process "check immediately after driving" pattern,
// which only worked because the original DUT was a single register stage
// -- reusing that pattern on a now-2-stage DUT would hit the exact same
// class of bug gmsk_step2d_gardner_ted's own testbench development
// already ran into once (see that testbench's header for the full
// account). Switched to the PROVEN self-synchronizing capture pattern
// instead: a separate process captures (is_midpoint, mu_out) into an
// array every cycle `strobe` pulses, completely independent of drive
// timing, compared against a pre-filtered "real events only" reference
// (gen_test_vectors.py's expected_events_ismid.hex/expected_events_mu.hex)
// -- sidesteps needing to know or hand-count the exact latency at all.
//
module tb_gmsk_step2b2_nco;

    localparam integer STEP_WIDTH  = 32;
    localparam integer MU_WIDTH    = 16;
    localparam integer LOG2_SPS    = 2;
    localparam integer NUM_SAMPLES = 3000;  // 3 phases x 1000 samples (gen_test_vectors.py)
    localparam integer GAP_CYCLES  = 3;
    localparam integer NUM_EVENTS  = 1500;  // upper bound headroom -- actual count read from the generator's own printed total; array sized generously, unused tail entries simply never get compared

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock -- arbitrary, per-clock streaming test

    reg aresetn = 1'b0;

    reg  [STEP_WIDTH-1:0]        step_mem              [0:NUM_SAMPLES-1];
    reg  [STEP_WIDTH-1:0]        adj_mem               [0:NUM_SAMPLES-1];
    reg                          expected_events_ismid [0:NUM_EVENTS-1];
    reg  [MU_WIDTH-1:0]          expected_events_mu    [0:NUM_EVENTS-1];

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
        $readmemb("expected_events_ismid.hex", expected_events_ismid);
        $readmemh("expected_events_mu.hex", expected_events_mu);
    end

    // Capture process -- self-synchronizing on `strobe`, in order,
    // independent of drive timing and of the DUT's exact latency.
    integer cap_idx;
    reg                cap_ismid [0:NUM_EVENTS-1];
    reg [MU_WIDTH-1:0] cap_mu    [0:NUM_EVENTS-1];

    initial begin
        cap_idx = 0;
        forever begin
            @(posedge clk);
            if (strobe && cap_idx < NUM_EVENTS) begin
                cap_ismid[cap_idx] = is_midpoint;
                cap_mu[cap_idx]    = mu_out;
                cap_idx = cap_idx + 1;
            end
        end
    end

    // Driver process.
    integer drive_idx;
    initial begin
        sample_valid = 1'b0;
        step_in      = {STEP_WIDTH{1'b0}};
        adj_in       = {STEP_WIDTH{1'b0}};

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
            repeat (GAP_CYCLES) @(posedge clk);
            #1;
        end

        // Let the pipeline fully drain (2-stage DUT, comfortably covered)
        // before checking.
        repeat (20) @(posedge clk);
        #1;

        check_all;
    end

    task check_all;
        integer i, errors, checked;
        begin
            errors = 0;
            checked = 0;
            for (i = 0; i < NUM_EVENTS; i = i + 1) begin
                if (expected_events_mu[i] === {MU_WIDTH{1'bx}}) begin
                    // reached the end of the (shorter than NUM_EVENTS)
                    // real reference list -- stop comparing here.
                    i = NUM_EVENTS;
                end else begin
                    checked = checked + 1;
                    if (i >= cap_idx) begin
                        errors = errors + 1;
                        if (errors <= 20)
                            $display("FAIL: event %0d never captured (cap_idx=%0d)", i, cap_idx);
                    end else begin
                        if (cap_ismid[i] !== expected_events_ismid[i]) begin
                            errors = errors + 1;
                            if (errors <= 20)
                                $display("FAIL(is_midpoint): event %0d got=%0b expected=%0b",
                                          i, cap_ismid[i], expected_events_ismid[i]);
                        end
                        if (cap_mu[i] !== expected_events_mu[i]) begin
                            errors = errors + 1;
                            if (errors <= 20)
                                $display("FAIL(mu): event %0d got=%0d expected=%0d",
                                          i, cap_mu[i], expected_events_mu[i]);
                        end
                    end
                end
            end

            $display("Checked %0d real events (captured %0d total).", checked, cap_idx);
            if (errors == 0 && checked > 0 && cap_idx == checked)
                $display("TEST PASSED");
            else
                $display("TEST FAILED (%0d errors, checked %0d, captured %0d)",
                          errors, checked, cap_idx);

            $finish;
        end
    endtask

endmodule
