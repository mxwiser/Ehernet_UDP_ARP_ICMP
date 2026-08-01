//同步，可被综合成M9K
module fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH = 1024
)
(
    input  wire                  clock,
    input  wire                  rstn,
    input  wire [DATA_WIDTH-1:0] data,
    input  wire                  wrreq,
    input  wire                  rdreq,
    output wire                  empty,
    output wire                  full,
    output reg  [DATA_WIDTH-1:0] q
);


localparam ADDR_WIDTH = $clog2(DEPTH);


// RAM
reg [DATA_WIDTH-1:0] mem [DEPTH-1:0];


// pointer
reg [31:0] wr_ptr;
reg [31:0] rd_ptr;


// count
wire [31:0] count;


assign count = wr_ptr - rd_ptr;


// 状态

assign empty = (count == 0);

assign full  = (count == DEPTH);



always @(posedge clock or negedge rstn)
begin


    if (rstn==0) begin
        wr_ptr = 0;
        rd_ptr = 0;
        q      = 0;
    end else begin
        // 写FIFO

        if(wrreq && !full)
        begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= data;
            wr_ptr <= wr_ptr + 1'b1;
        end


        // 读FIFO

        if(rdreq && !empty)
        begin
            q <= mem[rd_ptr[ADDR_WIDTH-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
        end

    end
end




endmodule