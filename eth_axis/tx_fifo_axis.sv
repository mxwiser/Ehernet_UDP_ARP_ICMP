`include "axis.svh"

module tx_fifo_axis(
    input logic      clk,
    input logic      rstn,
    axis.slave sys_tx,
    axis.slave udp_tx,
    axis.master phy_tx
);

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
assign sys_rdreq		= !sys_empty && phy_tx.tready;
assign phy_tx.tvalid = sys_rdreq && !sys_q_end;
assign phy_tx.tlast  = !sys_empty && !sys_q_end;
assign phy_tx.tdata  = sys_q_data;
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
endmodule