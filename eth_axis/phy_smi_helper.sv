module phy_smi_helper(
    input logic clk,
    input  logic rst,
    input  logic mdclk,
    output logic phyrst,
    output logic phy_rdy,
    inout  logic mdio
);
assign phyrst = rphyrst;
logic rphyrst;

logic SMI_trg;
logic SMI_ack;
logic SMI_ready;
logic SMI_rw;
logic [4:0] SMI_adr;
logic [15:0] SMI_data;
logic [15:0] SMI_wdata;

byte SMI_status;

// IEEE 802.3 Clause 22 standard registers.
localparam logic [4:0] PHY_REG_BMCR = 5'd0;
localparam logic [4:0] PHY_REG_BMSR = 5'd1;

// BMCR[13] = 1: 100 Mb/s
// BMCR[12] = 0: auto-negotiation disabled
// BMCR[8]  = 1: full duplex
localparam logic [15:0] BMCR_FORCE_100M_FULL_DUPLEX = 16'h2100;
localparam logic [15:0] BMCR_MODE_MASK              = 16'h3100;

always_ff@(posedge mdclk or negedge rst)begin
    if(rst == 1'b0)begin
        phy_rdy <= 1'b0;
        rphyrst <= 1'b0;
        SMI_trg <= 1'b0;
        SMI_adr <= PHY_REG_BMCR;
        SMI_wdata <= BMCR_FORCE_100M_FULL_DUPLEX;
        SMI_rw <= 1'b0;
        SMI_status <= 0;
    end else begin
        rphyrst <= 1'b1;
        if(phy_rdy == 1'b0)begin
            SMI_trg <= 1'b1;
            if(SMI_ack && SMI_ready)begin
                case(SMI_status)
                    0:begin
                        // The forced-mode BMCR write has completed; read it
                        // back before reporting that PHY setup is complete.
                        SMI_adr <= PHY_REG_BMCR;
                        SMI_rw <= 1'b1;
                        SMI_status <= 1;
                    end
                    1:begin
                        if((SMI_data & BMCR_MODE_MASK) ==
                           BMCR_FORCE_100M_FULL_DUPLEX)begin
                            // Forced mode is active. Poll the standard BMSR
                            // link-status bit until the link comes up.
                            SMI_adr <= PHY_REG_BMSR;
                            SMI_rw <= 1'b1;
                            SMI_status <= 2;
                        end else begin
                            // Retry the BMCR write if the requested mode did
                            // not read back correctly.
                            SMI_adr <= PHY_REG_BMCR;
                            SMI_wdata <= BMCR_FORCE_100M_FULL_DUPLEX;
                            SMI_rw <= 1'b0;
                            SMI_status <= 0;
                        end
                    end
                    2:begin
                        if(SMI_data[2])begin
                            phy_rdy <= 1'b1;
                            SMI_trg <= 1'b0;
                        end
                    end
                endcase
            end
        end
    end
end
//1 = read, 0 = write
SMI_ct ct(
    .clk(mdclk), .rst(rphyrst), .rw(SMI_rw), .trg(SMI_trg), .ready(SMI_ready), .ack(SMI_ack),
    .phy_adr(5'd1), .reg_adr(SMI_adr),
    .data(SMI_wdata),
    .smi_data(SMI_data),
    .mdio(mdio)
);

endmodule
