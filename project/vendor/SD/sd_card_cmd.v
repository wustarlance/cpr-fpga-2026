
// SD命令与数据块的SPI传输，连接sd_card_sec_read_write和spi_master。
// 命令拆成6字节发送，等待R1及命令附带数据；读取块等待0xFE令牌，
// 接收512字节数据和2字节CRC。写块发送数据/CRC后检查响应并等待卡退出忙态。
// 初始化阶段CS保持高，发送11个0xFF（88个时钟）。
// 请求为电平，在S_WAIT采样；应答为单拍脉冲。
// 命令、令牌与SPI等待有超时保护，read_cancel用于中止读取。
module sd_card_cmd #(
    parameter integer TOKEN_TIMEOUT_CYCLES = 10_000_000,
    parameter integer SPI_TIMEOUT_CYCLES = 1_000_000
)(
    input                       read_cancel,
    output                      ready,
    output                      block_read_error,
    output                      spi_abort,
	input                       sys_clk,
	input                       rst,						  // 系统复位（异步、高有效）
	input[15:0]                 spi_clk_div,                  // SPI 时钟分频参数（由上层切换：初始化慢速 / 传数据快速）
	input                       cmd_req,                      // 命令请求（上层举起，本模块在 S_WAIT 采样）
	output                      cmd_req_ack,                  // 命令请求应答（结束一拍脉冲）
	output reg                  cmd_req_error,                // 命令出错（响应超时，或 R1 不是期望值）
	input[47:0]                 cmd,                          // 48 位命令：{命令号, 参数32位, CRC7+结束位}
	input[7:0]                  cmd_r1,                       // 期望收到的 R1 响应（初始化阶段 0x01，传数据阶段 0x00）
	input[15:0]                 cmd_data_len,                 // 本命令附带数据的字节数（CMD8 为 4，其余多为 0）
	input                       block_read_req,               // 扇区读请求（上层举起）
	output reg                  block_read_valid,             // 读到的字节有效（每字节一拍脉冲）
	output reg[7:0]             block_read_data,              // 读到的字节
	output                      block_read_req_ack,           // 扇区读应答（一个扇区读完，一拍）
	input                       block_write_req,              // 扇区写请求
	input[7:0]                  block_write_data,             // 待写入的字节（下一拍有效）
	output                      block_write_data_rd,          // 向上一级要下一个待写字节（一拍）
	output                      block_write_req_ack,          // 扇区写应答（一个扇区写完，一拍）
	output                      nCS_ctrl,                     // 片选控制（0 = 把 CS 拉低选中卡）
	output reg[15:0]            clk_div,                      // 送给 SPI 层的实际分频值
	output reg                  spi_wr_req,                   // 请求 SPI 层发一个字节（举起等 ack）
	input                       spi_wr_ack,                   // SPI 层发完了（一拍脉冲）
	output[7:0]                 spi_data_in,                  // 要发出去的字节
	input[7:0]                  spi_data_out                  // 同时收回来的字节（SPI 是全双工）
);
// 状态编号：0~8 连续，之后跳到 14~17（9~13 被跳过，属于原作者的编号习惯）
parameter S_IDLE         = 0;
parameter S_WAIT         = 1;
parameter S_INIT         = 2;
parameter S_CMD_PRE      = 3;
parameter S_CMD          = 4;
parameter S_CMD_DATA     = 5;
parameter S_READ_WAIT    = 6;
parameter S_READ         = 7;
parameter S_READ_ACK     = 8;
parameter S_WRITE_TOKEN  = 9;
parameter S_WRITE_DATA_0 = 10;
parameter S_WRITE_DATA_1 = 11;
parameter S_WRITE_CRC    = 12;
parameter S_WRITE_SUC    = 13;
parameter S_WRITE_BUSY   = 14;
parameter S_WRITE_ACK    = 15;
parameter S_ERR          = 16;
parameter S_END          = 17;
reg[4:0]                      state;
localparam S_READ_ERROR = 18;
localparam S_RECOVER = 19;
reg [31:0] token_wait;
reg [31:0] spi_wait;
reg [15:0] read_crc;
reg [7:0] received_crc_hi;
wire spi_active = spi_wr_req && state != S_WAIT && state != S_IDLE;
wire spi_timeout = spi_active && !spi_wr_ack &&
                   spi_wait >= SPI_TIMEOUT_CYCLES - 1;
