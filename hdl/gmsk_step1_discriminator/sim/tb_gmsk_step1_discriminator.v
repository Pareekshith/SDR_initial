`timescale 1ns / 1ps
//
// tb_gmsk_step1_discriminator — Step 1 SIM gate.
//
// Feeds the synthetic two-tone (MARK/SPACE) continuous-phase test vectors
// from gen_test_vectors.awk through the DUT and self-checks the pass
// condition from docs/step1_discriminator.html: the discriminator output
// must toggle cleanly between two distinct, well-separated levels, one per
// transmitted bit, with no framing logic involved.
//
// Must match gen_test_vectors.awk's constants exactly.
//
// GAP_CYCLES (2026-08-01): real AD9361 data arrives as sparse strobes, not
// back-to-back every clock -- this testbench originally drove s_axis_tvalid
// high on every single cycle, which hid a real hardware bug in the DUT's
// delay-line (i_d2 ended up duplicating i_d1 instead of holding the true
// previous sample, whenever there were idle cycles between valid pulses --
// see the DUT's own comment for the full explanation). Driving with a gap
// between samples exercises that same code path in sim, so this class of
// bug gets caught here next time instead of only on real hardware via ILA.
// The capture loop below is now self-synchronizing to m_axis_tvalid pulses
// rather than indexing off a fixed cycle-latency constant, so it doesn't
// care how many gap cycles are used or what the DUT's exact pipeline depth
// is -- it just needs each input sample to eventually produce exactly one
// output pulse, in order.
//
module tb_gmsk_step1_discriminator;

    localparam integer IQ_WIDTH        = 16;
    localparam integer OUT_WIDTH       = 16;   // must match DUT's OUT_WIDTH (multiple of 8, AXI4-Stream rule)
    localparam integer SAMPLES_PER_BIT = 480;
    localparam integer NUM_BITS        = 10;
    localparam integer NUM_SAMPLES     = SAMPLES_PER_BIT * NUM_BITS;
    localparam integer GAP_CYCLES      = 3;    // idle cycles between valid pulses -- real hardware has many more,
                                                // this just needs to be >0 to exercise the sparse-valid code path
    localparam integer SETTLE_SAMPLES  = 100;  // skip this many samples per bit before averaging

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz sim clock — arbitrary, this is a per-clock streaming test

    reg aresetn = 1'b0;

    reg  [2*IQ_WIDTH-1:0] mem [0:NUM_SAMPLES-1];
    reg  signed [OUT_WIDTH-1:0] captured [0:NUM_SAMPLES-1];

    reg                    s_axis_tvalid;
    wire                   s_axis_tready;
    reg  [2*IQ_WIDTH-1:0]  s_axis_tdata;
    wire                   m_axis_tvalid;
    wire signed [OUT_WIDTH-1:0] m_axis_tdata;

    integer idx;
    integer errors;

    gmsk_step1_discriminator #(
        .IQ_WIDTH  (IQ_WIDTH),
        .OUT_WIDTH (OUT_WIDTH)
    ) dut (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (1'b1),
        .m_axis_tdata  (m_axis_tdata)
    );

    initial begin
        $readmemh("test_vectors.hex", mem);
    end

    // Drive one sample every (1 + GAP_CYCLES) clocks once out of reset --
    // a single-cycle tvalid pulse per sample, then idle, matching real
    // AD9361 data's sparse strobe pattern instead of back-to-back valid.
    integer g;
    initial begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = {2*IQ_WIDTH{1'b0}};
        idx           = 0;
        repeat (5) @(posedge clk);
        aresetn = 1'b1;
        @(posedge clk);
        for (idx = 0; idx < NUM_SAMPLES; idx = idx + 1) begin
            s_axis_tdata  = mem[idx];
            s_axis_tvalid = 1'b1;
            @(posedge clk);
            s_axis_tvalid = 1'b0;
            for (g = 0; g < GAP_CYCLES; g = g + 1)
                @(posedge clk);
        end
    end

    // Capture: self-synchronizing to m_axis_tvalid pulses rather than a
    // fixed cycle-latency offset, so it doesn't matter how many gap cycles
    // separate input samples or exactly how deep the DUT's pipeline is --
    // each valid output pulse is simply the next captured sample, in order.
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

    // Analysis: run after all samples + pipeline drain have been captured.
    real mark_avg, space_avg, mark_sum, space_sum;
    integer mark_cnt, space_cnt;
    integer b, s, n;
    real seg_sum, seg_avg;
    integer seg_cnt;
    real dev;

    initial begin
        errors = 0;
        // Wait for every input sample to have produced its captured output.
        wait (cap_idx >= NUM_SAMPLES);
        repeat (10) @(posedge clk);

        mark_sum = 0.0; mark_cnt = 0;
        space_sum = 0.0; space_cnt = 0;

        for (b = 0; b < NUM_BITS; b = b + 1) begin
            seg_sum = 0.0;
            seg_cnt = 0;
            for (s = SETTLE_SAMPLES; s < SAMPLES_PER_BIT; s = s + 1) begin
                n = b*SAMPLES_PER_BIT + s;
                seg_sum = seg_sum + captured[n];
                seg_cnt = seg_cnt + 1;
            end
            seg_avg = seg_sum / seg_cnt;

            // Per-sample consistency within this segment: should sit close
            // to the segment's own average — a noisy/wrong DUT would show
            // wide scatter here instead of a clean level.
            for (s = SETTLE_SAMPLES; s < SAMPLES_PER_BIT; s = s + 1) begin
                n = b*SAMPLES_PER_BIT + s;
                dev = captured[n] - seg_avg;
                if (dev < 0) dev = -dev;
                if (dev > 0.15 * (seg_avg < 0 ? -seg_avg : seg_avg) + 50) begin
                    errors = errors + 1;
                    $display("FAIL: bit %0d sample %0d = %0d deviates from segment avg %.1f",
                              b, n, captured[n], seg_avg);
                end
            end

            if (b % 2 == 0) begin
                mark_sum = mark_sum + seg_avg; mark_cnt = mark_cnt + 1;
                $display("bit %0d (MARK)  segment avg = %.1f", b, seg_avg);
            end else begin
                space_sum = space_sum + seg_avg; space_cnt = space_cnt + 1;
                $display("bit %0d (SPACE) segment avg = %.1f", b, seg_avg);
            end
        end

        mark_avg  = mark_sum / mark_cnt;
        space_avg = space_sum / space_cnt;
        $display("MARK avg = %.1f, SPACE avg = %.1f, ratio = %.2f",
                  mark_avg, space_avg, mark_avg / space_avg);

        if (!(mark_avg > 2.0 * space_avg)) begin
            errors = errors + 1;
            $display("FAIL: MARK/SPACE levels not clearly separated (need MARK > 2x SPACE)");
        end
        if (!(space_avg > 0.0)) begin
            errors = errors + 1;
            $display("FAIL: SPACE level not positive as expected for a positive baseband offset");
        end

        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors)", errors);

        $finish;
    end

endmodule
