`include "axis.svh"

module tx_fifo_axis(
    input logic      clk,
    input logic      rstn,
    axis.slave sys_tx,
    axis.slave udp_tx,
    axis.master phy_tx
);

// ================================ sys_tx 帧缓存 ================================
logic        sys_frame_end_flag;
logic        sys_data_idx;
logic [8:0] sys_fifo_data; 
assign sys_fifo_data = {1'b0,sys_tx.tdata};

assign sys_tx.tready = 1'b1;
always_ff@(posedge clk or negedge rstn) begin
	if(!rstn) begin
		sys_data_idx   <= 'b0;
		sys_frame_end_flag <= 'b0;
	end else begin
		if(sys_tx.tlast) begin
			sys_data_idx <= 1'b1;
		end else begin
			sys_data_idx <='d0;
			if(sys_data_idx!='d0)begin
				sys_frame_end_flag <= 'b1;
			end
		end
		if (sys_frame_end_flag) begin
			sys_frame_end_flag <= 'b0;
		end
	end
end

wire  		 sys_empty;
wire  	 	 sys_rdreq;
wire[15:0]   sys_q;
wire		 sys_q_idx;
wire[7:0]	 sys_q_data;
wire		 sys_q_end;
assign sys_q_end  = (sys_q_idx);      
assign sys_q_idx  = sys_q[8];
assign sys_q_data = sys_q[7:0];
fifo#(
	.DATA_WIDTH('d9),
	.DEPTH('d1024)
)udp_sys_tx_fifo_512_d9(
	.clock 		(clk),
	.rstn  		(rstn),
	.clear 		(1'b0),
	.wrreq		(sys_tx.tvalid||sys_frame_end_flag),
	.data		(sys_frame_end_flag?{1'b1,8'h00}:sys_fifo_data),
	.empty		(sys_empty),
	.rdreq		(sys_rdreq),
	.q			(sys_q)
);

// ================================ udp_tx 帧缓存 ================================
logic        udp_frame_end_flag;
logic        udp_data_idx;
logic [8:0] udp_fifo_data; 
assign udp_fifo_data = {1'b0,udp_tx.tdata};

assign udp_tx.tready = 1'b1;
always_ff@(posedge clk or negedge rstn) begin
	if(!rstn) begin
		udp_data_idx   <= 'b0;
		udp_frame_end_flag <= 'b0;
	end else begin
		if(udp_tx.tlast) begin
			udp_data_idx <= 1'b1;
		end else begin
			udp_data_idx <='d0;
			if(udp_data_idx!='d0)begin
				udp_frame_end_flag <= 'b1;
			end
		end
		if (udp_frame_end_flag) begin
			udp_frame_end_flag <= 'b0;
		end
	end
end

wire  		 udp_empty;
wire  	 	 udp_rdreq;
wire[15:0]   udp_q;
wire		 udp_q_idx;
wire[7:0]	 udp_q_data;
wire		 udp_q_end;
assign udp_q_end  = (udp_q_idx);      
assign udp_q_idx  = udp_q[8];
assign udp_q_data = udp_q[7:0];
fifo#(
	.DATA_WIDTH('d9),
	.DEPTH('d1024)
)udp_tx_fifo_1024_d9(
	.clock 		(clk),
	.rstn  		(rstn),
	.clear 		(1'b0),
	.wrreq		(udp_tx.tvalid||udp_frame_end_flag),
	.data		(udp_frame_end_flag?{1'b1,8'h00}:udp_fifo_data),
	.empty		(udp_empty),
	.rdreq		(udp_rdreq),
	.q			(udp_q)
);

// ================================ 帧级仲裁: sys 优先 ================================
// 以帧为单位, 在帧结束(读到帧尾标志)时选择下一帧使用的 FIFO
reg			 sel;							// 1'b0: sys, 1'b1: udp
wire		 cur_empty;
wire[15:0]   cur_q;
wire		 cur_q_end;
wire		 cur_rdreq;
assign cur_empty  = sel ? udp_empty : sys_empty;
assign cur_q      = sel ? udp_q     : sys_q;
assign cur_q_end  = cur_q[8];
assign cur_rdreq  = !cur_empty && phy_tx.tready;
assign sys_rdreq  = !sel ? cur_rdreq : 1'b0;
assign udp_rdreq  = sel  ? cur_rdreq : 1'b0;

assign phy_tx.tvalid = cur_rdreq && !cur_q_end;
assign phy_tx.tlast  = !cur_empty && !cur_q_end;
assign phy_tx.tdata  = cur_q[7:0];

always_ff@(posedge clk or negedge rstn) begin
	if(!rstn) begin
		sel <= 1'b0;
	end else if (cur_rdreq && cur_q_end) begin		// 当前帧结束, 选择下一帧: sys 优先
		sel <= sys_empty ? 1'b1 : 1'b0;
	end else if (cur_empty && !sys_empty) begin		// 空闲且 sys 有帧数据, 发送 sys
		sel <= 1'b0;
	end else if (cur_empty && sys_empty && !udp_empty) begin	// 空闲且 sys 无帧数据, 发送 udp
		sel <= 1'b1;
	end else begin
		sel <= sel;
	end
end

endmodule
