`timescale 1ns / 1ps
//
// tb_gmsk_interp_tag_delay -- SIM gate for the interpolator-latency
// tag-delay glue module. Drives a pseudo-random (strobe_in, is_midpoint_in)
// sequence every single cycle (this module has no valid/gap concept --
// it's an unconditional shift register, matching the interpolator's own
// pipeline behavior it's designed to shadow) and checks that
// (strobe_out, is_midpoint_out) at cycle i+DELAY_CYCLES exactly equals
// (strobe_in, is_midpoint_in) at cycle i, for every i.
//
// Single drive+check process, `#1` settle delay after every
// `@(posedge clk)` -- same race-avoidance discipline established in
// gmsk_step2b_nco's own testbench (this module is a single always block,
// same simple category as that one, not a multi-stage pipeline).
//
// Indexing note (hand-traced with a concrete DELAY_CYCLES=2 example
// before trusting it): when input is driven and output is checked within
// the SAME loop iteration/same clock edge, the value asserted at
// iteration i first appears at the output at iteration i+(DELAY_CYCLES-1),
// not i+DELAY_CYCLES -- because that same edge both shifts the new value
// into the first stage AND is the first of the DELAY_CYCLES edges needed
// for it to reach the last stage. This is a property of same-iteration
// checking, not a shortfall in the RTL's actual latency (a real system
// asserting strobe_in for one cycle sees strobe_out one cycle DELAY_CYCLES
// edges later, exactly as intended) -- caught by hand-tracing a small
// concrete example before trusting the first version of this check, which
// got the offset wrong.
//
module tb_gmsk_interp_tag_delay;

    localparam integer DELAY_CYCLES = 20;  // matches gmsk_step2a_interpolator's current pipeline depth (19->20 as of 2026-08-24, see gmsk_interp_tag_delay.v's header)
    localparam integer NUM_CYCLES   = 500;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg aresetn = 1'b0;

    reg strobe_hist   [0:NUM_CYCLES-1];
    reg ismid_hist    [0:NUM_CYCLES-1];

    reg strobe_in;
    reg is_midpoint_in;
    wire strobe_out;
    wire is_midpoint_out;

    gmsk_interp_tag_delay #(
        .DELAY_CYCLES (DELAY_CYCLES)
    ) dut (
        .aclk            (clk),
        .aresetn         (aresetn),
        .strobe_in       (strobe_in),
        .is_midpoint_in  (is_midpoint_in),
        .strobe_out      (strobe_out),
        .is_midpoint_out (is_midpoint_out)
    );

    // Pseudo-random but deterministic stimulus (LFSR-free, just a simple
    // arithmetic pattern) -- exercises isolated pulses, back-to-back
    // pulses, and long gaps, all of which this module must shift through
    // identically since it has no gating logic at all.
    integer i;
    integer strobe_errors, ismid_errors;
    reg [31:0] lfsr;

    initial begin
        strobe_in      = 1'b0;
        is_midpoint_in = 1'b0;
        strobe_errors  = 0;
        ismid_errors   = 0;
        lfsr           = 32'hACE1_2345;

        repeat (5) @(posedge clk);
        #1;
        aresetn = 1'b1;
        @(posedge clk);
        #1;

        for (i = 0; i < NUM_CYCLES; i = i + 1) begin
            // simple deterministic PRNG, just needs to be reproducible and varied
            lfsr = lfsr ^ (lfsr << 13);
            lfsr = lfsr ^ (lfsr >> 17);
            lfsr = lfsr ^ (lfsr << 5);

            strobe_in      = lfsr[0];
            is_midpoint_in = lfsr[1];
            strobe_hist[i] = strobe_in;
            ismid_hist[i]  = is_midpoint_in;

            @(posedge clk);
            #1;

            // Check output at THIS cycle against input from (DELAY_CYCLES-1)
            // iterations ago -- see header note on why it's DELAY_CYCLES-1,
            // not DELAY_CYCLES, for a same-iteration drive+check pattern.
            if (i >= DELAY_CYCLES - 1) begin
                if (strobe_out !== strobe_hist[i - (DELAY_CYCLES - 1)]) begin
                    strobe_errors = strobe_errors + 1;
                    if (strobe_errors <= 10)
                        $display("FAIL(strobe): cycle %0d got=%0b expected=%0b",
                                  i, strobe_out, strobe_hist[i - (DELAY_CYCLES - 1)]);
                end
                if (is_midpoint_out !== ismid_hist[i - (DELAY_CYCLES - 1)]) begin
                    ismid_errors = ismid_errors + 1;
                    if (ismid_errors <= 10)
                        $display("FAIL(is_midpoint): cycle %0d got=%0b expected=%0b",
                                  i, is_midpoint_out, ismid_hist[i - (DELAY_CYCLES - 1)]);
                end
            end else begin
                // before enough history exists, output must still be held
                // at its post-reset value (0) -- confirms the shift
                // register doesn't leak garbage/X before it's genuinely
                // been filled DELAY_CYCLES deep.
                if (strobe_out !== 1'b0) begin
                    strobe_errors = strobe_errors + 1;
                    $display("FAIL(strobe, pre-fill): cycle %0d got=%0b expected=0", i, strobe_out);
                end
                if (is_midpoint_out !== 1'b0) begin
                    ismid_errors = ismid_errors + 1;
                    $display("FAIL(is_midpoint, pre-fill): cycle %0d got=%0b expected=0", i, is_midpoint_out);
                end
            end
        end

        $display("Checked %0d cycles (DELAY_CYCLES=%0d).", NUM_CYCLES, DELAY_CYCLES);
        if (strobe_errors == 0 && ismid_errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d strobe errors, %0d is_midpoint errors)",
                      strobe_errors, ismid_errors);

        $finish;
    end

endmodule
