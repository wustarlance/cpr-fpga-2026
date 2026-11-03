// BMP和WAV共用一个SD扇区读口，BMP请求优先。
// WAV请求及地址锁存在pending中，授权后owner保持至I_sd_end。
// valid/end只送给当前owner；未授权通道不接收返回数据。
// 持续BMP请求会延迟WAV服务，本模块未按音频FIFO水位仲裁。
module sd_sec_arbiter (
    input  wire        clk,
    input  wire        rst,

    /* ---- 上游：唯一的 sd_card_top ---- */
    input  wire        I_sd_ready,          // sd_card_top.sd_sec_ready
    output wire        O_sd_read,
    output wire [31:0] O_sd_addr,
    input  wire [7:0]  I_sd_data,
    input  wire        I_sd_valid,
    input  wire        I_sd_end,

    /* ---- ch0：BMP 画面（优先） ---- */
    output wire        O_ch0_ready,
    input  wire        I_ch0_read,
    input  wire [31:0] I_ch0_addr,
    output wire [7:0]  O_ch0_data,
    output wire        O_ch0_valid,
    output wire        O_ch0_end,

    /* ---- ch1：WAV 音频（让路） ---- */
    output wire        O_ch1_ready,
    input  wire        I_ch1_read,
    input  wire [31:0] I_ch1_addr,
    output wire [7:0]  O_ch1_data,
    output wire        O_ch1_valid,
    output wire        O_ch1_end
);

localparam [1:0] OWN_NONE = 2'd0;
localparam [1:0] OWN_BMP  = 2'd1;
localparam [1:0] OWN_WAV  = 2'd2;

reg  [1:0]  owner;
reg         wav_pend;
reg  [31:0] wav_addr_q;
reg         ch1_read_d;

wire idle = (owner == OWN_NONE);

// BMP直接发起。wav_fire必须排除同拍BMP请求，避免误清WAV pending。
wire bmp_fire = I_ch0_read && I_sd_ready && idle;

// WAV等待期间保存请求和地址，获准后再发送。
wire wav_fire = wav_pend && I_sd_ready && idle && !bmp_fire;

// WAV请求可保持到扇区结束，只在上升沿登记，避免结束后重复补发。
// 重复扇区的end可能截断下一次文件解析。
wire ch1_read_rise = I_ch1_read && !ch1_read_d;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wav_pend   <= 1'b0;
        wav_addr_q <= 32'd0;
        ch1_read_d <= 1'b0;
    end
    else begin
        ch1_read_d <= I_ch1_read;
        if (wav_fire) begin
            wav_pend   <= 1'b0;
        end
        else if (ch1_read_rise) begin
            wav_pend   <= 1'b1;
            wav_addr_q <= I_ch1_addr;
        end
        else if (!I_ch1_read) begin
            // 换曲abort撤销未发出的请求，避免旧扇区进入新解析。
            wav_pend   <= 1'b0;
        end
    end
end

assign O_sd_read = bmp_fire | wav_fire;
assign O_sd_addr = bmp_fire ? I_ch0_addr : wav_addr_q;

/* --------------------------------------------------------------------------
 * owner 锁：整扇区粒度，收到 end 才释放
 * -------------------------------------------------------------------------- */
always @(posedge clk or posedge rst) begin
    if (rst)
        owner <= OWN_NONE;
    else if (idle) begin
        if (bmp_fire)
            owner <= OWN_BMP;
        else if (wav_fire)
            owner <= OWN_WAV;
    end
    else if (I_sd_end)
        owner <= OWN_NONE;
end

// 总线空闲时BMP可请求；WAV还需等待BMP没有同拍请求。
assign O_ch0_ready = I_sd_ready && idle;
assign O_ch1_ready = I_sd_ready && idle && !I_ch0_read;

/* --------------------------------------------------------------------------
 * 数据分发：按 owner 门控，未授权方看不到任何字节
 * -------------------------------------------------------------------------- */
assign O_ch0_data  = I_sd_data;
assign O_ch0_valid = I_sd_valid && (owner == OWN_BMP);
assign O_ch0_end   = I_sd_end   && (owner == OWN_BMP);

assign O_ch1_data  = I_sd_data;
assign O_ch1_valid = I_sd_valid && (owner == OWN_WAV);
assign O_ch1_end   = I_sd_end   && (owner == OWN_WAV);

endmodule
