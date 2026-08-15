`timescale 1ns / 1ps
//
// tb_gmsk_step2b_nco -- Sub-step B SIM gate.
//
// Drives the (step_in, adj_in) sequence from gen_test_vectors.py through the
// DUT with gapped (non-back-to-back) sample_valid pulses -- same lesson
// gmsk_step1_discriminator's and gmsk_step2a_interpolator's testbenches
// learned the hard way (see their own GAP_CYCLES comments): a design that
// only looks right under back-to-back valid pulses can hide a real bug that
// only shows up with idle gaps between samples, which real hardware always
// has.
//
// Single drive+check process, not a separate driver/checker pair -- an
// earlier version of this testbench used two processes (a driver and a
// forever-loop checker gated by a hand-rolled "delayed valid" signal) and
// hit a real same-time-step multiple-process read/NBA-ordering confusion:
// reading a DUT output right after this process's own `@(posedge clk)`
// resumes is well-defined ONLY once BOTH the Active region (blocking
// assignments/reads) AND the NBA region (this module's own `<=` register
// commits, and the DUT's) have settled for that time step -- confirmed
// directly with a `$strobe`-based debug probe (which the Verilog LRM
// specifically guarantees samples only after that settling, unlike
// `$display`). The standard, unambiguous fix, used here: a small `#1` delay
// after `@(posedge clk)`, before reading ANY DUT signal for comparison.
// Doing drive and check in one sequential process (rather than a second
// process racing against the first) sidesteps the whole class of bug.
//
// A second, related race was found and fixed in the same debugging pass:
// `repeat(GAP_CYCLES) @(posedge clk);` returns control to this process
// EXACTLY at a clock edge (zero simulated time after it) -- the very next
// statement (blocking-assigning `sample_valid` for the following sample)
// then executes in that SAME time step, racing the DUT's own always block
// which is ALSO triggered by that identical edge. Depending on scheduler
// ordering this could let the DUT see the new sample_valid a full cycle
// early -- confirmed directly with a `$strobe`-based trace showing
// sample_valid held high for two consecutive edges instead of one. Fixed
// by always landing a nonzero delay (`#1`) after ANY `@(posedge clk)`
// before touching an input again, never exactly on the edge itself.
//
module tb_gmsk_step2b_nco;

    localparam integer STEP_WIDTH  = 32;
    localparam integer MU_WIDTH    = 16;
    localparam integer LOG2_SPS    = 2;
    localparam integer NUM_SAMPLES = 3000;  // 3 phases x 1000 samples (gen_test_vectors.py)
    localparam integer GAP_CYCLES  = 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock -- arbitrary, per-clock streaming test

    reg aresetn = 1'b0;

    reg  [STEP_WIDTH-1:0]        step_mem            [0:NUM_SAMPLES-1];
    reg  [STEP_WIDTH-1:0]        adj_mem             [0:NUM_SAMPLES-1];  // stored as raw bits, reinterpreted signed on drive
    reg                          expected_strobe_mem [0:NUM_SAMPLES-1];
    reg  [MU_WIDTH-1:0]          expected_mu_mem     [0:NUM_SAMPLES-1];

    reg                          sample_valid;
    reg  [STEP_WIDTH-1:0]        step_in;
    reg  signed [STEP_WIDTH-1:0] adj_in;

    wire                         strobe;
    wire [MU_WIDTH-1:0]          mu_out;

    gmsk_step2b_nco #(
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
        .mu_out       (mu_out)
    );

    initial begin
        $readmemh("step.hex", step_mem);
        $readmemh("adj.hex", adj_mem);
        $readmemb("expected_strobe.hex", expected_strobe_mem);  // single-digit '0'/'1' lines -- readmemb, not readmemh
        $readmemh("expected_mu.hex", expected_mu_mem);
    end

    integer drive_idx;
    integer strobe_errors, mu_errors, strobes_seen;

    initial begin
        sample_valid  = 1'b0;
        step_in       = {STEP_WIDTH{1'b0}};
        adj_in        = {STEP_WIDTH{1'b0}};
        strobe_errors = 0;
        mu_errors     = 0;
        strobes_seen  = 0;

        repeat (5) @(posedge clk);
        #1;
        aresetn = 1'b1;
        @(posedge clk);
        #1;  // same off-edge landing as the loop's own gap-wait -- see header race note

        for (drive_idx = 0; drive_idx < NUM_SAMPLES; drive_idx = drive_idx + 1) begin
            step_in      = step_mem[drive_idx];
            adj_in       = adj_mem[drive_idx];
            sample_valid = 1'b1;
            @(posedge clk);
            #1;  // let this edge's register commits settle before reading -- see header
            sample_valid = 1'b0;

            if (strobe !== expected_strobe_mem[drive_idx]) begin
                strobe_errors = strobe_errors + 1;
                if (strobe_errors <= 20)
                    $display("FAIL(strobe): sample %0d got=%0b expected=%0b",
                              drive_idx, strobe, expected_strobe_mem[drive_idx]);
            end
            if (mu_out !== expected_mu_mem[drive_idx]) begin
                mu_errors = mu_errors + 1;
                if (mu_errors <= 20)
                    $display("FAIL(mu): sample %0d got=%0d expected=%0d",
                              drive_idx, mu_out, expected_mu_mem[drive_idx]);
            end
            if (strobe === 1'b1) strobes_seen = strobes_seen + 1;

            repeat (GAP_CYCLES) @(posedge clk);
            #1;  // land safely off-edge before the next iteration's blocking assignments -- see header race note
        end

        $display("Checked %0d samples, %0d strobes observed.", NUM_SAMPLES, strobes_seen);
        if (strobe_errors == 0 && mu_errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d strobe errors, %0d mu errors)",
                      strobe_errors, mu_errors);

        $finish;
    end

endmodule
