`ifndef PC_HEAD_INTERFACE
`define PC_HEAD_INTERFACE
interface pc_head;

logic	[47:0]				pc_mac_addr;
logic	[31:0]				pc_ip_addr;
logic	[15:0]				pc_port;
logic	[15:0]				board_port;
modport master(
    output pc_mac_addr,
    output pc_ip_addr,
    output pc_port,
    output board_port
);
modport slave(
    input  pc_mac_addr,
    input  pc_ip_addr,
    input  pc_port,
    input  board_port
);

endinterface



`endif
