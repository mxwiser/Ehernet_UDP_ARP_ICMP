`include "axis.svh"

// author:		Benjamin SMith
// create time:	2023/03/17 17:24
// edit time:	2026/08/05
// platform:	Cyclone ep4ce10f17i7, 野火 board
// module:		udp_axis_rx
// function:	ARP request and response + UDP received data, IPv4 only
//				merge of eth_arp_gmii.v and udp_gmii_rx.v, AXIS version
// version:		2.0

module udp_axis_rx (
	input	wire							sys_clk,
	input	wire							sys_rst_n,
	
	axis.slave								s_axis_rx,				// PHY RX stream from rmii_axis, tlast is frame-level
	axis.master								m_axis_arp,				// ARP reply TX stream to rmii_axis
	output	reg								arp_working,			// ARP reply is being sent, for TX arbitration
	
	output	reg		[31:0]					test_count,
	
	output	reg								udp_rxstart,
	output	reg								udp_rxend,
	output	reg								udp_rxdv,
	output	reg		[7:0]					udp_rxdata,
	output	reg		[15:0]					udp_rxamount,			// total amount of data, including all pieces
	output	reg		[15:0]					udp_rxnum,				// the order of the received data in this package
	
	output	reg		[47:0]					pc_mac_addr,
	output	reg		[31:0]					pc_ip_addr,
	output	reg		[15:0]					pc_port,
	output	reg		[15:0]					board_port
);

	parameter		BOARD_MAC_ADDR			= 48'h00_11_22_33_44_55;
	parameter		BOARD_IP_ADDR			= 32'hA9_FE_01_17;				// 169.254.1.23

// -------------------------------- axis <-> gmii bridge ------------------------------------------
// RX: s_mac_tvalid / s_mac_tdata come from s_axis_rx, tready is ignored (rmii_axis never backpressures RX)
	wire									s_mac_tvalid;
	wire		[7:0]						s_mac_tdata	;
	assign		s_mac_tvalid			=	s_axis_rx.tvalid; 
	assign		s_mac_tdata			=	s_axis_rx.tdata;
	assign		s_axis_rx.tready	=	1'b1;

// TX (ARP reply only): gmii_txen / gmii_txbusy mapped to AXIS handshake.
// gmii_txen && !gmii_txbusy  ==  tvalid && tready, so the original FSM body is unchanged
	wire									gmii_txen;
	wire									gmii_txbusy;
	reg			[7:0]						gmii_txdata;
	assign		gmii_txen			=	( tx_state != IDLE );
	assign		gmii_txbusy			=	!( gmii_txen && m_axis_arp.tready );
	assign		m_axis_arp.tvalid	=	gmii_txen;
	assign		m_axis_arp.tlast	=	gmii_txen;					// frame-level: high in frame, falling edge = frame end
	assign		m_axis_arp.tuser	=	1'b0;
	assign		m_axis_arp.tdata	=	gmii_txdata;

	reg			[47:0]						arp_pc_mac;					// PC MAC learned by ARP (not exported)
	reg			[31:0]						arp_pc_ip;					// PC IP learned by ARP (not exported)
	wire									arp_pc_refresh;				// learned pulse (not exported)

// ================================ ARP part (from eth_arp_gmii.v) ================================
	localparam		IDLE					= 13'h0001,
					RX_SFD					= 13'h0002,						// (0xD5)
					TX_PACKAGE_HEAD			= 13'h0002,						// preamble (7B 0x55), and SFD
					MAC_DES					= 13'h0004,
					MAC_SRC					= 13'h0008,
					TYPE					= 13'h0010,						// MAC package
					ARP_TYPE				= 13'h0020,						// ARP_TYPE include hardware type (2B), protocol type (2B), MAC length (1B), IP length (1B), 'h0001_0800_0604
					ARP_OPCODE				= 13'h0040,
					ARP_SRC_MAC				= 13'h0080,
					ARP_SRC_IP				= 13'h0100,
					ARP_DES_MAC				= 13'h0200,
					ARP_DES_IP				= 13'h0400,
					ARP_FILL				= 13'h0800,						// ARP
					CRC						= 13'h1000;

// -------------------------------- receive arp request ------------------------------------------
	reg		[7:0]							gmii_rxdata_r;
	reg		[12:0]							rx_state;
	reg		[2:0]							rx_cnt_pre;
	reg		[2:0]							rx_cnt_mac_des;
	reg		[47:0]							mac_des;
	reg		[2:0]							rx_cnt_mac_src;
	reg		[47:0]							mac_src;
	reg										rx_cnt_type;
	reg		[2:0]							rx_cnt_arp_type;
	reg		[47:0]							arp_type;
	reg										rx_cnt_arp_opcode;
	reg		[2:0]							rx_cnt_arp_src_mac;
	reg		[1:0]							rx_cnt_arp_src_ip;
	reg		[31:0]							ip_src;
	reg		[2:0]							rx_cnt_arp_des_mac;
	reg		[2:0]							rx_cnt_arp_des_ip;
	reg		[31:0]							ip_des;
	reg		[4:0]							rx_cnt_arp_fill;
	reg		[2:0]							rx_cnt_crc;
	reg		[31:0]							rx_crc32_read;
	reg										arp_req;						// correct ARP request sign
	reg										arp_req_true;					// ARP request sign after crc32 check
	reg										arp_resp;						// arp response starting signal
	
always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_state <= IDLE;
	end else case (rx_state)
		IDLE: begin
			if ( ( rx_cnt_pre == 3'd6 ) && s_mac_tvalid && ( s_mac_tdata == 8'h55 ) ) begin
				rx_state <= RX_SFD;
			end else begin
				rx_state <= IDLE;
			end
		end
		RX_SFD: begin
			if ( s_mac_tvalid && ( s_mac_tdata == 8'hD5 ) ) begin				// when correct SFD (0xD5) is received, jump to next state
				rx_state <= MAC_DES;
			end else if ( s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= RX_SFD;
			end
		end
		MAC_DES: begin
			if ( rx_cnt_mac_des >= 3'd6 && ( mac_des == 48'hFF_FF_FF_FF_FF_FF || mac_des == BOARD_MAC_ADDR ) ) begin
				rx_state <= MAC_SRC;
			end else if ( rx_cnt_mac_des >= 3'd6 ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= MAC_DES;
			end
		end
		MAC_SRC: begin
			if ( rx_cnt_mac_src == 3'd5 && s_mac_tvalid ) begin
				rx_state <= TYPE;
			end else begin
				rx_state <= MAC_SRC;
			end
		end
		TYPE: begin															// only ARP protocol is supported, TYPE = 'h0806
			if ( rx_cnt_type && s_mac_tvalid && ( { gmii_rxdata_r, s_mac_tdata } == 16'h0806 ) ) begin
				rx_state <= ARP_TYPE;
			end else if ( rx_cnt_type && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= TYPE;
			end
		end
		ARP_TYPE: begin														// only IPv4 is supported
			if ( rx_cnt_arp_type >= 3'd6 && arp_type == 48'h0001_0800_0604 ) begin
				rx_state <= ARP_OPCODE;
			end else if ( rx_cnt_arp_type >= 3'd6 ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_TYPE;
			end
		end
		ARP_OPCODE: begin													// 1: request, 2: response, detect request
			if ( rx_cnt_arp_opcode && s_mac_tvalid && ( { gmii_rxdata_r, s_mac_tdata } == 16'h0001 ) ) begin
				rx_state <= ARP_SRC_MAC;
			end else if ( rx_cnt_arp_opcode && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_OPCODE;
			end
		end
		ARP_SRC_MAC: begin													// this information has got in MAC_SRC state. ignore it
			if ( rx_cnt_arp_src_mac >= 3'd5 && s_mac_tvalid ) begin
				rx_state <= ARP_SRC_IP;
			end else begin
				rx_state <= ARP_SRC_MAC;
			end
		end
		ARP_SRC_IP: begin
			if ( rx_cnt_arp_src_ip >= 2'd3 && s_mac_tvalid ) begin
				rx_state <= ARP_DES_MAC;
			end else begin
				rx_state <= ARP_SRC_IP;
			end
		end
		ARP_DES_MAC: begin
			if ( rx_cnt_arp_des_mac >= 3'd5 && s_mac_tvalid ) begin
				rx_state <= ARP_DES_IP;
			end else begin
				rx_state <= ARP_DES_MAC;
			end
		end
		ARP_DES_IP: begin
			if ( rx_cnt_arp_des_ip >= 3'd3 && s_mac_tvalid ) begin
				rx_state <= ARP_FILL;
			end else begin
				rx_state <= ARP_DES_IP;
			end
		end
		ARP_FILL: begin
			if ( rx_cnt_arp_fill >= 5'd17 && s_mac_tvalid ) begin
				rx_state <= CRC;
			end else begin
				rx_state <= ARP_FILL;
			end
		end
		CRC: begin
			if ( rx_cnt_crc >= 3'd3 && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else begin
				rx_state <= CRC;
			end
		end
		default: rx_state <= IDLE;
	endcase
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin						// delay of s_mac_tdata
	if ( !sys_rst_n ) begin
		gmii_rxdata_r <= 8'h0;
	end else if ( s_mac_tvalid ) begin
		gmii_rxdata_r <= s_mac_tdata;
	end else begin
		gmii_rxdata_r <= gmii_rxdata_r;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_pre <= 3'd0;
	end else if ( rx_state == IDLE ) begin									// preamble counter, working in idle state
		if ( s_mac_tvalid && ( s_mac_tdata == 8'h55 ) ) begin					// receive 7 0x55 then jump to SFD
			rx_cnt_pre <= rx_cnt_pre + 3'd1;
		end else if ( s_mac_tvalid ) begin
			rx_cnt_pre <= 3'd0;
		end else begin
			rx_cnt_pre <= rx_cnt_pre;
		end
	end else begin
		rx_cnt_pre <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_mac_des <= 3'd0;
	end else if ( rx_state == MAC_DES ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_mac_des <= rx_cnt_mac_des + 3'd1;
		end else begin
			rx_cnt_mac_des <= rx_cnt_mac_des;
		end
	end else begin
		rx_cnt_mac_des <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		mac_des <= 48'h0;
	end else if ( rx_state == MAC_DES ) begin								// receive 6 byte destination MAC address, when it's broadcast address, jump to next state
		if ( rx_cnt_mac_des == 3'd0 && s_mac_tvalid ) begin
			mac_des <= { s_mac_tdata, mac_des[39:0] };
		end else if ( rx_cnt_mac_des == 3'd1 && s_mac_tvalid ) begin
			mac_des <= { mac_des[47:40], s_mac_tdata, mac_des[31:0] };
		end else if ( rx_cnt_mac_des == 3'd2 && s_mac_tvalid ) begin
			mac_des <= { mac_des[47:32], s_mac_tdata, mac_des[23:0] };
		end else if ( rx_cnt_mac_des == 3'd3 && s_mac_tvalid ) begin
			mac_des <= { mac_des[47:24], s_mac_tdata, mac_des[15:0] };
		end else if ( rx_cnt_mac_des == 3'd4 && s_mac_tvalid ) begin
			mac_des <= { mac_des[47:16], s_mac_tdata, mac_des[7:0] };
		end else if ( rx_cnt_mac_des == 3'd5 && s_mac_tvalid ) begin
			mac_des <= { mac_des[47:8], s_mac_tdata };
		end else begin
			mac_des <= mac_des;
		end
	end else begin
		mac_des <= mac_des;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_mac_src <= 3'd0;
	end else if ( rx_state == MAC_SRC ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_mac_src <= rx_cnt_mac_src + 3'd1;
		end else begin
			rx_cnt_mac_src <= rx_cnt_mac_src;
		end
	end else begin
		rx_cnt_mac_src <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		mac_src <= 48'h0;
	end else if ( rx_state == MAC_SRC ) begin								// receive 6 byte source MAC address, and save it in mac_src temporary
		if ( rx_cnt_mac_src == 3'd0 && s_mac_tvalid ) begin					// when destination IP address is correct, acknowledge this address
			mac_src <= { s_mac_tdata, mac_src[39:0] };
		end else if ( rx_cnt_mac_src == 3'd1 && s_mac_tvalid ) begin
			mac_src <= { mac_src[47:40], s_mac_tdata, mac_src[31:0] };
		end else if ( rx_cnt_mac_src == 3'd2 && s_mac_tvalid ) begin
			mac_src <= { mac_src[47:32], s_mac_tdata, mac_src[23:0] };
		end else if ( rx_cnt_mac_src == 3'd3 && s_mac_tvalid ) begin
			mac_src <= { mac_src[47:24], s_mac_tdata, mac_src[15:0] };
		end else if ( rx_cnt_mac_src == 3'd4 && s_mac_tvalid ) begin
			mac_src <= { mac_src[47:16], s_mac_tdata, mac_src[7:0] };
		end else if ( rx_cnt_mac_src == 3'd5 && s_mac_tvalid ) begin
			mac_src <= { mac_src[47:8], s_mac_tdata };
		end else begin
			mac_src <= mac_src;
		end
	end else begin
		mac_src <= mac_src;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_type <= 1'b0;
	end else if ( rx_state == TYPE ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_type <= ~rx_cnt_type;
		end else begin
			rx_cnt_type <= rx_cnt_type;
		end
	end else begin
		rx_cnt_type <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_type <= 3'd0;
	end else if ( rx_state == ARP_TYPE ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_type <= rx_cnt_arp_type + 3'd1;
		end else begin
			rx_cnt_arp_type <= rx_cnt_arp_type;
		end
	end else begin
		rx_cnt_arp_type <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_type <= 48'h0;
	end else if ( rx_state == ARP_TYPE ) begin
		if ( s_mac_tvalid && rx_cnt_arp_type == 3'd0 ) begin					// hardware type, 'h0001 means Ethernet
			arp_type <= { s_mac_tdata, arp_type[39:0] };
		end else if ( s_mac_tvalid && rx_cnt_arp_type == 3'd1 ) begin
			arp_type <= { arp_type[47:40], s_mac_tdata, arp_type[31:0] };
		end else if ( s_mac_tvalid && rx_cnt_arp_type == 3'd2 ) begin			// protocol type, 'h0800 means IPv4
			arp_type <= { arp_type[47:32], s_mac_tdata, arp_type[23:0] };
		end else if ( s_mac_tvalid && rx_cnt_arp_type == 3'd3 ) begin
			arp_type <= { arp_type[47:24], s_mac_tdata, arp_type[15:0] };
		end else if ( s_mac_tvalid && rx_cnt_arp_type == 3'd4 ) begin			// MAC address length, which must be 6
			arp_type <= { arp_type[47:16], s_mac_tdata, arp_type[7:0] };
		end else if ( s_mac_tvalid && rx_cnt_arp_type == 3'd5 ) begin			// IP address length, which is 4 in IPv4
			arp_type <= { arp_type[47:8], s_mac_tdata };
		end else begin
			arp_type <= arp_type;
		end
	end else begin
		arp_type <= arp_type;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_opcode <= 1'b0;
	end else if ( rx_state == ARP_OPCODE ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_opcode <= ~rx_cnt_arp_opcode;
		end else begin
			rx_cnt_arp_opcode <= rx_cnt_arp_opcode;
		end
	end else begin
		rx_cnt_arp_opcode <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_src_mac <= 3'd0;
	end else if ( rx_state == ARP_SRC_MAC ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_src_mac <= rx_cnt_arp_src_mac + 3'd1;
		end else begin
			rx_cnt_arp_src_mac <= rx_cnt_arp_src_mac;
		end
	end else begin
		rx_cnt_arp_src_mac <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_src_ip <= 2'd0;
	end else if ( rx_state == ARP_SRC_IP ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_src_ip <= rx_cnt_arp_src_ip + 2'd1;
		end else begin
			rx_cnt_arp_src_ip <= rx_cnt_arp_src_ip;
		end
	end else begin
		rx_cnt_arp_src_ip <= 2'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		ip_src <= 32'h0;
	end else if ( rx_state == ARP_SRC_IP ) begin							// receive 4 byte source IP address, and save it in ip_src temporary
		if ( rx_cnt_arp_src_ip == 2'd0 && s_mac_tvalid ) begin					// when destination IP address is correct, acknowledge it
			ip_src <= { s_mac_tdata, ip_src[23:0] };
		end else if ( rx_cnt_arp_src_ip == 2'd1 && s_mac_tvalid ) begin
			ip_src <= { ip_src[31:24], s_mac_tdata, ip_src[15:0] };
		end else if ( rx_cnt_arp_src_ip == 2'd2 && s_mac_tvalid ) begin
			ip_src <= { ip_src[31:16], s_mac_tdata, ip_src[7:0] };
		end else if ( rx_cnt_arp_src_ip == 2'd3 && s_mac_tvalid ) begin
			ip_src <= { ip_src[31:8], s_mac_tdata };
		end else begin
			ip_src <= ip_src;
		end
	end else begin
		ip_src <= ip_src;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_des_mac <= 3'd0;
	end else if ( rx_state == ARP_DES_MAC ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_des_mac <= rx_cnt_arp_des_mac + 3'd1;
		end else begin
			rx_cnt_arp_des_mac <= rx_cnt_arp_des_mac;
		end
	end else begin
		rx_cnt_arp_des_mac <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_des_ip <= 3'd0;
	end else if ( rx_state == ARP_DES_IP ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_des_ip <= rx_cnt_arp_des_ip + 3'd1;
		end else begin
			rx_cnt_arp_des_ip <= rx_cnt_arp_des_ip;
		end
	end else begin
		rx_cnt_arp_des_ip <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		ip_des <= 32'h0;
	end else if ( rx_state == ARP_DES_IP ) begin							// read destination IP
		if ( rx_cnt_arp_des_ip == 3'd0 && s_mac_tvalid ) begin
			ip_des <= { s_mac_tdata, ip_des[23:0] };
		end else if ( rx_cnt_arp_des_ip == 3'd1 && s_mac_tvalid ) begin
			ip_des <= { ip_des[31:24], s_mac_tdata, ip_des[15:0] };
		end else if ( rx_cnt_arp_des_ip == 3'd2 && s_mac_tvalid ) begin
			ip_des <= { ip_des[31:16], s_mac_tdata, ip_des[7:0] };
		end else if ( rx_cnt_arp_des_ip == 3'd3 && s_mac_tvalid ) begin
			ip_des <= { ip_des[31:8], s_mac_tdata };
		end else begin
			ip_des <= ip_des;
		end
	end else begin
		ip_des <= ip_des;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_arp_fill <= 5'd0;
	end else if ( rx_state == ARP_FILL ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_arp_fill <= rx_cnt_arp_fill + 5'd1;
		end else begin
			rx_cnt_arp_fill <= rx_cnt_arp_fill;
		end
	end else begin
		rx_cnt_arp_fill <= 5'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_cnt_crc <= 3'd0;
	end else if ( rx_state == CRC ) begin
		if ( s_mac_tvalid ) begin
			rx_cnt_crc <= rx_cnt_crc + 3'd1;
		end else begin
			rx_cnt_crc <= rx_cnt_crc;
		end
	end else begin
		rx_cnt_crc <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_crc32_read <= 32'h0;
	end else if ( rx_state == CRC ) begin
		if ( rx_cnt_crc == 3'd0 && s_mac_tvalid ) begin
			rx_crc32_read <= { rx_crc32_read[31:8], s_mac_tdata };
		end else if ( rx_cnt_crc == 3'd1 && s_mac_tvalid ) begin
			rx_crc32_read <= { rx_crc32_read[31:16], s_mac_tdata, rx_crc32_read[7:0] };
		end else if ( rx_cnt_crc == 3'd2 && s_mac_tvalid ) begin
			rx_crc32_read <= { rx_crc32_read[31:24], s_mac_tdata, rx_crc32_read[15:0] };
		end else if ( rx_cnt_crc == 3'd3 && s_mac_tvalid ) begin
			rx_crc32_read <= { s_mac_tdata, rx_crc32_read[23:0] };
		end else begin
			rx_crc32_read <= rx_crc32_read;
		end
	end else begin
		rx_crc32_read <= rx_crc32_read;
	end
end

// 鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯�?ARP request crc32 check 鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯�?
	reg		[7:0]							rx_crc_data;
	reg										rx_crc_en;
	reg										rx_crc_end;
	reg										rx_crc_start;
	wire									rx_crc32_valid;
	wire	[31:0]							rx_crc32_temp;
	reg		[31:0]							rx_crc32;

CRC32_D8									u1_rx_CRC32_D8 (
	.sys_clk								( sys_clk		),
	.sys_rst_n								( sys_rst_n		),
	.data									( rx_crc_data	),
	.crc_start								( rx_crc_start	),
	.crc_en									( rx_crc_en		),
	.crc_end								( rx_crc_end	),
	.crc32									( rx_crc32_temp	),
	.crc32_valid							( rx_crc32_valid)
);

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_crc_start <= 1'b0;
	end else if ( rx_state == MAC_DES && rx_cnt_mac_des == 3'd0 && s_mac_tvalid ) begin
		rx_crc_start <= 1'b1;
	end else begin
		rx_crc_start <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_crc_end <= 1'b0;
	end else if ( rx_state == ARP_FILL && rx_cnt_arp_fill == 5'd17 && s_mac_tvalid ) begin
		rx_crc_end <= 1'b1;
	end else begin
		rx_crc_end <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_crc_en <= 1'b0;
	end else if ( rx_state == IDLE || rx_state == RX_SFD || rx_state == CRC ) begin
		rx_crc_en <= 1'b0;
	end else begin
		rx_crc_en <= s_mac_tvalid;
	end
end

always @ ( posedge sys_clk ) begin
	rx_crc_data <= s_mac_tdata;
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		rx_crc32 <= 32'h0;
	end else if ( rx_crc32_valid ) begin
		rx_crc32 <= rx_crc32_temp;
	end else begin
		rx_crc32 <= rx_crc32;
	end
end
// 鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔�?ARP request crc32 check 鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔�?

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_req <= 1'b0;
	end else if ( rx_state == IDLE ) begin									// receive corresponding IP address, enable arp_req
		arp_req <= 1'b0;
	end else if ( rx_cnt_arp_des_ip == 3'd4 && ip_des == BOARD_IP_ADDR ) begin
		arp_req <= 1'b1;
	end else begin
		arp_req <= arp_req;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_req_true <= 1'b0;
	end else if ( rx_cnt_crc >= 3'd4 && rx_crc32_read == rx_crc32 ) begin
		arp_req_true <= arp_req;
	end else begin
		arp_req_true <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_pc_mac <= 48'h0;
	end else if ( arp_req_true ) begin
		arp_pc_mac <= mac_src;
	end else begin
		arp_pc_mac <= arp_pc_mac;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_pc_ip <= 32'h0;
	end else if ( arp_req_true ) begin
		arp_pc_ip <= ip_src;
	end else begin
		arp_pc_ip <= arp_pc_ip;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_resp <= 1'b0;
	end else begin
		arp_resp <= arp_req_true;
	end
end

assign		arp_pc_refresh		=	arp_resp;

// -------------------------------- transform arp response ------------------------------------------

	reg		[12:0]							tx_state;
	reg		[47:0]							tx_des_mac;
	reg		[31:0]							tx_des_ip;
	reg		[2:0]							tx_cnt_package_head;
	reg		[2:0]							tx_cnt_mac_des;
	reg		[2:0]							tx_cnt_mac_src;
	reg										tx_cnt_type;
	reg		[2:0]							tx_cnt_arp_type;
	reg										tx_cnt_arp_opcode;
	reg		[2:0]							tx_cnt_arp_src_mac;
	reg		[1:0]							tx_cnt_arp_src_ip;
	reg		[2:0]							tx_cnt_arp_des_mac;
	reg		[1:0]							tx_cnt_arp_des_ip;
	reg		[4:0]							tx_cnt_arp_fill;
	reg		[1:0]							tx_cnt_crc;

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_state <= IDLE;
	end else case ( tx_state )
		IDLE: begin
			if ( arp_resp ) begin
				tx_state <= TX_PACKAGE_HEAD;
			end else begin
				tx_state <= IDLE;
			end
		end
		TX_PACKAGE_HEAD: begin
			if ( tx_cnt_package_head >= 3'd7 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= MAC_DES;
			end else begin
				tx_state <= TX_PACKAGE_HEAD;
			end
		end
		MAC_DES: begin
			if ( tx_cnt_mac_des >= 3'd5 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= MAC_SRC;
			end else begin
				tx_state <= MAC_DES;
			end
		end
		MAC_SRC: begin
			if ( tx_cnt_mac_src >= 3'd5 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= TYPE;
			end else begin
				tx_state <= MAC_SRC;
			end
		end
		TYPE: begin
			if ( tx_cnt_type && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_TYPE;
			end else begin
				tx_state <= TYPE;
			end
		end
		ARP_TYPE: begin
			if ( tx_cnt_arp_type >= 3'd5 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_OPCODE;
			end else begin
				tx_state <= ARP_TYPE;
			end
		end
		ARP_OPCODE: begin
			if ( tx_cnt_arp_opcode && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_SRC_MAC;
			end else begin
				tx_state <= ARP_OPCODE;
			end
		end
		ARP_SRC_MAC: begin
			if ( tx_cnt_arp_src_mac >= 3'd5 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_SRC_IP;
			end else begin
				tx_state <= ARP_SRC_MAC;
			end
		end
		ARP_SRC_IP: begin
			if ( tx_cnt_arp_src_ip >= 2'd3 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_DES_MAC;
			end else begin
				tx_state <= ARP_SRC_IP;
			end
		end
		ARP_DES_MAC: begin
			if ( tx_cnt_arp_des_mac >= 3'd5 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_DES_IP;
			end else begin
				tx_state <= ARP_DES_MAC;
			end
		end
		ARP_DES_IP: begin
			if ( tx_cnt_arp_des_ip >= 2'd3 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= ARP_FILL;
			end else begin
				tx_state <= ARP_DES_IP;
			end
		end
		ARP_FILL: begin
			if ( tx_cnt_arp_fill >= 5'd17 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= CRC;
			end else begin
				tx_state <= ARP_FILL;
			end
		end
		CRC: begin
			if ( tx_cnt_crc >= 2'd3 && gmii_txen && !gmii_txbusy ) begin
				tx_state <= IDLE;
			end else begin
				tx_state <= CRC;
			end
		end
		default: tx_state <= IDLE;
	endcase
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_des_mac <= 48'h0;
		tx_des_ip <= 32'h0;
	end else if ( arp_resp ) begin
		tx_des_mac <= arp_pc_mac;
		tx_des_ip <= arp_pc_ip;
	end else begin
		tx_des_mac <= tx_des_mac;
		tx_des_ip <= tx_des_ip;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_package_head <= 3'd0;
	end else if ( tx_state == TX_PACKAGE_HEAD ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_package_head <= tx_cnt_package_head + 3'd1;
		end else begin
			tx_cnt_package_head <= tx_cnt_package_head;
		end
	end else begin
		tx_cnt_package_head <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_mac_des <= 3'd0;
	end else if ( tx_state == MAC_DES ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_mac_des <= tx_cnt_mac_des + 3'd1;
		end else begin
			tx_cnt_mac_des <= tx_cnt_mac_des;
		end
	end else begin
		tx_cnt_mac_des <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_mac_src <= 3'd0;
	end else if ( tx_state == MAC_SRC ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_mac_src <= tx_cnt_mac_src + 3'd1;
		end else begin
			tx_cnt_mac_src <= tx_cnt_mac_src;
		end
	end else begin
		tx_cnt_mac_src <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_type <= 1'b0;
	end else if ( tx_state == TYPE ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_type <= ~tx_cnt_type;
		end else begin
			tx_cnt_type <= tx_cnt_type;
		end
	end else begin
		tx_cnt_type <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_type <= 3'd0;
	end else if ( tx_state == ARP_TYPE ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_type <= tx_cnt_arp_type + 3'd1;
		end else begin
			tx_cnt_arp_type <= tx_cnt_arp_type;
		end
	end else begin
		tx_cnt_arp_type <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_opcode <= 1'b0;
	end else if ( tx_state == ARP_OPCODE ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_opcode <= ~tx_cnt_arp_opcode;
		end else begin
			tx_cnt_arp_opcode <= tx_cnt_arp_opcode;
		end
	end else begin
		tx_cnt_arp_opcode <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_src_mac <= 3'd0;
	end else if ( tx_state == ARP_SRC_MAC ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_src_mac <= tx_cnt_arp_src_mac + 3'd1;
		end else begin
			tx_cnt_arp_src_mac <= tx_cnt_arp_src_mac;
		end
	end else begin
		tx_cnt_arp_src_mac <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_src_ip <= 2'd0;
	end else if ( tx_state == ARP_SRC_IP ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_src_ip <= tx_cnt_arp_src_ip + 2'd1;
		end else begin
			tx_cnt_arp_src_ip <= tx_cnt_arp_src_ip;
		end
	end else begin
		tx_cnt_arp_src_ip <= 2'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_des_mac <= 3'd0;
	end else if ( tx_state == ARP_DES_MAC ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_des_mac <= tx_cnt_arp_des_mac + 3'd1;
		end else begin
			tx_cnt_arp_des_mac <= tx_cnt_arp_des_mac;
		end
	end else begin
		tx_cnt_arp_des_mac <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_des_ip <= 2'd0;
	end else if ( tx_state == ARP_DES_IP ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_des_ip <= tx_cnt_arp_des_ip + 2'd1;
		end else begin
			tx_cnt_arp_des_ip <= tx_cnt_arp_des_ip;
		end
	end else begin
		tx_cnt_arp_des_ip <= 2'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_arp_fill <= 5'd0;
	end else if ( tx_state == ARP_FILL ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_arp_fill <= tx_cnt_arp_fill + 5'd1;
		end else begin
			tx_cnt_arp_fill <= tx_cnt_arp_fill;
		end
	end else begin
		tx_cnt_arp_fill <= 5'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_cnt_crc <= 2'd0;
	end else if ( tx_state == CRC ) begin
		if ( gmii_txen && !gmii_txbusy ) begin
			tx_cnt_crc <= tx_cnt_crc + 2'd1;
		end else begin
			tx_cnt_crc <= tx_cnt_crc;
		end
	end else begin
		tx_cnt_crc <= 2'd0;
	end
end


always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		arp_working <= 1'b0;
	end else if ( tx_state == IDLE ) begin
		arp_working <= 1'b0;
	end else begin
		arp_working <= 1'b1;
	end
end

// 鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯�?ARP request crc32 check 鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯啌鈫撯�?
	wire									tx_crc_en;
	wire									tx_crc_end;
	wire									tx_crc_start;
	wire									tx_crc32_valid;
	wire	[31:0]							tx_crc32_temp;
	reg		[31:0]							tx_crc32;

assign		tx_crc_en		=	( tx_state != IDLE ) && ( tx_state != TX_PACKAGE_HEAD ) && ( tx_state != CRC ) && gmii_txen && !gmii_txbusy;
assign		tx_crc_start	=	( tx_state == MAC_DES ) && ( tx_cnt_mac_des == 3'd0 ) && gmii_txen && !gmii_txbusy;
assign		tx_crc_end		=	( tx_state == ARP_FILL ) && ( tx_cnt_arp_fill >= 5'd17 ) && gmii_txen && !gmii_txbusy;

CRC32_D8									u2_tx_CRC32_D8 (
	.sys_clk								( sys_clk		),
	.sys_rst_n								( sys_rst_n		),
	.data									( gmii_txdata	),
	.crc_start								( tx_crc_start	),
	.crc_en									( tx_crc_en		),
	.crc_end								( tx_crc_end	),
	.crc32									( tx_crc32_temp	),
	.crc32_valid							( tx_crc32_valid)
);

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		tx_crc32 <= 32'h0;
	end else if ( tx_crc32_valid ) begin
		tx_crc32 <= tx_crc32_temp;
	end else begin
		tx_crc32 <= tx_crc32;
	end
end
// 鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔�?ARP request crc32 check 鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔啈鈫戔�?

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		gmii_txdata <= 8'h0;
	end else case ( tx_state )
		IDLE: begin
			if ( arp_resp ) begin
				gmii_txdata <= 8'h55;
			end else begin
				gmii_txdata <= 8'h0;
			end
		end
		TX_PACKAGE_HEAD: begin
			if ( tx_cnt_package_head == 3'd6 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'hD5;
			end else if ( tx_cnt_package_head == 3'd7 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[47:40];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		MAC_DES: begin
			if ( tx_cnt_mac_des == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[39:32];
			end else if ( tx_cnt_mac_des == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[31:24];
			end else if ( tx_cnt_mac_des == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[23:16];
			end else if ( tx_cnt_mac_des == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[15:8];
			end else if ( tx_cnt_mac_des == 3'd4 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[7:0];
			end else if ( tx_cnt_mac_des == 3'd5 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[47:40];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		MAC_SRC: begin
			if ( tx_cnt_mac_src == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[39:32];
			end else if ( tx_cnt_mac_src == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[31:24];
			end else if ( tx_cnt_mac_src == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[23:16];
			end else if ( tx_cnt_mac_src == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[15:8];
			end else if ( tx_cnt_mac_src == 3'd4 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[7:0];
			end else if ( tx_cnt_mac_src == 3'd5 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h08;
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		TYPE: begin
			if ( !tx_cnt_type && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h06;										// 0806, ARP protocol
			end else if ( tx_cnt_type && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h00;
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		ARP_TYPE: begin
			if ( tx_cnt_arp_type == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h01;										// 0001, Ethernet
			end else if ( tx_cnt_arp_type == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h08;
			end else if ( tx_cnt_arp_type == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h00;										// 0800, IPv4
			end else if ( tx_cnt_arp_type == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h06;										// MAC address length
			end else if ( tx_cnt_arp_type == 3'd4 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h04;										// IP address length
			end else if ( tx_cnt_arp_type == 3'd5 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h00;
			end else begin
				gmii_txdata <= gmii_txdata;
			end
			
		end
		ARP_OPCODE: begin
			if ( !tx_cnt_arp_opcode && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h02;										// 0002, ARP response
			end else if ( tx_cnt_arp_opcode && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[47:40];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		ARP_SRC_MAC: begin
			if ( tx_cnt_arp_src_mac == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[39:32];
			end else if ( tx_cnt_arp_src_mac == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[31:24];
			end else if ( tx_cnt_arp_src_mac == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[23:16];
			end else if ( tx_cnt_arp_src_mac == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[15:8];
			end else if ( tx_cnt_arp_src_mac == 3'd4 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_MAC_ADDR[7:0];
			end else if ( tx_cnt_arp_src_mac == 3'd5 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_IP_ADDR[31:24];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		ARP_SRC_IP: begin
			if ( tx_cnt_arp_src_ip == 2'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_IP_ADDR[23:16];
			end else if ( tx_cnt_arp_src_ip == 2'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_IP_ADDR[15:8];
			end else if ( tx_cnt_arp_src_ip == 2'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= BOARD_IP_ADDR[7:0];
			end else if ( tx_cnt_arp_src_ip == 2'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[47:40];
			end else begin
			
			end
		end
		ARP_DES_MAC: begin
			if ( tx_cnt_arp_des_mac == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[39:32];
			end else if ( tx_cnt_arp_des_mac == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[31:24];
			end else if ( tx_cnt_arp_des_mac == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[23:16];
			end else if ( tx_cnt_arp_des_mac == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[15:8];
			end else if ( tx_cnt_arp_des_mac == 3'd4 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_mac[7:0];
			end else if ( tx_cnt_arp_des_mac == 3'd5 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_ip[31:24];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		ARP_DES_IP: begin
			if ( tx_cnt_arp_des_ip == 2'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_ip[23:16];
			end else if ( tx_cnt_arp_des_ip == 2'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_ip[15:8];
			end else if ( tx_cnt_arp_des_ip == 2'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_des_ip[7:0];
			end else if ( tx_cnt_arp_des_ip == 2'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h00;										// filled data
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		ARP_FILL: begin
			if ( tx_crc32_valid ) begin
				gmii_txdata <= tx_crc32_temp[7:0];
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		CRC: begin
			if ( tx_cnt_crc == 3'd0 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_crc32[15:8];
			end else if ( tx_cnt_crc == 3'd1 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_crc32[23:16];
			end else if ( tx_cnt_crc == 3'd2 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= tx_crc32[31:24];
			end else if ( tx_cnt_crc == 3'd3 && gmii_txen && !gmii_txbusy ) begin
				gmii_txdata <= 8'h00;
			end else begin
				gmii_txdata <= gmii_txdata;
			end
		end
		default: gmii_txdata <= 8'h0;
	endcase
end

// ================================ UDP RX part (from udp_gmii_rx.v) ================================

	localparam		UDP_IDLE					= 18'h0_0001,
					SFD						= 18'h0_0002,
					MAC_ADDR				= 18'h0_0004,					// destination MAC and source MAC
					UDP_TYPE					= 18'h0_0008,					// 'h0800, only IPv4 supported
					IP_TYPE					= 18'h0_0010,					// IP version, IP header length ( *4 Byte ), service type, 'h4500
					IP_LEN					= 18'h0_0020,					// network length
					IP_ID					= 18'h0_0040,					// identification
					IP_SPLIT				= 18'h0_0080,					// flags and fragment offset
					IP_TTL					= 18'h0_0100,					// time to live, initial value is 64 or 128
					IP_PROTOCOL				= 18'h0_0200,					// UDP: 17
					IP_CHECK				= 18'h0_0400,					// IP header checksum, ignore it
					IP_ADDR					= 18'h0_0800,					// source IP address and destination IP address
					IP_FILL					= 18'h0_1000,					// when IP header length > 5, filled data shows
					UDP_PORT				= 18'h0_2000,					// source PORT and destination PORT
					UDP_LEN					= 18'h0_4000,					// udp length, ( = network length - IP header length ) if have not split
					UDP_CHECK				= 18'h0_8000,					// udp checksum, ignore it
					DATA					= 18'h1_0000,
					UDP_CRC						= 18'h2_0000;
	
	reg		[7:0]							gmii_rxdata_d;
	reg		[17:0]							state;
	
	reg		[47:0]							des_mac;
	reg		[31:0]							des_ip;
	reg		[15:0]							des_port;
	reg		[47:0]							src_mac;
	reg		[31:0]							src_ip;
	reg		[15:0]							src_port;
	reg		[5:0]							ip_header_len;
	reg		[15:0]							ip_len;
	reg		[15:0]							udp_len;
	reg		[15:0]							id;
	reg		[2:0]							flags;
	
	reg		[2:0]							cnt_pre;
	reg		[3:0]							cnt_mac_addr;
	reg										cnt_type;
	reg										cnt_ip_type;
	reg										cnt_ip_len;
	reg										cnt_ip_id;
	reg										cnt_ip_split;
	reg										cnt_ip_check;
	reg		[2:0]							cnt_ip_addr;
	reg		[1:0]							cnt_udp_port;
	reg										cnt_udp_len;
	reg										cnt_udp_check;
	reg		[1:0]							cnt_crc;
	reg		[5:0]							cnt_network;					// count network length up to 63, avoid short data in udp, complete filled data in ip header

	wire									pc_refresh;
	reg		[15:0]							cnt_data;
	reg		[15:0]							data_len;
	reg										udp_continue;					// flags[0] is assigned to it when state == UDP_CRC. indicates that next frame is continuous






always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		state <= UDP_IDLE;
		test_count <= 0;
	end else begin
		case ( state )
			UDP_IDLE: begin
				if ( cnt_pre >= 3'd6 && s_mac_tvalid && s_mac_tdata == 8'h55 ) begin
					state <= SFD;
				end else begin
					state <= UDP_IDLE;
				end
			end
			SFD: begin
				if ( s_mac_tvalid && s_mac_tdata == 8'hD5 ) begin					// SFD == 'hD5
					state <= MAC_ADDR;
				end else if ( s_mac_tvalid ) begin
					state <= UDP_IDLE;
				end else begin
					state <= SFD;
				end
			end
			MAC_ADDR: begin
				if ( cnt_mac_addr >= 4'd11 && s_mac_tvalid ) begin
					if ( des_mac == BOARD_MAC_ADDR ) begin
						state <= UDP_TYPE;
					end else begin
						state <= UDP_IDLE;
					end
				end else begin
					state <= MAC_ADDR;
				end
			end
			UDP_TYPE: begin
				if ( cnt_type && s_mac_tvalid ) begin
					if ( {gmii_rxdata_d, s_mac_tdata} == 16'h0800 ) begin		// IPv4 only, UDP_TYPE = 'h0800
						state <= IP_TYPE;
					end else begin
						state <= UDP_IDLE;
					end
				end else begin
					state <= UDP_TYPE;
				end
			end
			IP_TYPE: begin
				if ( cnt_ip_type && s_mac_tvalid ) begin
					if ( gmii_rxdata_d[7:4] == 'h4 ) begin						// IPv4 only
						state <= IP_LEN;
					end else begin
						state <= UDP_IDLE;
					end
				end else begin
					state <= IP_TYPE;
				end
			end
			IP_LEN: begin
				if ( cnt_ip_len && s_mac_tvalid ) begin
					state <= IP_ID;
				end else begin
					state <= IP_LEN;
				end
			end
			IP_ID: begin
				if ( cnt_ip_id && s_mac_tvalid ) begin
					state <= IP_SPLIT;
				end else begin
					state <= IP_ID;
				end
			end
			IP_SPLIT: begin
				if ( cnt_ip_split && s_mac_tvalid ) begin
					state <= IP_TTL;
				end else begin
					state <= IP_SPLIT;
				end
			end
			IP_TTL: begin
				if ( s_mac_tvalid ) begin
					state <= IP_PROTOCOL;
				end else begin
					state <= IP_TTL;
				end
			end
			IP_PROTOCOL: begin
				if ( s_mac_tvalid && s_mac_tdata == 8'd17 ) begin					// UDP only
					state <= IP_CHECK;
				end else if ( s_mac_tvalid ) begin
					state <= UDP_IDLE;
				end else begin
					state <= IP_PROTOCOL;
				end
			end
			IP_CHECK: begin
				if ( cnt_ip_check && s_mac_tvalid ) begin
					state <= IP_ADDR;
				end else begin
					state <= IP_CHECK;
				end
			end
			IP_ADDR: begin
				if ( cnt_ip_addr >= 3'd7 && s_mac_tvalid && udp_continue && cnt_network < ip_header_len - 1 ) begin
					state <= IP_FILL;
				end else if ( cnt_ip_addr >= 3'd7 && s_mac_tvalid && udp_continue ) begin
					state <= DATA;
				end else if ( cnt_ip_addr >= 3'd7 && s_mac_tvalid ) begin
					state <= UDP_PORT;
				end else begin
					state <= IP_ADDR;
				end
			end
			IP_FILL: begin
				if ( cnt_network >= ip_header_len - 1 && s_mac_tvalid && udp_continue ) begin
					state <= DATA;
				end else if ( cnt_network >= ip_header_len - 1 && s_mac_tvalid ) begin
					state <= UDP_PORT;
				end else begin
					state <= IP_ADDR;
				end
			end
			UDP_PORT: begin
				if ( des_ip != BOARD_IP_ADDR ) begin
					state <= UDP_IDLE;
				end else if ( cnt_udp_port >= 2'd3 && s_mac_tvalid ) begin
					state <= UDP_LEN;
				end else begin
					state <= UDP_PORT;
				end
			end
			UDP_LEN: begin
				if ( cnt_udp_len && s_mac_tvalid ) begin
					state <= UDP_CHECK;
				end else begin
					state <= UDP_LEN;
				end
			end
			UDP_CHECK: begin
				if ( cnt_udp_check && s_mac_tvalid ) begin
					state <= DATA;
				end else begin
					state <= UDP_CHECK;
				end
			end
			DATA: begin
				//STL鐪嬩簡璁℃暟鍣紝纭疄鏄崱杩欓噷鐘舵€佹満瀵艰嚧姝绘満
				if ( cnt_data >= data_len - 16'd1 && s_mac_tvalid && cnt_network >= 'd45 ) begin
					state <= UDP_CRC;
					test_count <= test_count +1'b1;
				end else begin
					state <= DATA;
				end
			end
			UDP_CRC: begin
				if ( cnt_crc >= 2'd3 && s_mac_tvalid ) begin
					state <= UDP_IDLE;
				end else begin
					state <= UDP_CRC;
				end
			end
			default: state <= UDP_IDLE;
		endcase


	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		gmii_rxdata_d <= 8'h0;
	end else if ( s_mac_tvalid ) begin
		gmii_rxdata_d <= s_mac_tdata;
	end else begin
		gmii_rxdata_d <= gmii_rxdata_d;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_pre <= 3'd0;
	end else if ( state == UDP_IDLE ) begin
		if ( s_mac_tvalid && s_mac_tdata == 8'h55 ) begin
			cnt_pre <= cnt_pre + 3'd1;
		end else if ( s_mac_tvalid ) begin
			cnt_pre <= 3'd0;
		end else begin
			cnt_pre <= cnt_pre;
		end
	end else begin
		cnt_pre <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_mac_addr <= 4'd0;
	end else if ( state == MAC_ADDR ) begin
		if ( s_mac_tvalid ) begin
			cnt_mac_addr <= cnt_mac_addr + 4'd1;
		end else begin
			cnt_mac_addr <= cnt_mac_addr;
		end
	end else begin
		cnt_mac_addr <= 4'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		des_mac <= 48'h0;
	end else if ( state == MAC_ADDR ) begin
		if ( cnt_mac_addr == 4'd0 && s_mac_tvalid ) begin
			des_mac <= { s_mac_tdata, des_mac[39:0] };
		end else if ( cnt_mac_addr == 4'd1 && s_mac_tvalid ) begin
			des_mac <= { des_mac[47:40], s_mac_tdata, des_mac[31:0] };
		end else if ( cnt_mac_addr == 4'd2 && s_mac_tvalid ) begin
			des_mac <= { des_mac[47:32], s_mac_tdata, des_mac[23:0] };
		end else if ( cnt_mac_addr == 4'd3 && s_mac_tvalid ) begin
			des_mac <= { des_mac[47:24], s_mac_tdata, des_mac[15:0] };
		end else if ( cnt_mac_addr == 4'd4 && s_mac_tvalid ) begin
			des_mac <= { des_mac[47:16], s_mac_tdata, des_mac[7:0] };
		end else if ( cnt_mac_addr == 4'd5 && s_mac_tvalid ) begin
			des_mac <= { des_mac[47:8], s_mac_tdata };
		end else begin
			des_mac <= des_mac;
		end
	end else begin
		des_mac <= des_mac;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		src_mac <= 48'h0;
	end else if ( state == MAC_ADDR ) begin
		if ( cnt_mac_addr == 4'd6 && s_mac_tvalid ) begin
			src_mac <= { s_mac_tdata, src_mac[39:0] };
		end else if ( cnt_mac_addr == 4'd7 && s_mac_tvalid ) begin
			src_mac <= { src_mac[47:40], s_mac_tdata, src_mac[31:0] };
		end else if ( cnt_mac_addr == 4'd8 && s_mac_tvalid ) begin
			src_mac <= { src_mac[47:32], s_mac_tdata, src_mac[23:0] };
		end else if ( cnt_mac_addr == 4'd9 && s_mac_tvalid ) begin
			src_mac <= { src_mac[47:24], s_mac_tdata, src_mac[15:0] };
		end else if ( cnt_mac_addr == 4'd10 && s_mac_tvalid ) begin
			src_mac <= { src_mac[47:16], s_mac_tdata, src_mac[7:0] };
		end else if ( cnt_mac_addr == 4'd11 && s_mac_tvalid ) begin
			src_mac <= { src_mac[47:8], s_mac_tdata };
		end else begin
			src_mac <= src_mac;
		end
	end else begin
		src_mac <= src_mac;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_type <= 1'b0;
	end else if ( state == UDP_TYPE ) begin
		if ( s_mac_tvalid ) begin
			cnt_type <= ~cnt_type;
		end else begin
			cnt_type <= cnt_type;
		end
	end else begin
		cnt_type <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_network <= 6'd0;
	end else if ( state == UDP_IDLE || state == SFD || state == MAC_ADDR || state == UDP_TYPE || state == UDP_CRC ) begin
		cnt_network <= 6'd0;
	end else if ( cnt_network >= 6'd63 ) begin
		cnt_network <= 6'd63;
	end else if ( s_mac_tvalid ) begin
		cnt_network <= cnt_network + 6'd1;
	end else begin
		cnt_network <= cnt_network;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_type <= 1'b0;
	end else if ( state == IP_TYPE ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_type <= ~cnt_ip_type;
		end else begin
			cnt_ip_type <= cnt_ip_type;
		end
	end else begin
		cnt_ip_type <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		ip_header_len <= 6'd0;
	end else if ( state == IP_TYPE && !cnt_ip_type && s_mac_tvalid ) begin
		ip_header_len <= s_mac_tdata[3:0] << 2;
	end else begin
		ip_header_len <= ip_header_len;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_len <= 1'b0;
	end else if ( state == IP_LEN ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_len <= ~cnt_ip_len;
		end else begin
			cnt_ip_len <= cnt_ip_len;
		end
	end else begin
		cnt_ip_len <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		ip_len <= 16'd0;
	end else if ( state == IP_LEN ) begin
		if ( !cnt_ip_len && s_mac_tvalid ) begin
			ip_len <= { s_mac_tdata, ip_len[7:0] };
		end else if ( s_mac_tvalid ) begin
			ip_len <= { ip_len[15:8], s_mac_tdata };
		end else begin
			ip_len <= ip_len;
		end
	end else begin
		ip_len <= ip_len;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_id <= 1'b0;
	end else if ( state == IP_ID ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_id <= ~cnt_ip_id;
		end else begin
			cnt_ip_id <= cnt_ip_id;
		end
	end else begin
		cnt_ip_id <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		id <= 16'd0;
	end else if ( state == IP_ID ) begin
		if ( !cnt_ip_id && s_mac_tvalid ) begin
			id <= { s_mac_tdata, id[7:0] };
		end else if ( s_mac_tvalid ) begin
			id <= { id[15:8], s_mac_tdata };
		end else begin
			id <= id;
		end
	end else begin
		id <= id;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_split <= 1'b0;
	end else if ( state == IP_SPLIT ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_split <= ~cnt_ip_split;
		end else begin
			cnt_ip_split <= cnt_ip_split;
		end
	end else begin
		cnt_ip_split <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		flags <= 3'h0;
	end else if ( state == IP_SPLIT && !cnt_ip_split && s_mac_tvalid ) begin
		flags <= s_mac_tdata[7:5];
	end else begin
		flags <= flags;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_check <= 1'b0;
	end else if ( state == IP_CHECK ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_check <= ~cnt_ip_check;
		end else begin
			cnt_ip_check <= cnt_ip_check;
		end
	end else begin
		cnt_ip_check <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_ip_addr <= 3'd0;
	end else if ( state == IP_ADDR ) begin
		if ( s_mac_tvalid ) begin
			cnt_ip_addr <= cnt_ip_addr + 3'd1;
		end else begin
			cnt_ip_addr <= cnt_ip_addr;
		end
	end else begin
		cnt_ip_addr <= 3'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		src_ip <= 32'h0;
	end else if ( state == IP_ADDR ) begin
		if ( cnt_ip_addr == 3'd0 && s_mac_tvalid ) begin
			src_ip <= { s_mac_tdata, src_ip[23:0] };
		end else if ( cnt_ip_addr == 3'd1 && s_mac_tvalid ) begin
			src_ip <= { src_ip[31:24], s_mac_tdata, src_ip[15:0] };
		end else if ( cnt_ip_addr == 3'd2 && s_mac_tvalid ) begin
			src_ip <= { src_ip[31:16], s_mac_tdata, src_ip[7:0] };
		end else if ( cnt_ip_addr == 3'd3 && s_mac_tvalid ) begin
			src_ip <= { src_ip[31:8], s_mac_tdata };
		end else begin
			src_ip <= src_ip;
		end
	end else begin
		src_ip <= src_ip;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		des_ip <= 32'h0;
	end else if ( state == IP_ADDR ) begin
		if ( cnt_ip_addr == 3'd4 && s_mac_tvalid ) begin
			des_ip <= { s_mac_tdata, des_ip[23:0] };
		end else if ( cnt_ip_addr == 3'd5 && s_mac_tvalid ) begin
			des_ip <= { des_ip[31:24], s_mac_tdata, des_ip[15:0] };
		end else if ( cnt_ip_addr == 3'd6 && s_mac_tvalid ) begin
			des_ip <= { des_ip[31:16], s_mac_tdata, des_ip[7:0] };
		end else if ( cnt_ip_addr == 3'd7 && s_mac_tvalid ) begin
			des_ip <= { des_ip[31:8], s_mac_tdata };
		end else begin
			des_ip <= des_ip;
		end
	end else begin
		des_ip <= des_ip;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_udp_port <= 2'd0;
	end else if ( state == UDP_PORT ) begin
		if ( s_mac_tvalid ) begin
			cnt_udp_port <= cnt_udp_port + 2'd1;
		end else begin
			cnt_udp_port <= cnt_udp_port;
		end
	end else begin
		cnt_udp_port <= 2'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		src_port <= 16'h0;
	end else if ( state == UDP_PORT ) begin
		if ( cnt_udp_port == 2'd0 && s_mac_tvalid ) begin
			src_port <= { s_mac_tdata, src_port[7:0] };
		end else if ( cnt_udp_port == 2'd1 && s_mac_tvalid ) begin
			src_port <= { src_port[15:8], s_mac_tdata } ;
		end else begin
			src_port <= src_port;
		end
	end else begin
		src_port <= src_port;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		des_port <= 16'h0;
	end else if ( state == UDP_PORT ) begin
		if ( cnt_udp_port == 2'd0 && s_mac_tvalid ) begin
			des_port <= { s_mac_tdata, des_port[7:0] };
		end else if ( cnt_udp_port == 2'd1 && s_mac_tvalid ) begin
			des_port <= { des_port[15:8], s_mac_tdata } ;
		end else begin
			des_port <= des_port;
		end
	end else begin
		des_port <= des_port;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_udp_len <= 1'b0;
	end else if ( state == UDP_LEN ) begin
		if ( s_mac_tvalid ) begin
			cnt_udp_len <= ~cnt_udp_len;
		end else begin
			cnt_udp_len <= cnt_udp_len;
		end
	end else begin
		cnt_udp_len <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_len <= 16'd0;
	end else if ( state == UDP_LEN ) begin
		if ( !cnt_udp_len && s_mac_tvalid ) begin
			udp_len <= { s_mac_tdata, udp_len[7:0] };
		end else if ( s_mac_tvalid ) begin
			udp_len <= { udp_len[15:8], s_mac_tdata };
		end else begin
			udp_len <= udp_len;
		end
	end else begin
		udp_len <= udp_len;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_udp_check <= 1'b0;
	end else if ( state == UDP_CHECK ) begin
		if ( s_mac_tvalid ) begin
			cnt_udp_check <= ~cnt_udp_check;
		end else begin
			cnt_udp_check <= cnt_udp_check;
		end
	end else begin
		cnt_udp_check <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		data_len <= 16'd0;
	end else begin
		data_len <= ip_len - ip_header_len;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_data <= 16'd0;
	end else if ( state == DATA || state == UDP_PORT || state == UDP_LEN || state == UDP_CHECK ) begin
		if ( s_mac_tvalid ) begin
			cnt_data <= cnt_data + 16'd1;
		end else begin
			cnt_data <= cnt_data;
		end
	end else begin
		cnt_data <= 16'd0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		cnt_crc <= 2'd0;
	end else if ( state == UDP_CRC ) begin
		if ( s_mac_tvalid ) begin
			cnt_crc <= cnt_crc + 2'd1;
		end else begin
			cnt_crc <= cnt_crc;
		end
	end else begin
		cnt_crc <= 2'd0;
	end
end

assign		pc_refresh		=	state == UDP_LEN && !cnt_udp_len && s_mac_tvalid;

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		pc_mac_addr <= 48'h0;
		pc_ip_addr <= 32'h0;
		pc_port <= 16'h0;
		board_port <= 16'h0;
	end else if ( pc_refresh ) begin
		pc_mac_addr <= src_mac;
		pc_ip_addr <= src_ip;
		pc_port <= src_port;
		board_port <= des_port;
	end else begin
		pc_mac_addr <= pc_mac_addr;
		pc_ip_addr <= pc_ip_addr;
		pc_port <= pc_port;
		board_port <= board_port;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxdata <= 8'h0;
	end else if ( state == DATA ) begin
		udp_rxdata <= s_mac_tdata;
	end else begin
		udp_rxdata <= udp_rxdata;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxstart <= 1'b0;
	end else if ( !udp_continue && state == DATA && cnt_data == 16'd8 && s_mac_tvalid ) begin
		udp_rxstart <= 1'b1;
	end else begin
		udp_rxstart <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxend <= 1'b0;
	end else if ( !flags[0] && state == DATA && cnt_data == data_len - 16'd1 && s_mac_tvalid ) begin
		udp_rxend <= 1'b1;
	end else begin
		udp_rxend <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxdv <= 1'b0;
	end else if ( state == DATA && s_mac_tvalid && udp_rxnum < udp_len - 8 ) begin
		udp_rxdv <= 1'b1;
	end else begin
		udp_rxdv <= 1'b0;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxamount <= 16'd0;
	end else if ( state == UDP_CHECK ) begin
		udp_rxamount <= udp_len - 16'd8;
	end else begin
		udp_rxamount <= udp_rxamount;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_rxnum <= 16'd0;
	end else if ( udp_rxstart ) begin
		udp_rxnum <= 16'd1;
	end else if ( state == UDP_CRC && udp_rxnum >= udp_len - 8 ) begin
		udp_rxnum <= 16'd0;
	end else if ( state == DATA && s_mac_tvalid && udp_rxnum < udp_len - 8 ) begin
		udp_rxnum <= udp_rxnum + 16'd1;
	end else begin
		udp_rxnum <= udp_rxnum;
	end
end

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		udp_continue <= 1'b0;
	end else if ( state == UDP_CRC ) begin
		udp_continue <= flags[0];
	end else begin
		udp_continue <= udp_continue;
	end
end

endmodule
