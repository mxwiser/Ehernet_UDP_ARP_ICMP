module SMI_ct(
    input clk, rst, rw, trg,
    input [4:0] phy_adr, reg_adr,
    input [15:0] data,
    output logic ready, ack,
    output logic [15:0] smi_data,
    inout logic mdio
);

    byte ct;
    reg rmdio;

    reg [31:0] tx_data;
    reg [15:0] rx_data;

    assign mdio = rmdio?1'bZ:1'b0;

    always_comb begin
        smi_data <= rx_data;
    end

    always_ff@(posedge clk or negedge rst)begin
        if(rst == 1'b0)begin
            ct <= 0;
            ready <= 1'b0;
            ack <= 1'b0;

            rmdio <= 1'b1;
        end else begin
            ct <= ct + 8'd1;
            if(ct == 0 && trg == 1'b0)ct<=0;
            if(ct == 0 && trg == 1'b1)begin
                ready <= 1'b0;
                ack <= 1'b0;
            end

            if(ct == 64)begin
                ready <= 1'b1;
            end

            if(trg == 1'b1 && ready == 1'b1)begin
                ready <= 1'b0;
            end

            rmdio <= 1'b1;

            if(ct == 4 && trg == 1'b1)begin
                tx_data <= {2'b01, rw?2'b10:2'b01, phy_adr, reg_adr, rw?2'b11:2'b10, rw?16'hFFFF:data};
            end

            if(ct>31)begin
                rmdio <= tx_data[31];
                tx_data <= {tx_data[30:0], 1'b1};
            end

            if(ct == 48 && mdio == 1'b0)begin
                ack <= 1'b1;
            end
            
            if(ct>48)begin
                rx_data <= {rx_data[14:0], mdio};
            end
        end
    end
endmodule
