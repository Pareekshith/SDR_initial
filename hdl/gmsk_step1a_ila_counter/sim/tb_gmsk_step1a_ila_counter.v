`timescale 1ns / 1ps
//
// tb_gmsk_step1a_ila_counter — Step 1a SIM gate.
//
// A free-running counter is self-evidently correct, but this project's
// convention is to simulate every block anyway (see gmsk_step1_discriminator's
// tb). Checks: held at 0 throughout reset, increments by exactly 1 every
// clock once released, and clears again on a mid-stream reset re-assertion —
// enough to be confident the synchronous-reset counter behaves exactly as
// intended before it's packaged and wired onto real silicon.
//
module tb_gmsk_step1a_ila_counter;

    localparam integer WIDTH = 16;

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock — arbitrary, timing isn't under test here

    reg                 aresetn;
    wire [WIDTH-1:0]    count;

    integer errors;
    integer i;
    reg [WIDTH-1:0] expected;

    gmsk_step1a_ila_counter #(
        .WIDTH (WIDTH)
    ) dut (
        .aclk    (clk),
        .aresetn (aresetn),
        .count   (count)
    );

    initial begin
        errors  = 0;
        aresetn = 1'b0;

        // Held at 0 throughout reset.
        repeat (5) @(posedge clk);
        #1;
        if (count !== {WIDTH{1'b0}}) begin
            errors = errors + 1;
            $display("FAIL: count not held at 0 during reset (count=%0d)", count);
        end

        @(negedge clk);
        aresetn = 1'b1;

        // Increments by exactly 1 every clock once out of reset. First
        // posedge after deassertion takes count from 0 to 1.
        expected = 1;
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
            #1;
            if (count !== expected) begin
                errors = errors + 1;
                $display("FAIL: cycle %0d expected count=%0d got %0d", i, expected, count);
            end
            expected = expected + 1'b1;
        end

        // Mid-stream reset re-assertion must snap it straight back to 0.
        @(negedge clk);
        aresetn = 1'b0;
        @(posedge clk);
        #1;
        if (count !== {WIDTH{1'b0}}) begin
            errors = errors + 1;
            $display("FAIL: count did not clear on re-asserted reset (count=%0d)", count);
        end

        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors)", errors);

        $finish;
    end

endmodule
