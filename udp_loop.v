// author:		Benjamin SMith
// create time:	2023/03/22 11:07
// edit time:	2023/03/22 16:21
// platform:	Cyclone ep4ce10f17i7, 野火 board
// module:		udp_loop
// function:	UDP loop, transform information back to server
// version:		1.0
// history:	

module udp_loop (
	input	wire						sys_rst_n,
	
	input	wire						rmii_clk,
	input	wire						rmii_crsdv,
	input	wire	[1:0]				rmii_rxdata,
	output	wire						rmii_txen,
	output	wire	[1:0]				rmii_txdata,
	output	wire						rmii_rst
);


eth_mac_mii u0_eth_mac_mii(
	
);

udp_complete u1_udp_complete(
	.clk(rmii_clk),
	.rst(sys_rst_n)
);

endmodule