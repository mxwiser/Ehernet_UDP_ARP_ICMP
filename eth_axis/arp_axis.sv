`include "axis.svh"

// author:		Benjamin SMith
// create time:	2023/03/17 17:24
// edit time:	2026/08/05
// platform:	Cyclone ep4ce10f17i7, board
// module:		arp_axis
// function:	ARP request receive and response, IPv4 only
//				extracted from udp_axis_rx.sv, AXIS version
// version:		1.0

module arp_axis (
	input	wire							sys_clk,
	input	wire							sys_rst_n,
	
	axis.slave								s_axis_rx,				// PHY RX stream from rmii_axis, tlast is frame-level
	axis.master								m_axis_arp,				// ARP reply TX stream to rmii_axis
	output	reg								arp_working,			// ARP reply is being sent, for TX arbitration
	
	output	reg		[47:0]					arp_pc_mac,				// PC MAC learned by ARP
	output	reg		[31:0]					arp_pc_ip,				// PC IP learned by ARP
	output	wire							arp_pc_refresh			// learned pulse
);

	parameter		BOARD_MAC_ADDR			= 48'h00_11_22_33_44_55;
	parameter		BOARD_IP_ADDR			= 32'hA9_FE_01_17;				// 169.254.1.23

// -------------------------------- axis <-> gmii bridge ------------------------------------------
// RX: s_mac_tvalid / s_mac_tlast / s_mac_tdata come from s_axis_rx, tready is ignored (rmii_axis never backpressures RX)
	wire									s_mac_tvalid;
	wire									s_mac_tlast;				// frame-level: high in frame, falling edge = frame end
	wire		[7:0]						s_mac_tdata	;
	assign		s_mac_tlast			=	s_axis_rx.tlast;
	assign		s_mac_tvalid			=	s_axis_rx.tvalid; 
	assign		s_mac_tdata			=	s_axis_rx.tdata;
	assign		s_axis_rx.tready	=	1'b1;

// TX (ARP reply only): txen / txbusy mapped to AXIS handshake.
// txen && !txbusy  ==  tvalid && tready, so the original FSM body is unchanged
	wire									txen;
	wire									txbusy;
	reg			[7:0]						txdata;
	assign		txen			=	( tx_state != IDLE );
	assign		txbusy			=	!( txen && m_axis_arp.tready );
	assign		m_axis_arp.tvalid	=	txen;
	assign		m_axis_arp.tlast	=	txen;					// frame-level: high in frame, falling edge = frame end
	assign		m_axis_arp.tuser	=	1'b0;
	assign		m_axis_arp.tdata	=	txdata;
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
	reg		[7:0]							s_mac_tdata_r;
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
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
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
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= MAC_DES;
			end
		end
		MAC_SRC: begin
			if ( rx_cnt_mac_src == 3'd5 && s_mac_tvalid ) begin
				rx_state <= TYPE;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= MAC_SRC;
			end
		end
		TYPE: begin															// only ARP protocol is supported, TYPE = 'h0806
			if ( rx_cnt_type && s_mac_tvalid && ( { s_mac_tdata_r, s_mac_tdata } == 16'h0806 ) ) begin
				rx_state <= ARP_TYPE;
			end else if ( rx_cnt_type && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
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
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_TYPE;
			end
		end
		ARP_OPCODE: begin													// 1: request, 2: response, detect request
			if ( rx_cnt_arp_opcode && s_mac_tvalid && ( { s_mac_tdata_r, s_mac_tdata } == 16'h0001 ) ) begin
				rx_state <= ARP_SRC_MAC;
			end else if ( rx_cnt_arp_opcode && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_OPCODE;
			end
		end
		ARP_SRC_MAC: begin													// this information has got in MAC_SRC state. ignore it
			if ( rx_cnt_arp_src_mac >= 3'd5 && s_mac_tvalid ) begin
				rx_state <= ARP_SRC_IP;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_SRC_MAC;
			end
		end
		ARP_SRC_IP: begin
			if ( rx_cnt_arp_src_ip >= 2'd3 && s_mac_tvalid ) begin
				rx_state <= ARP_DES_MAC;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_SRC_IP;
			end
		end
		ARP_DES_MAC: begin
			if ( rx_cnt_arp_des_mac >= 3'd5 && s_mac_tvalid ) begin
				rx_state <= ARP_DES_IP;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_DES_MAC;
			end
		end
		ARP_DES_IP: begin
			if ( rx_cnt_arp_des_ip >= 3'd3 && s_mac_tvalid ) begin
				rx_state <= ARP_FILL;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_DES_IP;
			end
		end
		ARP_FILL: begin
			if ( rx_cnt_arp_fill >= 5'd17 && s_mac_tvalid ) begin
				rx_state <= CRC;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
				rx_state <= IDLE;
			end else begin
				rx_state <= ARP_FILL;
			end
		end
		CRC: begin
			if ( rx_cnt_crc >= 3'd3 && s_mac_tvalid ) begin
				rx_state <= IDLE;
			end else if ( !s_mac_tlast ) begin									// frame ends, back to idle
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
		s_mac_tdata_r <= 8'h0;
	end else if ( s_mac_tvalid ) begin
		s_mac_tdata_r <= s_mac_tdata;
	end else begin
		s_mac_tdata_r <= s_mac_tdata_r;
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

// ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓ ARP request crc32 check ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
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
// ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑ ARP request crc32 check ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑

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
			if ( tx_cnt_package_head >= 3'd7 && txen && !txbusy ) begin
				tx_state <= MAC_DES;
			end else begin
				tx_state <= TX_PACKAGE_HEAD;
			end
		end
		MAC_DES: begin
			if ( tx_cnt_mac_des >= 3'd5 && txen && !txbusy ) begin
				tx_state <= MAC_SRC;
			end else begin
				tx_state <= MAC_DES;
			end
		end
		MAC_SRC: begin
			if ( tx_cnt_mac_src >= 3'd5 && txen && !txbusy ) begin
				tx_state <= TYPE;
			end else begin
				tx_state <= MAC_SRC;
			end
		end
		TYPE: begin
			if ( tx_cnt_type && txen && !txbusy ) begin
				tx_state <= ARP_TYPE;
			end else begin
				tx_state <= TYPE;
			end
		end
		ARP_TYPE: begin
			if ( tx_cnt_arp_type >= 3'd5 && txen && !txbusy ) begin
				tx_state <= ARP_OPCODE;
			end else begin
				tx_state <= ARP_TYPE;
			end
		end
		ARP_OPCODE: begin
			if ( tx_cnt_arp_opcode && txen && !txbusy ) begin
				tx_state <= ARP_SRC_MAC;
			end else begin
				tx_state <= ARP_OPCODE;
			end
		end
		ARP_SRC_MAC: begin
			if ( tx_cnt_arp_src_mac >= 3'd5 && txen && !txbusy ) begin
				tx_state <= ARP_SRC_IP;
			end else begin
				tx_state <= ARP_SRC_MAC;
			end
		end
		ARP_SRC_IP: begin
			if ( tx_cnt_arp_src_ip >= 2'd3 && txen && !txbusy ) begin
				tx_state <= ARP_DES_MAC;
			end else begin
				tx_state <= ARP_SRC_IP;
			end
		end
		ARP_DES_MAC: begin
			if ( tx_cnt_arp_des_mac >= 3'd5 && txen && !txbusy ) begin
				tx_state <= ARP_DES_IP;
			end else begin
				tx_state <= ARP_DES_MAC;
			end
		end
		ARP_DES_IP: begin
			if ( tx_cnt_arp_des_ip >= 2'd3 && txen && !txbusy ) begin
				tx_state <= ARP_FILL;
			end else begin
				tx_state <= ARP_DES_IP;
			end
		end
		ARP_FILL: begin
			if ( tx_cnt_arp_fill >= 5'd17 && txen && !txbusy ) begin
				tx_state <= CRC;
			end else begin
				tx_state <= ARP_FILL;
			end
		end
		CRC: begin
			if ( tx_cnt_crc >= 2'd3 && txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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
		if ( txen && !txbusy ) begin
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

// ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓ ARP request crc32 check ↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓↓
	wire									tx_crc_en;
	wire									tx_crc_end;
	wire									tx_crc_start;
	wire									tx_crc32_valid;
	wire	[31:0]							tx_crc32_temp;
	reg		[31:0]							tx_crc32;

assign		tx_crc_en		=	( tx_state != IDLE ) && ( tx_state != TX_PACKAGE_HEAD ) && ( tx_state != CRC ) && txen && !txbusy;
assign		tx_crc_start	=	( tx_state == MAC_DES ) && ( tx_cnt_mac_des == 3'd0 ) && txen && !txbusy;
assign		tx_crc_end		=	( tx_state == ARP_FILL ) && ( tx_cnt_arp_fill >= 5'd17 ) && txen && !txbusy;

CRC32_D8									u2_tx_CRC32_D8 (
	.sys_clk								( sys_clk		),
	.sys_rst_n								( sys_rst_n		),
	.data									( txdata	),
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
// ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑ ARP request crc32 check ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑

always @ ( posedge sys_clk or negedge sys_rst_n ) begin
	if ( !sys_rst_n ) begin
		txdata <= 8'h0;
	end else case ( tx_state )
		IDLE: begin
			if ( arp_resp ) begin
				txdata <= 8'h55;
			end else begin
				txdata <= 8'h0;
			end
		end
		TX_PACKAGE_HEAD: begin
			if ( tx_cnt_package_head == 3'd6 && txen && !txbusy ) begin
				txdata <= 8'hD5;
			end else if ( tx_cnt_package_head == 3'd7 && txen && !txbusy ) begin
				txdata <= tx_des_mac[47:40];
			end else begin
				txdata <= txdata;
			end
		end
		MAC_DES: begin
			if ( tx_cnt_mac_des == 3'd0 && txen && !txbusy ) begin
				txdata <= tx_des_mac[39:32];
			end else if ( tx_cnt_mac_des == 3'd1 && txen && !txbusy ) begin
				txdata <= tx_des_mac[31:24];
			end else if ( tx_cnt_mac_des == 3'd2 && txen && !txbusy ) begin
				txdata <= tx_des_mac[23:16];
			end else if ( tx_cnt_mac_des == 3'd3 && txen && !txbusy ) begin
				txdata <= tx_des_mac[15:8];
			end else if ( tx_cnt_mac_des == 3'd4 && txen && !txbusy ) begin
				txdata <= tx_des_mac[7:0];
			end else if ( tx_cnt_mac_des == 3'd5 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[47:40];
			end else begin
				txdata <= txdata;
			end
		end
		MAC_SRC: begin
			if ( tx_cnt_mac_src == 3'd0 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[39:32];
			end else if ( tx_cnt_mac_src == 3'd1 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[31:24];
			end else if ( tx_cnt_mac_src == 3'd2 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[23:16];
			end else if ( tx_cnt_mac_src == 3'd3 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[15:8];
			end else if ( tx_cnt_mac_src == 3'd4 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[7:0];
			end else if ( tx_cnt_mac_src == 3'd5 && txen && !txbusy ) begin
				txdata <= 8'h08;
			end else begin
				txdata <= txdata;
			end
		end
		TYPE: begin
			if ( !tx_cnt_type && txen && !txbusy ) begin
				txdata <= 8'h06;										// 0806, ARP protocol
			end else if ( tx_cnt_type && txen && !txbusy ) begin
				txdata <= 8'h00;
			end else begin
				txdata <= txdata;
			end
		end
		ARP_TYPE: begin
			if ( tx_cnt_arp_type == 3'd0 && txen && !txbusy ) begin
				txdata <= 8'h01;										// 0001, Ethernet
			end else if ( tx_cnt_arp_type == 3'd1 && txen && !txbusy ) begin
				txdata <= 8'h08;
			end else if ( tx_cnt_arp_type == 3'd2 && txen && !txbusy ) begin
				txdata <= 8'h00;										// 0800, IPv4
			end else if ( tx_cnt_arp_type == 3'd3 && txen && !txbusy ) begin
				txdata <= 8'h06;										// MAC address length
			end else if ( tx_cnt_arp_type == 3'd4 && txen && !txbusy ) begin
				txdata <= 8'h04;										// IP address length
			end else if ( tx_cnt_arp_type == 3'd5 && txen && !txbusy ) begin
				txdata <= 8'h00;
			end else begin
				txdata <= txdata;
			end
			
		end
		ARP_OPCODE: begin
			if ( !tx_cnt_arp_opcode && txen && !txbusy ) begin
				txdata <= 8'h02;										// 0002, ARP response
			end else if ( tx_cnt_arp_opcode && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[47:40];
			end else begin
				txdata <= txdata;
			end
		end
		ARP_SRC_MAC: begin
			if ( tx_cnt_arp_src_mac == 3'd0 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[39:32];
			end else if ( tx_cnt_arp_src_mac == 3'd1 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[31:24];
			end else if ( tx_cnt_arp_src_mac == 3'd2 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[23:16];
			end else if ( tx_cnt_arp_src_mac == 3'd3 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[15:8];
			end else if ( tx_cnt_arp_src_mac == 3'd4 && txen && !txbusy ) begin
				txdata <= BOARD_MAC_ADDR[7:0];
			end else if ( tx_cnt_arp_src_mac == 3'd5 && txen && !txbusy ) begin
				txdata <= BOARD_IP_ADDR[31:24];
			end else begin
				txdata <= txdata;
			end
		end
		ARP_SRC_IP: begin
			if ( tx_cnt_arp_src_ip == 2'd0 && txen && !txbusy ) begin
				txdata <= BOARD_IP_ADDR[23:16];
			end else if ( tx_cnt_arp_src_ip == 2'd1 && txen && !txbusy ) begin
				txdata <= BOARD_IP_ADDR[15:8];
			end else if ( tx_cnt_arp_src_ip == 2'd2 && txen && !txbusy ) begin
				txdata <= BOARD_IP_ADDR[7:0];
			end else if ( tx_cnt_arp_src_ip == 2'd3 && txen && !txbusy ) begin
				txdata <= tx_des_mac[47:40];
			end else begin
			
			end
		end
		ARP_DES_MAC: begin
			if ( tx_cnt_arp_des_mac == 3'd0 && txen && !txbusy ) begin
				txdata <= tx_des_mac[39:32];
			end else if ( tx_cnt_arp_des_mac == 3'd1 && txen && !txbusy ) begin
				txdata <= tx_des_mac[31:24];
			end else if ( tx_cnt_arp_des_mac == 3'd2 && txen && !txbusy ) begin
				txdata <= tx_des_mac[23:16];
			end else if ( tx_cnt_arp_des_mac == 3'd3 && txen && !txbusy ) begin
				txdata <= tx_des_mac[15:8];
			end else if ( tx_cnt_arp_des_mac == 3'd4 && txen && !txbusy ) begin
				txdata <= tx_des_mac[7:0];
			end else if ( tx_cnt_arp_des_mac == 3'd5 && txen && !txbusy ) begin
				txdata <= tx_des_ip[31:24];
			end else begin
				txdata <= txdata;
			end
		end
		ARP_DES_IP: begin
			if ( tx_cnt_arp_des_ip == 2'd0 && txen && !txbusy ) begin
				txdata <= tx_des_ip[23:16];
			end else if ( tx_cnt_arp_des_ip == 2'd1 && txen && !txbusy ) begin
				txdata <= tx_des_ip[15:8];
			end else if ( tx_cnt_arp_des_ip == 2'd2 && txen && !txbusy ) begin
				txdata <= tx_des_ip[7:0];
			end else if ( tx_cnt_arp_des_ip == 2'd3 && txen && !txbusy ) begin
				txdata <= 8'h00;										// filled data
			end else begin
				txdata <= txdata;
			end
		end
		ARP_FILL: begin
			if ( tx_crc32_valid ) begin
				txdata <= tx_crc32_temp[7:0];
			end else begin
				txdata <= txdata;
			end
		end
		CRC: begin
			if ( tx_cnt_crc == 3'd0 && txen && !txbusy ) begin
				txdata <= tx_crc32[15:8];
			end else if ( tx_cnt_crc == 3'd1 && txen && !txbusy ) begin
				txdata <= tx_crc32[23:16];
			end else if ( tx_cnt_crc == 3'd2 && txen && !txbusy ) begin
				txdata <= tx_crc32[31:24];
			end else if ( tx_cnt_crc == 3'd3 && txen && !txbusy ) begin
				txdata <= 8'h00;
			end else begin
				txdata <= txdata;
			end
		end
		default: txdata <= 8'h0;
	endcase
end

endmodule
