`ifndef RMII_INTERFACE
`define RMII_INTERFACE
interface rmii(
    input clk50m, crs_dv,
    output mdc, txen,
    inout mdio,
    output [1:0] txd,
    input [1:0] rxd
);

modport fpga_side(
    input  clk50m, rxd, crs_dv,
    output txd, txen, mdc,
    inout  mdio
);

endinterface //rmii
`endif //RMII_INTERFACE