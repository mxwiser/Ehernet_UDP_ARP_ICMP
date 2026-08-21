`ifndef HC_595_INTERFACE
`define HC_595_INTERFACE
interface hc595;
logic stcp;
logic shcp;
logic ds;
logic oen;
modport master(
    output stcp,
    output shcp,
    output ds,
    output oen
);


endinterface



`endif