assign ready = state == S_WAIT;
assign block_read_error = state == S_READ_ERROR;
assign spi_abort = (state == S_READ_ERROR) || (state == S_ERR) || read_cancel;

// CRC-16/CCITT, SD data convention: polynomial 0x1021, zero seed, MSB first.
function [15:0] crc16_byte;
    input [15:0] previous;
    input [7:0] value;
    reg [15:0] c;
    integer b;
    begin
        c = previous ^ {value,8'b0};
        for (b=0; b<8; b=b+1)
            c = c[15] ? (c << 1) ^ 16'h1021 : (c << 1);
        crc16_byte = c;
    end
endfunction
always @(posedge sys_clk or posedge rst) begin
    if (rst) begin token_wait<=0; spi_wait<=0; end
    else begin
        if (state != S_READ_WAIT) token_wait<=0;
        else if (token_wait < TOKEN_TIMEOUT_CYCLES) token_wait<=token_wait+1'b1;
        if (!spi_active || spi_wr_ack) spi_wait<=0;
        else if (spi_wait < SPI_TIMEOUT_CYCLES) spi_wait<=spi_wait+1'b1;
    end
end


reg                           CS_reg;                       // 片选寄存（1 = 不选中，0 = 选中）
reg[15:0]                     byte_cnt;                     // 字节计数：不同状态下含义不同（已发字节数 / 已收字节数）
reg[7:0]                      send_data;                    // 下一个要发的字节
wire[7:0]                     data_recv;                    // 刚从卡收到的字节
reg[9:0]                      wr_data_cnt;                  // 写模式下已发出的数据字节数

// ── 下面这 4 条是"完成"信号，都是"只高一拍"的脉冲（把某个状态直接当输出用）──
assign cmd_req_ack = (state == S_END);                      // 命令流程结束
assign block_read_req_ack = (state == S_READ_ACK) || (state == S_READ_ERROR);          // 一个扇区读完
assign block_write_req_ack= (state == S_WRITE_ACK);         // 一个扇区写完
assign block_write_data_rd = (state == S_WRITE_DATA_0);     // 该给下一个待写字节了
assign spi_data_in = send_data;
assign data_recv = spi_data_out;
assign nCS_ctrl = CS_reg;
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		CS_reg <= 1'b1;                                     // 复位后 CS 默认拉高（不选中）
		spi_wr_req <= 1'b0;
		byte_cnt <= 16'd0;
		clk_div <= 16'd0;
		send_data <= 8'hff;                                 // SPI 空闲时总发 0xFF
		state <= S_IDLE;
		cmd_req_error <= 1'b0;
		wr_data_cnt <= 10'd0;
        read_crc <= 0;
        received_crc_hi <= 0;
	end
    else if (read_cancel) begin
        state <= S_READ_ERROR;
        CS_reg <= 1;
        spi_wr_req <= 0;
        byte_cnt <= 0;
    end else if (spi_timeout && state != S_RECOVER) begin
        state <= (state == S_READ || state == S_READ_WAIT) ? S_READ_ERROR : S_ERR;
        CS_reg <= 1;
        spi_wr_req <= 0;
        byte_cnt <= 0;
    end else
		case(state)
			S_IDLE:
			begin
				state <= S_INIT;
				clk_div <= spi_clk_div;
				CS_reg <= 1'b1;                             // 注意：这里 CS 保持高
			end
			S_INIT:
			begin
				// 上电先空发 11 个字节 = 88 个时钟（规范要求 ≥74 个），
				// 且本状态不动 CS_reg，所以 CS 一直是高的 —— 正是规范要求的做法
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt >= 16'd10)                  // 0~10 共 11 个字节
					begin
						byte_cnt <= 16'd0;
						spi_wr_req <= 1'b0;
						state <= S_WAIT;
					end
					begin                                   // ⚠️ 这是个"裸 begin..end"块，无条件执行
						byte_cnt <= byte_cnt + 16'd1;       // （原作者写法，效果等于计数 +1）
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;                     // 空发 0xFF 产生时钟
				end
			end
			S_WAIT:
			begin
				cmd_req_error <= 1'b0;
				wr_data_cnt <= 10'd0;
				// 空闲等待：三种请求谁先来就走谁（只有电平，所以不用担心漏拍）
				if(cmd_req == 1'b1)
					state <= S_CMD_PRE;
				else if(block_read_req == 1'b1) begin
                    state <= S_READ_WAIT;
                    byte_cnt <= 0;
                    read_crc <= 0;
                end
				else if(block_write_req == 1'b1)
					state <= S_WRITE_TOKEN;
				clk_div <= spi_clk_div;
			end
			S_CMD_PRE:
			begin
				// 发命令之前先空发一个 0xFF：垫出几拍时钟，同时让 CS 回到高
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_CMD;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_CMD:
			begin
				if(spi_wr_ack == 1'b1)
				begin
					// 收字节的判断逻辑（三个分支顺序很重要）：
					//   ① 超时（发满 0xffff 个字节）或 收到了 bit7=0 但不是期望值 → 报错
					//   ② 收到期望的 R1 → 成功，按有无附带数据决定下一步
					//   ③ 其余（bit7=1，卡还没准备好）→ 继续等
					if((byte_cnt == 16'hffff) || (data_recv != cmd_r1 && data_recv[7] == 1'b0))
					begin
						state <= S_ERR;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else if(data_recv == cmd_r1)
					begin
						spi_wr_req <= 1'b0;
						if(cmd_data_len != 16'd0)
						begin
							state <= S_CMD_DATA;            // 这条命令还带数据
							byte_cnt <= 16'd0;
						end
						else
						begin
							state <= S_END;                 // 没有附带数据，直接结束
							byte_cnt <= 16'd0;
						end
					end
					else
						byte_cnt <=  byte_cnt + 16'd1;      // 卡还没响应，接着发 0xFF 等
				end
				else
				begin
					spi_wr_req <= 1'b1;
					CS_reg <= 1'b0;                         // ★ 发命令时把 CS 拉低（选中卡）
					// 把 48 位命令拆成 6 个字节依次发出
					if(byte_cnt == 16'd0)
						send_data <= (cmd[47:40] | 8'h40);  // ★ 首字节 = 0x40 | 命令号：
						                                    //   0x40 = 起始位0 + 传输位1，再拼 6 位命令号
					else if(byte_cnt == 16'd1)
						send_data <= cmd[39:32];            // 参数第 1 字节
					else if(byte_cnt == 16'd2)
						send_data <= cmd[31:24];            // 参数第 2 字节
					else if(byte_cnt == 16'd3)
						send_data <= cmd[23:16];            // 参数第 3 字节
					else if(byte_cnt == 16'd4)
						send_data <= cmd[15:8];             // 参数第 4 字节
					else if(byte_cnt == 16'd5)
						send_data <= cmd[7:0];              // CRC7 + 结束位
					else
						send_data <= 8'hff;                 // 命令发完，继续发 0xFF 等响应
				end
			end
			S_CMD_DATA:
			begin
				// 收发命令附带的数据（如 CMD8 的 4 字节），数量由 cmd_data_len 指定
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == cmd_data_len - 16'd1)
					begin
						state <= S_END;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
            S_READ_WAIT: begin
                // An accepted token wins on the deadline edge.
                if (spi_wr_ack && data_recv == 8'hfe) begin
                    spi_wr_req <= 0;
                    state <= S_READ;
                    byte_cnt <= 0;
                    read_crc <= 0;
                end else if ((spi_wr_ack && data_recv != 8'hff) ||
                             token_wait >= TOKEN_TIMEOUT_CYCLES-1) begin
                    state <= S_READ_ERROR;
                    CS_reg <= 1;
                    spi_wr_req <= 0;
                    byte_cnt <= 0;
                end else begin
                    spi_wr_req <= 1;
                    send_data <= 8'hff;
                end
            end
            S_READ: begin
                if (spi_wr_ack) begin
                    if (byte_cnt < 512) read_crc <= crc16_byte(read_crc, data_recv);
                    if (byte_cnt == 512) received_crc_hi <= data_recv;
                    if (byte_cnt == 513) begin
                        state <= ({received_crc_hi,data_recv} == read_crc) ? S_READ_ACK : S_READ_ERROR;
                        CS_reg <= 1;
                        spi_wr_req <= 0;
                        byte_cnt <= 0;
                    end else byte_cnt <= byte_cnt + 1'b1;
                end else begin
                    spi_wr_req <= 1;
                    send_data <= 8'hff;
                end
            end
            S_READ_ERROR: begin
                state <= S_RECOVER;
                CS_reg <= 1;
                spi_wr_req <= 0;
            end
            // Deselect and provide a complete dummy byte before accepting another
            // command. spi_abort resets an interrupted byte in the SPI engine.
            S_RECOVER: begin
                CS_reg <= 1;
                send_data <= 8'hff;
                if (spi_wr_ack || spi_timeout) begin
                    spi_wr_req <= 0;
                    state <= S_WAIT;
                end else spi_wr_req <= 1;
            end
			S_WRITE_TOKEN:
				// 写操作由主机先发起始令牌 0xFE（与读方向相反）
				if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;
					spi_wr_req <= 1'b0;
					byte_cnt <= 16'd0;  
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hfe;
				end
			S_WRITE_DATA_0:
			begin
				// 停一拍，让 block_write_data_rd 拉起，通知上层"给下一个字节"
				state <= S_WRITE_DATA_1;
				wr_data_cnt <= wr_data_cnt + 10'd1;
			end
			S_WRITE_DATA_1:
			begin
				if(spi_wr_ack == 1'b1 && wr_data_cnt == 10'd512)
				begin
					state <= S_WRITE_CRC;                   // 512 字节发完，接着发 CRC
					spi_wr_req <= 1'b0;
				end
				else if(spi_wr_ack == 1'b1)
				begin
					state <= S_WRITE_DATA_0;                // 还没发够，回去要下一个字节
					spi_wr_req <= 1'b0;
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= block_write_data;          // 把上层给的字节发出去
				end
			end
			S_WRITE_CRC:
			begin
				// 发 2 字节 CRC（SPI 模式下卡不检查，填 0xFF 即可）
				if(spi_wr_ack == 1'b1)
				begin
					if(byte_cnt == 16'd1)
					begin
						state <= S_WRITE_SUC;
						spi_wr_req <= 1'b0;
						byte_cnt <= 16'd0;
					end
					else
					begin
						byte_cnt <= byte_cnt + 16'd1;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_SUC :
			begin
				// 等卡的 Data Response：低 5 位 = 00101 表示"数据已接受"
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv[4:0] == 5'b00101)
					begin
						state <= S_WRITE_BUSY;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_WRITE_BUSY :
			begin
				// 卡正在写内部存储（MISO 被拉低表示 busy）；
				// 一直发 0xFF，直到收回的字节变回 0xFF 表示卡空闲了
				if(spi_wr_ack == 1'b1)
				begin
					if(data_recv == 8'hff)
					begin
						state <= S_WRITE_ACK;
						spi_wr_req <= 1'b0;
					end
				end
				else
				begin
					spi_wr_req <= 1'b1;
					send_data <= 8'hff;
				end
			end
			S_ERR:
			begin
				state <= S_END;                             // 报错也要走 S_END，好让上层收到 cmd_req_ack
				CS_reg <= 1'b1;
                spi_wr_req <= 0;
				cmd_req_error <= 1'b1;                      // 上层靠这个区分"成功结束"和"出错结束"
			end
			S_WRITE_ACK:
			begin
				state <= S_WAIT;                            // 这三种"结束态"都只停一拍，然后回空闲
			end
            S_READ_ACK: state <= S_RECOVER;
            S_END: state <= cmd_req_error ? S_RECOVER : S_WAIT;
			default:
				state <= S_IDLE;
		endcase
end
// 从收到的 514 字节里，只把前 512 字节当作数据打 valid（后 2 字节是 CRC）
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_valid <= 1'b0;
	else if(!read_cancel && !spi_timeout && state == S_READ && byte_cnt < 16'd512)          // 只在前 512 字节内放行
		block_read_valid <= spi_wr_ack;
	else
		block_read_valid <= 1'b0;
end

// 锁存读到的字节（与上面 valid 同一拍产生）
always@(posedge sys_clk or posedge rst)
begin
	if(rst == 1'b1)
		block_read_data <= 8'd0;
	else if(state == S_READ && spi_wr_ack == 1'b1)
		block_read_data <= data_recv;
end

endmodule
