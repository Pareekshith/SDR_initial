`timescale 1ns / 1ps
//
// gmsk_step0_regs — Step 0 infrastructure proof (see project_fpga_gmsk_plan memory)
//
// A minimal, standards-correct AXI4-Lite slave. No DSP. Its only job is to prove
// the Verilog -> IP packaging -> block design -> bitstream -> JTAG -> Linux
// readback loop works, fully decoupled from any question about discriminator/
// timing-recovery correctness.
//
// Register map (word-aligned byte offsets, 32-bit accesses):
//   0x0  ID       read-only   32'h474D_534B  ("GMSK" in ASCII hex)
//   0x4  SCRATCH  read/write  round-trip proof: write anything, read it back
//   0x8  COUNTER  read-only   free-running, incremented every S_AXI_ACLK
//   0xC  (reserved, reads 0)
//
// scratch_out (2026-08-02): SCRATCH's value, exposed as a plain output port
// so other IP in the block design can be driven live from software (devmem
// a write to 0x40000004, no rebuild) instead of a hardwired constant -- e.g.
// gmsk_step2a_interpolator's mu_in. Purely additive: SCRATCH's own AXI-Lite
// read/write behavior is unchanged, this just mirrors the same register out.
//
module gmsk_step0_regs #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4       // 4 x 32-bit registers
)
(
    input  wire                              S_AXI_ACLK,
    input  wire                              S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire [2:0]                        S_AXI_AWPROT,
    input  wire                              S_AXI_AWVALID,
    output wire                              S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                              S_AXI_WVALID,
    output wire                              S_AXI_WREADY,

    output wire [1:0]                        S_AXI_BRESP,
    output wire                              S_AXI_BVALID,
    input  wire                              S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire [2:0]                        S_AXI_ARPROT,
    input  wire                              S_AXI_ARVALID,
    output wire                              S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    output wire [1:0]                        S_AXI_RRESP,
    output wire                              S_AXI_RVALID,
    input  wire                              S_AXI_RREADY,

    output wire [31:0]                       scratch_out
);

    localparam integer ADDR_LSB          = 2;   // 32-bit-aligned registers
    localparam integer OPT_MEM_ADDR_BITS = 1;   // 2 index bits -> 4 registers
    localparam [31:0]  ID_MAGIC          = 32'h474D_534B;

    // -----------------------------------------------------------------
    // Write address / write data channels (AXI4-Lite allows AW and W to
    // arrive on different cycles; only fire the register write once both
    // have been accepted).
    // -----------------------------------------------------------------
    reg                          axi_awready;
    reg                          axi_wready;
    reg                          axi_bvalid;
    reg [1:0]                    axi_bresp;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_awready <= 1'b0;
        else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID)
            axi_awready <= 1'b1;
        else
            axi_awready <= 1'b0;
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_awaddr <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID)
            axi_awaddr <= S_AXI_AWADDR;
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    wire slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    reg [31:0] scratch_reg;
    integer    byte_index;

    assign scratch_out = scratch_reg;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            scratch_reg <= 32'h0;
        end else if (slv_reg_wren &&
                     axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 2'h1) begin
            for (byte_index = 0; byte_index <= 3; byte_index = byte_index + 1)
                if (S_AXI_WSTRB[byte_index])
                    scratch_reg[byte_index*8 +: 8] <= S_AXI_WDATA[byte_index*8 +: 8];
            // Writes to ID (0x0), COUNTER (0x8) or reserved (0xC) are accepted
            // by the bus (BRESP=OKAY) but have no effect — matches how a
            // read-only register should behave under a write.
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else if (axi_awready && S_AXI_AWVALID && ~axi_bvalid &&
                     axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp  <= 2'b00;               // OKAY
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;

    // -----------------------------------------------------------------
    // Read address / read data channels
    // -----------------------------------------------------------------
    reg                          axi_arready;
    reg                          axi_rvalid;
    reg [1:0]                    axi_rresp;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg [31:0]                   axi_rdata;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else if (~axi_arready && S_AXI_ARVALID) begin
            axi_arready <= 1'b1;
            axi_araddr  <= S_AXI_ARADDR;
        end else begin
            axi_arready <= 1'b0;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp  <= 2'b00;               // OKAY
        end else if (S_AXI_RREADY && axi_rvalid) begin
            axi_rvalid <= 1'b0;
        end
    end

    // Free-running counter — the one piece of this module that's actually
    // "running" logic rather than just storage, so a correct readback proves
    // the fabric clock genuinely reaches this IP.
    reg [31:0] counter_reg;
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            counter_reg <= 32'h0;
        else
            counter_reg <= counter_reg + 1'b1;
    end

    always @(*) begin
        case (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB])
            2'h0:    axi_rdata = ID_MAGIC;
            2'h1:    axi_rdata = scratch_reg;
            2'h2:    axi_rdata = counter_reg;
            default: axi_rdata = 32'h0;
        endcase
    end

    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

endmodule
