	flasher u0 (
		.clk_clk               (<connected-to-clk_clk>),               //     clk.clk
		.reset_reset_n         (<connected-to-reset_reset_n>),         //   reset.reset_n
		.avl_csr_address       (<connected-to-avl_csr_address>),       // avl_csr.address
		.avl_csr_read          (<connected-to-avl_csr_read>),          //        .read
		.avl_csr_readdata      (<connected-to-avl_csr_readdata>),      //        .readdata
		.avl_csr_write         (<connected-to-avl_csr_write>),         //        .write
		.avl_csr_writedata     (<connected-to-avl_csr_writedata>),     //        .writedata
		.avl_csr_waitrequest   (<connected-to-avl_csr_waitrequest>),   //        .waitrequest
		.avl_csr_readdatavalid (<connected-to-avl_csr_readdatavalid>), //        .readdatavalid
		.avl_mem_write         (<connected-to-avl_mem_write>),         // avl_mem.write
		.avl_mem_burstcount    (<connected-to-avl_mem_burstcount>),    //        .burstcount
		.avl_mem_waitrequest   (<connected-to-avl_mem_waitrequest>),   //        .waitrequest
		.avl_mem_read          (<connected-to-avl_mem_read>),          //        .read
		.avl_mem_address       (<connected-to-avl_mem_address>),       //        .address
		.avl_mem_writedata     (<connected-to-avl_mem_writedata>),     //        .writedata
		.avl_mem_readdata      (<connected-to-avl_mem_readdata>),      //        .readdata
		.avl_mem_readdatavalid (<connected-to-avl_mem_readdatavalid>), //        .readdatavalid
		.avl_mem_byteenable    (<connected-to-avl_mem_byteenable>)     //        .byteenable
	);

