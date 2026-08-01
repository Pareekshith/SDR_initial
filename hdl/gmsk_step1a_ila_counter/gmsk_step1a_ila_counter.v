`timescale 1ns / 1ps
//
// gmsk_step1a_ila_counter — Step 1a: ILA proof-of-life (see
// project_fpga_gmsk_plan memory, "START HERE NEXT SESSION — Step 1a" for the
// full rationale).
//
// Step 1's hardware bring-up left one variable untested: whether the
// ILA/dbg_hub debug-capture chain even works on the rx_clk (axi_ad9361_l_clk)
// domain at all — across a whole debugging session we never once got a
// confirmed-successful ILA capture of anything, real AD9361 data or
// otherwise. This module exists purely to answer that, in isolation from
// every AD9361/DMA/AXI-Stream question: a free-running counter with no
// upstream dependency of any kind. If this doesn't show up cleanly on the
// ILA, the problem was never AD9361/DMA — it was the observation tool.
//
// Deliberately NOT wrapped in AXI4-Stream (unlike gmsk_step1_discriminator).
// There is nothing here for tvalid/tready to arbitrate — adding that
// interface back would just reintroduce components this test is trying to
// rule out. aclk/aresetn only, so it drops onto the exact same suspect
// clock/reset nets (axi_ad9361_l_clk + the util_vector_logic_0 NOT-gate off
// axi_ad9361_rst) with nothing else in the way.
//
module gmsk_step1a_ila_counter #
(
    parameter integer WIDTH = 16                       // matches system_ila_0's existing probe0 width,
                                                        // so the ILA IP itself needs no reconfiguration
)
(
    input  wire             aclk,
    input  wire             aresetn,
    output reg  [WIDTH-1:0] count
);

    always @(posedge aclk) begin
        if (!aresetn)
            count <= {WIDTH{1'b0}};
        else
            count <= count + 1'b1;
    end

endmodule
