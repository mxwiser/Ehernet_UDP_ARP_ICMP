
module flasher (
	clk_clk,
	reset_reset_n,
	avl_csr_address,
	avl_csr_read,
	avl_csr_readdata,
	avl_csr_write,
	avl_csr_writedata,
	avl_csr_waitrequest,
	avl_csr_readdatavalid,
	avl_mem_write,
	avl_mem_burstcount,
	avl_mem_waitrequest,
	avl_mem_read,
	avl_mem_address,
	avl_mem_writedata,
	avl_mem_readdata,
	avl_mem_readdatavalid,
	avl_mem_byteenable);	

	input		clk_clk;
	input		reset_reset_n;
	input	[5:0]	avl_csr_address;
	input		avl_csr_read;
	output	[31:0]	avl_csr_readdata;
	input		avl_csr_write;
	input	[31:0]	avl_csr_writedata;
	output		avl_csr_waitrequest;
	output		avl_csr_readdatavalid;
	input		avl_mem_write;
	input	[6:0]	avl_mem_burstcount;
	output		avl_mem_waitrequest;
	input		avl_mem_read;
	input	[18:0]	avl_mem_address;
	input	[31:0]	avl_mem_writedata;
	output	[31:0]	avl_mem_readdata;
	output		avl_mem_readdatavalid;
	input	[3:0]	avl_mem_byteenable;
endmodule
