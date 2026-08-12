// dcfifo: 异步 FIFO, 写侧 wrclk 域, 读侧 rdclk 域
// 指针用格雷码跨时钟域传递, 双触发器同步, 消除亚稳态
// 读端口为寄存器输出: rdreq 弹出的数据下一拍才在 q 上有效 (仿真与综合时序一致)
// 综合为 M9K 简单双口 RAM, DEPTH 必须为 2 的幂

module dcfifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 1024
)(
    input  logic                  wrclk,
    input  logic                  rdclk,
    input  logic                  aclr,                // 异步复位, 高有效, 清空两侧指针
    input  logic [DATA_WIDTH-1:0] data,
    input  logic                  wrreq,
    output logic                  wrfull,
    input  logic                  rdreq,
    output logic                  rdempty,
    output logic [DATA_WIDTH-1:0] q
);

    localparam ADDR_WIDTH = $clog2(DEPTH);

//--------------------------------------------------
// RAM: 简单双口, 写 wrclk 域, 读 rdclk 域
//--------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [DEPTH-1:0];

//--------------------------------------------------
// 指针: 二进制, 多 1 位区分满/空, 跨域只传格雷码
//--------------------------------------------------
    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    wire [ADDR_WIDTH:0] wr_ptr_gray = wr_ptr ^ (wr_ptr >> 1);
    wire [ADDR_WIDTH:0] rd_ptr_gray = rd_ptr ^ (rd_ptr >> 1);

    reg [ADDR_WIDTH:0] rd_ptr_gray_sync1;
    reg [ADDR_WIDTH:0] rd_ptr_gray_sync2;   // rd_ptr 同步到 wrclk 域
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync1;
    reg [ADDR_WIDTH:0] wr_ptr_gray_sync2;   // wr_ptr 同步到 rdclk 域

//--------------------------------------------------
// 写侧: wrclk 域
//--------------------------------------------------
    always_ff @(posedge wrclk or posedge aclr) begin
        if (aclr) begin
            wr_ptr            <= '0;
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            if (wrreq && !wrfull) begin
                mem[wr_ptr[ADDR_WIDTH-1:0]] <= data;
                wr_ptr                      <= wr_ptr + 1'b1;
            end
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    wire [ADDR_WIDTH:0] wr_ptr_next      = wr_ptr + 1'b1;
    wire [ADDR_WIDTH:0] wr_ptr_next_gray = wr_ptr_next ^ (wr_ptr_next >> 1);

    // 满: 下一写使 wr_ptr 与 rd_ptr 相差一整圈 (格雷码高 2 位取反判满)
    assign wrfull = (wr_ptr_next_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                          rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});

//--------------------------------------------------
// 读侧: rdclk 域
//--------------------------------------------------
    always_ff @(posedge rdclk or posedge aclr) begin
        if (aclr) begin
            rd_ptr            <= '0;
            q                 <= '0;
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            if (rdreq && !rdempty) begin
                q      <= mem[rd_ptr[ADDR_WIDTH-1:0]];   // 本拍弹出的数据
                rd_ptr <= rd_ptr + 1'b1;
            end
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    assign rdempty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule
