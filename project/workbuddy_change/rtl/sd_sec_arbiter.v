//=============================================================================
// sd_sec_arbiter.v —— SD 卡扇区读仲裁（BMP 画面 vs WAV 音频 共享一份 sd_card_top）
//-----------------------------------------------------------------------------
// 背景：
//   板卡只有一组 SD 引脚，物理上只能有一份 sd_card_top。原来的 sd_card_bmp
//   把 sd_card_top 缩在内部、独占引脚，导致 WAV 播放没有通道。
//   本模块把"一路 SD 控制器"拆成两个从通道：
//       ch0 = BMP 读图（画面刷新，突发但可等待）
//       ch1 = WAV 读音频（持续，FIFO 缓冲约 21 ms）
//
// 两边的接口语义完全一致（都来自 sd_card_bmp / wav_reader 的同构状态机）：
//   发起方在 ready=1 时把 read 拉高一拍，然后进入接收态，等 valid 逐字节收数，
//   收到 end 结束本次事务。
//
// 仲裁策略（关键设计决策）：
//   1. BMP 绝对优先。BMP 的 read 直接透传，不吸收、不延迟 —— 因为它一旦发出
//      read 就进入接收态，丢一次就会挂到 1 秒超时后报错重试。
//   2. WAV 的 read 被 pending 吸收。它在 S_RECV 状态纯等 valid/end、没有超时，
//      等到数据就能正常收完，所以可以安全地让路。
//   3. 事务粒度 = 整个扇区。一旦授权给某一方，锁定到 I_sd_end 才释放，
//      确保数据不会串到另一侧。
//   4. 最坏情况：切页时 BMP 连读 1800 个扇区（约 72 ms），WAV 会短暂欠载。
//      这是可接受的代价，且只在切页瞬间发生；平时 BMP 不读，WAV 独占总线。
//
// 数据分发：
//   valid / end 按 owner 门控后再送给对应通道，未被授权的一方看不到任何字节。
//=============================================================================
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

wire idle = (owner == OWN_NONE);

/* --------------------------------------------------------------------------
 * BMP 直接透传（绝对优先）
 *   必须先声明：wav_fire 要拿它做屏蔽，否则两者同拍为 1 时地址取 BMP 的，
 *   但 wav_pend 仍会被下面的 else-if 清掉 —— WAV 那次请求就凭空消失了。
 *   WAV 侧进 S_RECV 后只等 valid/end、没有超时，丢一次就永久卡死。
 * -------------------------------------------------------------------------- */
wire bmp_fire = I_ch0_read && I_sd_ready && idle;

/* --------------------------------------------------------------------------
 * WAV 请求吸收
 *   I_ch1_read 可能是"BMP 正占用"时发出的，必须锁存，否则这次请求永久丢失，
 *   WAV 侧会卡在接收态等不到 end。地址同时锁存，保证补发时地址仍然正确。
 * -------------------------------------------------------------------------- */
wire wav_fire = wav_pend && I_sd_ready && idle && !bmp_fire;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wav_pend   <= 1'b0;
        wav_addr_q <= 32'd0;
    end
    else begin
        if (I_ch1_read) begin
            wav_pend   <= 1'b1;
            wav_addr_q <= I_ch1_addr;
        end
        else if (wav_fire) begin
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

/* --------------------------------------------------------------------------
 * ready 分发
 *   BMP 永远先看到 ready；WAV 只在 BMP 此刻没有在发请求时才看到 ready，
 *   让 BMP 的"看 ready 就发 read"行为完全不受干扰。
 * -------------------------------------------------------------------------- */
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
