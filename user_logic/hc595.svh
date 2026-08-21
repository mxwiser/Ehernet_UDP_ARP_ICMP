`ifndef HC_595_INTERFACE
`define HC_595_INTERFACE
interface hc595;
logic stcp;
logic shcp;
logic ser;
logic oen;
modport master(
    output stcp,
    output shcp,
    output ser,
    output oen
);


endinterface



`endif
