`include "axis.svh"

module rmii2axis(
    input   wire            rstn,
    input	wire			rmii_clk,						
	input	wire			rmii_crs_dv,
	input	wire	[1:0]	rmii_rxdata,
	output	reg			    rmii_txen,
	output	wire	[1:0]	rmii_txdata,
	output	wire			rmii_rst,
    axis.master             m_rmii_rx_axis_net,
    axis.slave              s_rmii_tx_axis_net
);

localparam		IDLE					= 18'h0_0001,
                PREAMBLE				= 18'h0_0002,
                SFD				        = 18'h0_0003,
                DATA				    = 18'h0_0004,					
                CRS_CHECK			    = 18'h0_0005;				

wire      rx_dv;
reg [7:0] state;
assign m_rmii_rx_axis_net.tlast = rx_dv;

//rx
always_ff @(posedge rmii_clk or negedge rstn) begin
    if(rstn==0)begin
        m_rmii_rx_axis_net.tdata  =  'd0;
        m_rmii_rx_axis_net.tuser  =  'd0;
        m_rmii_rx_axis_net.tvalid = 'd0;
        rx_dv = 'd0;
        state = 'd0;
    end else begin

    end
end


endmodule