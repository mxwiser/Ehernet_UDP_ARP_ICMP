`ifndef AXIS_INTERFACE
`define AXIS_INTERFACE
interface axis #(
    parameter int BYTE_WIDTH = 1,
);
logic [BYTE_WIDTH*8-1:0] tdata;
logic                    tvalid;
logic                    tready;
logic                    tlast;
logic                    tuser;
logic [BYTE_WIDTH-1:0]   tkeep;
modport master(
    output tdata,
    output tvalid,
    input  tready,
    output tlast,
    output tuser
);
modport slave(
    input  tdata,
    input  tvalid,
    output tready,
    input  tlast,
    input  tuser
);

endinterface 



`endif //AXIS_INTERFACE