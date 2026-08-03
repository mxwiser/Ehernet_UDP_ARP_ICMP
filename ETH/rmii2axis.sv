`include "axis.svh"

module rmii2axis(
    input   wire            rstn,
    input	wire			rmii_clk,						
	input	wire			rmii_crs_dv,
	input	wire	[1:0]	rmii_rxdata,
	output	reg			    rmii_txen,
	output	wire	[1:0]	rmii_txdata,
	output	wire			rmii_rst,
    axis.master             m_rmii_rx_axis_net, //tlast :rx_dv
    axis.slave              s_rmii_tx_axis_net  //tlast :tx_en
);

localparam		IDLE					= 18'h0_0001,
                PREAMBLE				= 18'h0_0002,
                SFD				        = 18'h0_0003,
                DATA				    = 18'h0_0004,					
                CRS_CHECK			    = 18'h0_0005;				

logic       rx_dv;
logic [7:0] rx_state;
logic [7:0] rx_tick;
logic [1:0] rxd;
logic nibble_shift;
assign m_rmii_rx_axis_net.tlast = rx_dv;
assign rxd = rmii_rxdata;
always_comb begin
    rx_dv = rmii_crs_dv || nibble_shift;
end


//rx
always_ff @(posedge rmii_clk or negedge rstn) begin
    if(!rstn)begin
        m_rmii_rx_axis_net.tdata  <=  'd0;
        m_rmii_rx_axis_net.tuser  <=  'd0;
        m_rmii_rx_axis_net.tvalid <= 'd0;
        rx_dv    <= 'd0;
        rx_state <= 'd0;
        rx_tick  <= 'd0;
        nibble_shift <= 'd0;
    end else begin


    
    case (rx_state)
        IDLE:begin
            if(rx_dv&&(rxd==2'b01))
              rx_state = PREAMBLE;
        end 

        PREAMBLE: begin

        end

    
    endcase
        
    end
end



//tx
always_ff @(posedge rmii_clk or negedge rstn) begin
    if(!rstn)begin
        s_rmii_tx_axis_net.tready  =  'd0;
    end else begin

    end
end

endmodule