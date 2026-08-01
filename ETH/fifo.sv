// 同步 FIFO，可综合成 M9K
module fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH = 4096
)
(
    input  wire                  clock,
    input  wire                  rstn,
    input  wire [DATA_WIDTH-1:0] data,
    input  wire                  wrreq,
    input  wire                  rdreq,
    output wire                  empty,
    output wire                  full,
    output wire  [DATA_WIDTH-1:0] q
);


localparam ADDR_WIDTH = $clog2(DEPTH);


//--------------------------------------------------
// RAM
//--------------------------------------------------

reg [DATA_WIDTH-1:0] mem [DEPTH-1:0];
reg [DATA_WIDTH-1:0] qd;

//--------------------------------------------------
// pointer
//--------------------------------------------------
// 多1位用于判断full
//--------------------------------------------------
reg [ADDR_WIDTH:0] wr_ptr;
reg [ADDR_WIDTH:0] rd_ptr;



//--------------------------------------------------
// FIFO RAM
// Simple Dual Port RAM
//--------------------------------------------------
always @(posedge clock)
begin

    // write port
    if(wrreq && !full)
    begin
        mem[wr_ptr] <= data;
    end


    // read port
    if(rdreq && !empty)
    begin
        qd <= mem[rd_ptr];
    end

end

always_comb begin 
    q = rdreq ? qd : 0;
end



//--------------------------------------------------
// pointer control
//--------------------------------------------------
always @(posedge clock or negedge rstn)
begin

    if(!rstn)
    begin
        wr_ptr <= 0;
        rd_ptr <= 0;
    end else begin

        if(wrreq && !full)
        begin
            wr_ptr <= wr_ptr + 1'b1;
        end


        if(rdreq && !empty)
        begin
            rd_ptr <= rd_ptr + 1'b1;
        end

    end

end



//--------------------------------------------------
// status
//--------------------------------------------------
wire [ADDR_WIDTH:0] count;
assign count = (rd_ptr+DEPTH -wr_ptr)%DEPTH;
assign empty = (wr_ptr == rd_ptr)||(count==(DEPTH-1));


assign full = (count==1);



endmodule