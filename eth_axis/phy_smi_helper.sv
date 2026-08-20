module phy_smi_helper(
    input logic clk,
    input  logic rst,
    input  logic mdclk,
    output logic phyrst,
    output logic phy_rdy,
    inout  wire mdio
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




always_ff@(posedge mdclk or negedge rst)begin
    if(rst == 1'b0)begin
        phy_rdy <= 1'b0;
        rphyrst <= 1'b0;
        SMI_trg <= 1'b0;
        SMI_adr <= 5'd1;
        SMI_rw <= 1'b1;
        SMI_status <= 0;
    end else begin
        rphyrst <= 1'b1;
        if(phy_rdy == 1'b0)begin
            SMI_trg <= 1'b1;
            if(SMI_ack && SMI_ready)begin
                case(SMI_status)
                    0:begin
                        SMI_adr <= 5'd1;
                        SMI_rw <= 1'b1;
                        SMI_status <= 1;
                    end
                    1:begin
                        SMI_status <= 2;
                    end
                    2:begin
                        SMI_status <= 3;
                    end
                    3:begin
                        SMI_status <= 4;
                    end
                    4:begin
                        SMI_status <= 5;
                    end
                    5:begin
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
