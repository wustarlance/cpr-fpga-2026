`timescale 1ns/1ps
//=============================================================================
// wav_reader.v —— SD 扇区流 → PCM 帧流（重构版；旧版存档在 sim/wav_reader_before_refactor.v）
//-----------------------------------------------------------------------------
// 【本文件的结构来源】
// 状态机骨架、扇区请求握手、按字节计数的取数方式，全部照 bmp_read.v 的写法：
//
//   bmp_read                         本文件
//   ------------------------------   --------------------------------------
//   ST_IDLE / ST_SCAN / ST_LOAD_*    S_IDLE / S_SEC_ADDR / S_SEC_REQ / S_RECV
//   rd_cnt（扇区内 0..511 计数）      S_rd_cnt（同一个计数器，位宽名字都一样）
//   case(rd_cnt) 按偏移锁存字段      S_got 作索引，锁进 S_chunk / S_fmt
//   bmp_len_cnt（文件内字节计数）     W_rd_pos = {S_sec_off, S_rd_cnt}
//   pixel_offset（起始跳过）          S_pos（本次读的起点偏移）
//   bmp_len_cnt >= pixel_offset       W_rd_pos >= S_pos
//   file_len（头里给的文件长度）      S_remain（本次还要收多少字节）
//   header_match（魔数 + 字段组合）   W_id_is_fmt / W_id_is_data / W_riff_ok
//   sd_sec_read 电平 + end 收尾      完全一致
//   sd_sec_read_addr 递增            S_sec_off + 1
//
// 与 bmp_read 唯一的本质差别：WAV 的 data 块位置不是固定 54 字节，而是由前面
// 各 chunk 的 size 累加出来的。所以多了一个"块链定位"步骤（S_CHUNK / S_FMT_DEC），
// 其余全部沿用。
//
// 【和旧版相比删掉的东西】（下面第一项在本文件里已不存在，搜 S_hdr_ram 搜不到就是对的）
//   * 【已删除】1024 字节头部 RAM（S_hdr_ram）以及围绕它的 4 个状态
//     （S_SEEK/S_RD_ADDR/S_RD_WAIT/S_RD_CAP）——bmp_read 不需要缓存整个扇区，
//     只要在字节流里"数到目标位置再锁存"就够了，WAV 同样可以。
//     现在只留 46 字节字段锁存：S_riff[0:11] / S_chunk[0:7] / S_fmt[0:25]，
//     按 S_got 逐个字节写、按固定下标读，不是整扇区窗口。
//   * 【未删除】32 拍串行除法器（S_CALC_DIV）与 O_frame_total 都还在：
//     pcm_player 用 O_frame_total（I_frame_total）判"播完"，删了就没法自动结束。
//
// 【格式支持】
//   PCM(1) / WAVE_FORMAT_EXTENSIBLE(0xFFFE，SubFormat GUID 必须是 PCM)，
//   8/16/24/32 bit，单/双声道，8k~192k。非 PCM 一律 ERR_FORMAT。
//   位深统一左对齐到 24 bit：8 bit 无符号取反高位；16 bit 左移 8；24 bit 原值；
//   32 bit 取高 24 位。
//=============================================================================
module wav_reader #(
    parameter integer WAIT_TIMEOUT_CYCLES = 100_000_000, // 单扇区无进展超时
    parameter [11:0]  SEC_MIN_SPACE       = 12'd512      // 发新请求所需的最小 FIFO 空间
)(
    input  wire        I_clk,
    input  wire        I_rst,

    /* ---- SD 扇区读接口（与 sd_card_top 直连） ---- */
    input  wire        I_sd_init_done,
    input  wire        I_sd_sec_ready,
    input  wire [7:0]  I_sd_sec_data,
    input  wire        I_sd_sec_valid,
    input  wire        I_sd_sec_end,
    input  wire        I_sd_sec_error,
    output reg  [31:0] O_sd_sec_addr,
    output reg         O_sd_sec_read,

    /* ---- 启动参数 ---- */
    input  wire        I_start,           // 单拍脉冲
    input  wire [31:0] I_start_sector,    // WAV 文件首扇区（顶层直接给，不扫卡）
    input  wire        I_abort,           // 中止本次读，回 IDLE
    input  wire        I_loop,            // 1 = 播完从头再来

    /* ---- PCM 输出（FIFO 写侧） ---- */
    output reg  [47:0] O_pcm_data,        // {R[23:0], L[23:0]}
    output reg         O_pcm_valid,       // 单拍
    input  wire [11:0] I_fifo_space,

    /* ---- 状态 ---- */
    output wire        O_busy,
    output reg         O_done,
    output reg         O_error,
    output reg  [3:0]  O_error_code,
    output reg  [3:0]  O_state_code,
    output reg         O_hdr_ready,

    /* ---- 解析结果 ---- */
    output reg  [31:0] O_file_size,
    output reg  [31:0] O_sample_rate,
    output reg  [15:0] O_channels,
    output reg  [15:0] O_bits,
    output reg  [31:0] O_data_bytes,
    output reg  [31:0] O_data_sector,
    output reg  [31:0] O_frame_total,

    /* ---- 诊断 ---- */
    output reg  [31:0] O_sector_cnt,
    output wire [31:0] O_frame_cnt
);

//--------------------------------------------------------------------------
// 错误码 / 状态
//--------------------------------------------------------------------------
localparam [3:0] ERR_NONE      = 4'd0;
localparam [3:0] ERR_SD        = 4'd1;   // SD 读错误 / 初始化丢失
localparam [3:0] ERR_TIMEOUT   = 4'd2;   // 扇区读完前长时间无进展
localparam [3:0] ERR_NOT_RIFF  = 4'd3;   // 不是 RIFF/WAVE
localparam [3:0] ERR_NO_FMT    = 4'd4;   // 头里没有可用的 fmt 块
localparam [3:0] ERR_NO_DATA   = 4'd5;   // 没有 data 块 / 长度为 0
localparam [3:0] ERR_FORMAT    = 4'd6;   // 编码/位深/声道/采样率不支持
localparam [3:0] ERR_SIZE      = 4'd7;   // 文件太短 / 长度不可信

localparam [3:0] S_IDLE     = 4'd0;
localparam [3:0] S_SEC_ADDR = 4'd1;      // 摆扇区地址（= bmp_read 进状态前的赋值）
localparam [3:0] S_SEC_REQ  = 4'd2;      // 拉 sd_sec_read
localparam [3:0] S_RECV     = 4'd3;      // 收字节（= bmp_read 的 ST_LOAD_DATA 主体）
localparam [3:0] S_DECIDE   = 4'd4;      // 一个目标收完，决定下一步
localparam [3:0] S_CHUNK    = 4'd5;      // 判块类型（第 1 拍：只把 size 的比较打成标志）
localparam [3:0] S_FMT_DEC  = 4'd6;      // 解析 fmt 内容
localparam [3:0] S_CALC     = 4'd7;      // 校验格式（第 1 拍：算校验结果）
localparam [3:0] S_CALC_DIV = 4'd8;      // 算总帧数（WAV 特有，bmp_read 不需要）
localparam [3:0] S_CALC2    = 4'd9;      // 校验格式（第 2 拍：只用第 1 拍的结果做动作）
localparam [3:0] S_DECIDE2  = 4'd10;     // 决定下一步（第 2 拍：只用打好的判据标志）
localparam [3:0] S_CHUNK2   = 4'd11;     // 判块类型（第 2 拍：只读标志，不再碰 S_chunk）

// 本阶段收到的字节往哪放
localparam [1:0] D_RIFF  = 2'd0;
localparam [1:0] D_CHUNK = 2'd1;
localparam [1:0] D_FMT   = 2'd2;
localparam [1:0] D_PCM   = 2'd3;

reg [3:0]  S_state;
reg [3:0]  S_err_code;
reg        S_err_pend;
wire       W_busy = (S_state != S_IDLE);

//--------------------------------------------------------------------------
// 文件位置 —— 全部对齐 bmp_read 的计数器用法
//--------------------------------------------------------------------------
reg [31:0] S_start_sector;
reg [31:0] S_sec_off;         // 当前扇区相对文件首扇区的偏移（= bmp_read 的 scan/load 递增量）
reg [9:0]  S_rd_cnt;          // 扇区内字节序号 0..511（= bmp_read 的 rd_cnt，一模一样）
reg [31:0] S_pos;             // 本次要读的起始偏移（= bmp_read 的 pixel_offset）
reg [31:0] S_remain;          // 本次还要收多少字节（= bmp_read 的 file_len 倒数版）
// S_remain 的"是否为零"单独存一位：/!\ 别再在 W_take 里写 (|S_remain)
// 32 位 OR 归约是 3 级 LUT，直接挂在 O_pcm_data / S_acc / S_frame_cnt_r 的写使能上，
// TD 实测这条链 9.8 ns（7 级，cell 只占 26%）。下面凡是 S_remain 赋值的地方都同步维护它。
reg        S_rem_z;           // 1 = S_remain 为 0
reg [4:0]  S_got;             // 本次已收几个（锁存索引）
reg [1:0]  S_dst;             // 收到的字节送到哪

// 当前正在读的字节在文件内的偏移：扇区偏移 << 9 | 扇区内序号。纯拼接，不进加法器。
wire [31:0] W_rd_pos = {S_sec_off[22:0], S_rd_cnt};

// 取数判据 W_rd_pos >= S_pos 原来是 32 位比较，直接挂在 W_take 上，
// 而 W_take 又挂在几乎所有数据寄存器的写使能上（TD 实测 9.5 ns / 7 级）。
// 拆法：扇区偏移和 S_pos 的高 23 位在一个扇区内都不变 → 在 S_SEC_ADDR 里比一次存成
// 两个标志；运行时只剩 10 位（扇区内序号 vs S_pos 低 9 位）的比较，3 级。
reg        S_hi_gt, S_hi_eq;   // S_sec_off > / == S_pos[31:9]
wire       W_arrived = S_hi_gt | (S_hi_eq & (S_rd_cnt >= S_pos[8:0]));

//--------------------------------------------------------------------------
// 头字段（等价 bmp_read 里那一排 header_0/file_len/width/...）
//--------------------------------------------------------------------------
reg [7:0]  S_riff [0:11];
reg [7:0]  S_chunk[0:7];
reg [7:0]  S_fmt  [0:25];

reg [31:0] S_file_size;
reg [31:0] S_data_off;
reg [31:0] S_data_len_raw;
reg [31:0] S_fmt_size;
reg        S_has_fmt;

//--------------------------------------------------------------------------
// 组帧
//--------------------------------------------------------------------------
reg [2:0]  S_bps;             // 每样本字节数
reg        S_stereo;
reg [2:0]  S_nb;
reg        S_smp;
reg [23:0] S_acc;
reg [23:0] S_s24;
reg [31:0] S_frame_cnt_r;

//--------------------------------------------------------------------------
// 看门狗：扇区读里长时间既无 valid 也无 end（S_SEC_ADDR 等 FIFO 属正常反压，排除）
//--------------------------------------------------------------------------
reg [31:0] S_wd;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) S_wd <= 32'd0;
    else if (!W_busy || I_sd_sec_valid || I_sd_sec_end || (S_state == S_SEC_ADDR))
        S_wd <= 32'd0;
    else if (S_wd < WAIT_TIMEOUT_CYCLES) S_wd <= S_wd + 32'd1;
end
// 超时标志打一拍再用：直接拿 W_timeout 去驱动整条状态机的写使能，
// 等于把 27 位比较器串进每一个寄存器的 CE（TD 实测 6 级 / 9.8 ns）。
// 寄存一拍后 CE 的输入就是触发器输出，比较器自己独占一个周期。
reg S_timeout;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) S_timeout <= 1'b0;
    else       S_timeout <= (S_wd >= WAIT_TIMEOUT_CYCLES - 1);
end

//--------------------------------------------------------------------------
// 全局"立刻退出"原因，同样打一拍再用
//
// 原来主状态机是
//     if (S_err_pend) … else if (I_abort && busy) … else if (!I_sd_init_done && busy) …
//     else if (S_timeout && busy) … else <正常>
// 这四级优先链会把三个条件（外加 `S_state != S_IDLE`）串进**每一个**寄存器的 CE，
// 再叠上各自分支里的判断，TD 实测 7 级 / 9.505 ns（cell 只占 25%，其余全是走线）。
// 现在把这条链压成一个 2 位寄存器，CE 上只剩一次 `S_stop != 0` 的判断。
//
// 语义完全不变，只是响应晚 1 拍——abort / 卡掉 / 超时都是毫秒级事件，
// 1 拍（10 ns）无影响；1 帧音频 20.8 µs。
//--------------------------------------------------------------------------
localparam [1:0] STOP_NONE = 2'd0,
                 STOP_ABORT = 2'd1,   // 用户 stop：不置错误码
                 STOP_SD    = 2'd2,   // 卡掉线：ERR_SD
                 STOP_TMO   = 2'd3;   // 读超时：ERR_TIMEOUT
reg [1:0] S_stop;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst)                  S_stop <= STOP_NONE;
    else if (S_state == S_IDLE) S_stop <= STOP_NONE;   // 回到 IDLE 就清，只作用 1 拍
    else if (I_abort)           S_stop <= STOP_ABORT;  // 与原来的优先级一致
    else if (!I_sd_init_done)   S_stop <= STOP_SD;
    else if (S_timeout)         S_stop <= STOP_TMO;
end

//--------------------------------------------------------------------------
// 组合判断（对应 bmp_read 的 header_match 那一块）
//--------------------------------------------------------------------------
// 取数条件：已经走到本次起点，且还有字节要收
// 四个判据全是触发器输出（S_state / I_sd_sec_valid 打的拍 / 两个零标志），
// 所以这里是 1~2 级，而不是原来的 7 级。
wire W_take = (S_state == S_RECV) && I_sd_sec_valid &&
              W_arrived && (!S_rem_z);

// 最后一个字节的判断不走减法器（TD 实测 (S_remain-1==0) 会多一条 32 位借位链）
wire W_last  = (S_remain == 32'd1) && W_take;
wire W_need0 = S_rem_z || W_last;

wire W_riff_ok = (S_riff[0] == "R") && (S_riff[1] == "I") &&
                 (S_riff[2] == "F") && (S_riff[3] == "F") &&
                 (S_riff[8] == "W") && (S_riff[9] == "A") &&
                 (S_riff[10]== "V") && (S_riff[11]== "E");
wire [31:0] W_file_size = {S_riff[7], S_riff[6], S_riff[5], S_riff[4]} + 32'd8;

wire W_id_is_fmt  = (S_chunk[0] == "f") && (S_chunk[1] == "m") &&
                    (S_chunk[2] == "t") && (S_chunk[3] == " ");
wire W_id_is_data = (S_chunk[0] == "d") && (S_chunk[1] == "a") &&
                    (S_chunk[2] == "t") && (S_chunk[3] == "a");

wire [31:0] W_chunk_size = {S_chunk[7], S_chunk[6], S_chunk[5], S_chunk[4]};
wire [31:0] W_next_pos   = S_pos + 32'd8 + W_chunk_size + {31'd0, W_chunk_size[0]};
// 注意：进这里时 S_pos 已经被 S_CHUNK 推到 fmt 体起点（块头 +8），
// 所以下一块位置只加 S_fmt_size，不能再加 8。
wire [31:0] W_fmt_next   = S_pos + S_fmt_size + {31'd0, S_fmt_size[0]};

wire [15:0] W_fmt_tag = {S_fmt[1],  S_fmt[0]};    // +0  wFormatTag
wire [15:0] W_fmt_sub = {S_fmt[25], S_fmt[24]};   // +24 SubFormat GUID 前 2 字节

//--------------------------------------------------------------------------
// 格式校验拆两拍用的组合量
//
// 原来 S_CALC 是 6 级 else-if：tag → sub → 声道 → 位深 → 采样率 → data 起点。
// 每条都要串进 S_dv_* 的写使能，TD 实测 9.481 ns（10 级）。
// 拆法：第 1 拍把"格式类"和 32 位比较的**高位**各算一次存进寄存器，
// 第 2 拍只做"拼一下 + 两个判断"，级数从 10 降到 3。
//--------------------------------------------------------------------------
// data_off >= file_size，拆成 3 段（高 16 位比较、高 16 位相等、低 16 位比较）
wire        W_off_hi_gt = (S_data_off[31:16] >  S_file_size[31:16]);
wire        W_off_hi_eq = (S_data_off[31:16] == S_file_size[31:16]);
wire        W_off_lo_ge = (S_data_off[15:0]  >= S_file_size[15:0]);
// 采样率范围：>192k 的素材用不到，所以只看低 18 位 + 高位全零
wire        W_rate_bad  = (|O_sample_rate[31:18]) ||
                          (O_sample_rate[17:0] < 18'd8000) ||
                          (O_sample_rate[17:0] > 18'd192000);

// 写成一条并行 OR（原来是一串 else-if，只为了选错误码，可错误码都是 ERR_FORMAT）
wire        W_fmt_bad   = ((W_fmt_tag != 16'h0001) && (W_fmt_tag != 16'hFFFE)) ||
                          ((W_fmt_tag  == 16'hFFFE) &&
                           ((S_fmt_size < 32'd40) || (W_fmt_sub != 16'h0001))) ||
                          ((O_channels != 16'd1) && (O_channels != 16'd2)) ||
                          ((O_bits != 16'd8)  && (O_bits != 16'd16) &&
                           (O_bits != 16'd24) && (O_bits != 16'd32)) ||
                          W_rate_bad;

reg  S_v_err;                 // 第 1 拍的格式校验结论
reg  S_cmp_hi_gt, S_cmp_hi_eq, S_cmp_lo_ge;
wire W_off_ge = S_cmp_hi_gt | (S_cmp_hi_eq & S_cmp_lo_ge);

// S_DECIDE 第 1 拍算好的判据（第 2 拍与 S_CHUNK 只读这些标志）
reg  S_riff_ok, S_is_data, S_is_fmt;

// S_CHUNK 第 1 拍算好的"块长度"判据（第 2 拍只读它们，不再碰 S_chunk）
reg  S_cs_zero, S_cs_lt16, S_cs_ge40, S_cs_huge;

// S_CHUNK 的防死循环判据 (S_pos >= S_file_size) 是 32 位比较，
// 它挂在 S_remain/S_pos 这些寄存器的写使能上，TD 实测 9.396 ns（10 级）。
// S_CHUNK 只从 S_DECIDE 进来，且那一拍 S_pos / S_file_size 都不动，
// 所以提前一拍算好存成 1 位，S_CHUNK 里只读寄存器。
reg  S_pos_ge_fs;

// data 有效长度 = min(声明长度, 文件剩余)
//
// 这一段原来是两级 32 位组合：W_avail = (file_size > data_off) ? file_size-data_off
// : data_len_raw;  W_dlen = min(data_len_raw, W_avail)。
// TD 实测它有 **9 条紧路径同时挂在 sd_clk 上**（上板网表前 10 名里占 9 条，
// 起点全是 O_file_size_reg[*]，slack 0.248~0.425 ns，7 级 ADDER×4 + fanout=32 的网
// 0.676 ns），因为 W_dlen 同时驱动 S_dv_n / O_data_bytes / S_remain 三组共 96 个触发器，
// 每人都要自带一套 32 位 mux。
//
// 拆法（不改时序语义，只多一组寄存器）：
//   S_CALC  拍：S_avail <= S_file_size - S_data_off      纯减法，扇出只到 32 个寄存器
//   S_CALC2 拍：S_dlen  <= min(S_data_len_raw, S_avail)  比较 + mux，输入已是寄存器
// 之后 S_dv_n / O_data_bytes / S_remain 一律读 S_dlen（寄存器），锥体消失。
// 顺带把原来那个 (file_size > data_off) 的三元也去掉了：S_CALC2 的 W_off_ge
// 已经保证 data_off < file_size 才走正常分支，减法结果就是可用字节数。
reg  [31:0] S_avail;          // file_size - data_off（S_CALC 里算好）
reg  [31:0] S_dlen;           // min(data_len_raw, S_avail)，解析头时锁一次
wire [31:0] W_min_dlen = (S_data_len_raw < S_avail) ? S_data_len_raw : S_avail;

//--------------------------------------------------------------------------
// 总帧数 = data 字节数 / 每帧字节数（WAV 特有，bmp_read 没有这一步）
//
// 24 bit 立体声的帧长是 6 字节，不是 2 的幂，移位算不了，所以用一个 32 拍的
// 串行移位减法器，只在解析头部时跑一次（此时还在等第一个数据扇区，
// 时间余量以微秒计）。结果给 pcm_player 判"播完"。
//--------------------------------------------------------------------------
reg [31:0] S_dv_n;
reg [31:0] S_dv_rem;
reg [31:0] S_dv_quo;
reg [4:0]  S_dv_d;
reg [5:0]  S_dv_cnt;

wire [3:0]  W_bps4     = (O_bits == 16'd8)  ? 4'd1 :
                         (O_bits == 16'd16) ? 4'd2 :
                         (O_bits == 16'd24) ? 4'd3 : 4'd4;
wire [4:0]  W_fb_bytes = (O_channels == 16'd2) ? {W_bps4, 1'b0} : {1'b0, W_bps4};

wire [31:0] W_dv_rem_sh = {S_dv_rem[30:0], S_dv_n[31]};
wire        W_dv_ge     = (W_dv_rem_sh >= {27'd0, S_dv_d});
wire [31:0] W_dv_rem_nx = W_dv_ge ? (W_dv_rem_sh - {27'd0, S_dv_d}) : W_dv_rem_sh;
wire [31:0] W_dv_quo_nx = {S_dv_quo[30:0], W_dv_ge};

// 字节 → 24 bit 左对齐样本（小端：acc = {新字节, acc[23:8]}）
wire [23:0] W_u8_to_s24 = {~I_sd_sec_data[7], I_sd_sec_data[6:0], 16'd0};
wire [23:0] W_acc_next  = {I_sd_sec_data, S_acc[23:8]};
wire [23:0] W_s24       = (S_bps == 3'd1) ? W_u8_to_s24 : W_acc_next;

//--------------------------------------------------------------------------
// 主状态机
//--------------------------------------------------------------------------
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_state        <= S_IDLE;
        S_err_code     <= ERR_NONE;
        S_err_pend     <= 1'b0;
        O_sd_sec_addr  <= 32'd0;
        O_sd_sec_read  <= 1'b0;
        O_pcm_data     <= 48'd0;
        O_pcm_valid    <= 1'b0;
        O_done         <= 1'b0;
        O_error        <= 1'b0;
        O_error_code   <= ERR_NONE;
        O_state_code   <= 4'd1;
        O_hdr_ready    <= 1'b0;
        O_file_size    <= 32'd0;
        O_sample_rate  <= 32'd0;
        O_channels     <= 16'd0;
        O_bits         <= 16'd0;
        O_data_bytes   <= 32'd0;
        O_data_sector  <= 32'd0;
        O_frame_total  <= 32'd0;
        O_sector_cnt   <= 32'd0;
        S_start_sector <= 32'd0;
        S_sec_off      <= 32'd0;
        S_rd_cnt       <= 10'd0;
        S_pos          <= 32'd0;
        S_remain       <= 32'd0;
        S_rem_z        <= 1'b1;
        S_got          <= 5'd0;
        S_dst          <= D_RIFF;
        S_file_size    <= 32'd0;
        S_data_off     <= 32'd0;
        S_data_len_raw <= 32'd0;
        S_fmt_size     <= 32'd0;
        S_has_fmt      <= 1'b0;
        S_bps          <= 3'd2;
        S_stereo       <= 1'b1;
        S_nb           <= 3'd0;
        S_smp          <= 1'b0;
        S_acc          <= 24'd0;
        S_s24          <= 24'd0;
        S_frame_cnt_r  <= 32'd0;
        S_dv_n         <= 32'd0;
        S_dv_rem       <= 32'd0;
        S_dv_quo       <= 32'd0;
        S_dv_d         <= 5'd2;
        S_dv_cnt       <= 6'd0;
        S_avail        <= 32'd0;
        S_dlen         <= 32'd0;
        S_v_err        <= 1'b0;
        S_cmp_hi_gt    <= 1'b0;
        S_cmp_hi_eq    <= 1'b0;
        S_cmp_lo_ge    <= 1'b0;
        S_pos_ge_fs    <= 1'b0;
        S_riff_ok      <= 1'b0;
        S_is_data      <= 1'b0;
        S_is_fmt       <= 1'b0;
        S_cs_zero      <= 1'b0;
        S_cs_lt16      <= 1'b0;
        S_cs_ge40      <= 1'b0;
        S_cs_huge      <= 1'b0;
        S_hi_gt        <= 1'b0;
        S_hi_eq        <= 1'b1;
    end
    else if (S_err_pend) begin
        O_error       <= 1'b1;
        O_error_code  <= S_err_code;
        O_state_code  <= 4'hE;
        O_sd_sec_read <= 1'b0;
        O_pcm_valid   <= 1'b0;
        S_err_pend    <= 1'b0;
        S_state       <= S_IDLE;
    end
    else begin
        O_done      <= 1'b0;
        O_pcm_valid <= 1'b0;

        // 用户"停止" / 卡被拔 / 读超时：都回到 IDLE。
        // 三种原因的判定已经在 S_stop 里做完（见上面的注释），这里只做动作，
        // 不再让三个条件串在所有寄存器的 CE 前面。
        if (S_stop != STOP_NONE) begin
            O_sd_sec_read <= 1'b0;
            O_pcm_valid   <= 1'b0;
            if (S_stop == STOP_ABORT) begin
                O_state_code <= 4'd1;
                S_err_pend   <= 1'b0;
            end
            else begin
                O_error      <= 1'b1;
                O_error_code <= (S_stop == STOP_SD) ? ERR_SD : ERR_TIMEOUT;
                O_state_code <= 4'hE;
            end
            S_state <= S_IDLE;
        end
        else begin
            //----------------------------------------------------------------
            // 字节 → 样本 → 帧：与状态机并行，只在数据阶段生效
            //----------------------------------------------------------------
            if (W_take && (S_dst == D_PCM)) begin
                if (S_nb == S_bps - 3'd1) begin
                    S_nb  <= 3'd0;
                    S_acc <= 24'd0;
                    if (S_stereo) begin
                        if (!S_smp) begin
                            S_s24 <= W_s24;            // 左声道先来
                            S_smp <= 1'b1;
                        end
                        else begin
                            O_pcm_data    <= {W_s24, S_s24};
                            O_pcm_valid   <= 1'b1;
                            S_frame_cnt_r <= S_frame_cnt_r + 32'd1;
                            S_smp         <= 1'b0;
                        end
                    end
                    else begin
                        O_pcm_data    <= {W_s24, W_s24};
                        O_pcm_valid   <= 1'b1;
                        S_frame_cnt_r <= S_frame_cnt_r + 32'd1;
                        S_smp         <= 1'b0;
                    end
                end
                else begin
                    S_nb  <= S_nb + 3'd1;
                    S_acc <= W_acc_next;
                end
            end

            //----------------------------------------------------------------
            case (S_state)
            //----------------------------------------------------------------
            S_IDLE: begin
                O_state_code  <= 4'd1;
                O_sd_sec_read <= 1'b0;
                if (I_start) begin
                    O_error        <= 1'b0;
                    O_error_code   <= ERR_NONE;
                    O_hdr_ready    <= 1'b0;
                    O_file_size    <= 32'd0;
                    O_sector_cnt   <= 32'd0;
                    S_frame_cnt_r  <= 32'd0;
                    S_start_sector <= I_start_sector;
                    S_file_size    <= 32'd0;
                    S_has_fmt      <= 1'b0;
                    S_nb           <= 3'd0;
                    S_smp          <= 1'b0;
                    S_acc          <= 24'd0;
                    S_pos          <= 32'd0;       // 先读文件第 0 字节
                    S_sec_off      <= 32'd0;
                    S_remain       <= 32'd12;      // "RIFF"+size+"WAVE"
                    S_rem_z        <= 1'b0;
                    S_got          <= 5'd0;
                    S_dst          <= D_RIFF;
                    if (I_start_sector == 32'd0) begin
                        S_err_pend <= 1'b1;
                        S_err_code <= ERR_SIZE;
                    end
                    else begin
                        S_state <= S_SEC_ADDR;
                    end
                end
            end

            // 摆地址：扇区偏移已在寄存器里稳定，这里只把扇区内序号归零
            S_SEC_ADDR: begin
                O_state_code <= (S_dst == D_PCM) ? 4'd4 : 4'd2;
                if ((S_dst != D_PCM) || (I_fifo_space >= SEC_MIN_SPACE)) begin
                    O_sd_sec_addr <= S_start_sector + S_sec_off;
                    S_hi_gt       <= (S_sec_off[22:0] >  S_pos[31:9]);
                    S_hi_eq       <= (S_sec_off[22:0] == S_pos[31:9]);
                    S_rd_cnt      <= 10'd0;
                    S_state       <= S_SEC_REQ;
                end
            end

            S_SEC_REQ: begin
                O_state_code <= (S_dst == D_PCM) ? 4'd4 : 4'd2;
                if (I_sd_sec_ready) begin
                    O_sd_sec_read <= 1'b1;
                    S_state       <= S_RECV;
                end
            end

            // 收字节：与 bmp_read 的 ST_LOAD_DATA 同构
            S_RECV: begin
                O_state_code <= (S_dst == D_PCM) ? 4'd4 : 4'd2;
                if (I_sd_sec_valid) begin
                    S_rd_cnt <= S_rd_cnt + 10'd1;
                    if (W_take) begin
                        S_remain <= S_remain - 32'd1;
                        S_rem_z  <= (S_remain == 32'd1);
                        S_got    <= S_got + 5'd1;
                        case (S_dst)
                            D_RIFF : if (S_got < 5'd12) S_riff[S_got[3:0]]     <= I_sd_sec_data;
                            D_CHUNK: if (S_got < 5'd8)  S_chunk[S_got[2:0]]    <= I_sd_sec_data;
                            D_FMT  : if (S_got < 5'd26) S_fmt[S_got]           <= I_sd_sec_data;
                            default: ;
                        endcase
                    end
                end

                if (I_sd_sec_error) begin
                    O_error       <= 1'b1;
                    O_error_code  <= ERR_SD;
                    O_state_code  <= 4'hE;
                    O_sd_sec_read <= 1'b0;
                    S_state       <= S_IDLE;
                end

                if (I_sd_sec_end) begin
                    O_sd_sec_read <= 1'b0;
                    O_sector_cnt  <= O_sector_cnt + 32'd1;

                    if (W_need0) begin
                        S_state <= S_DECIDE;
                    end
                    else begin
                        // 本扇区还没数到目标 / 目标跨扇区：顺延一个扇区
                        S_sec_off <= S_sec_off + 32'd1;
                        S_state <= S_SEC_ADDR;
                    end
                end
            end

            // 一个目标收完，决定下一步
            //
            // 拆两拍：这一拍只把"RIFF 校验 / 块 ID"这些字节比较打成标志。
            // 它们原来是 3~4 级（8 个字节逐个比 + 归约），直接挂在 S_remain / S_sec_off
            // 的写使能上，TD 实测 10.1 ns（7 级、走线 74%）。
            S_DECIDE: begin
                O_state_code <= 4'd3;
                S_riff_ok    <= W_riff_ok;
                S_is_data    <= W_id_is_data;
                S_is_fmt     <= W_id_is_fmt;
                S_state      <= S_DECIDE2;
            end

            // 第 2 拍：判据全是标志位，动作与原来一模一样
            S_DECIDE2: begin
                O_state_code <= 4'd3;
                case (S_dst)
                    D_RIFF: begin
                        // 头 12 字节到齐：校验 RIFF，并从 chunk size 算出文件长度
                        // （和 bmp_read 从 BMP 头里拿 file_len 是同一招）
                        if (!S_riff_ok) begin
                            S_err_pend <= 1'b1;
                            S_err_code <= ERR_NOT_RIFF;
                        end
                        else begin
                            S_file_size <= W_file_size;
                            O_file_size <= W_file_size;
                            S_pos       <= 32'd12;     // 块链从偏移 12 开始
                            S_sec_off   <= 32'd0;
                            S_remain    <= 32'd8;
                            S_rem_z     <= 1'b0;
                            S_got       <= 5'd0;
                            S_dst       <= D_CHUNK;
                            S_state     <= S_SEC_ADDR;
                        end
                    end

                    D_CHUNK: begin
                        // 提前一拍算好 S_CHUNK 的越界判据（S_pos 此刻不动）
                        S_pos_ge_fs <= (S_pos >= S_file_size);
                        S_state     <= S_CHUNK;
                    end

                    D_FMT: begin
                        O_channels    <= {S_fmt[3], S_fmt[2]};
                        O_sample_rate <= {S_fmt[7], S_fmt[6], S_fmt[5], S_fmt[4]};
                        O_bits        <= {S_fmt[15], S_fmt[14]};
                        S_has_fmt     <= 1'b1;
                        S_pos         <= W_fmt_next;
                        S_sec_off     <= W_fmt_next >> 9;
                        S_remain      <= 32'd8;
                        S_rem_z       <= 1'b0;
                        S_got         <= 5'd0;
                        S_dst         <= D_CHUNK;
                        S_state       <= S_SEC_ADDR;
                    end

                    default: begin  // D_PCM：data 播完
                        O_done <= 1'b1;
                        if (I_loop) begin
                            S_pos       <= S_data_off;
                            S_remain    <= O_data_bytes;
                            S_rem_z     <= (O_data_bytes == 32'd0);
                            S_sec_off   <= S_data_off >> 9;
                            S_nb        <= 3'd0;
                            S_smp       <= 1'b0;
                            S_acc       <= 24'd0;
                            S_state     <= S_SEC_ADDR;
                        end
                        else begin
                            S_remain <= 32'd0;
                            S_rem_z  <= 1'b1;
                            S_state  <= S_IDLE;
                        end
                    end
                endcase
            end

            // 判块类型
            //
            // 第 1 拍只把"块长度"的四个判据打成标志。原来这一拍里
            // W_chunk_size 的 (==0 / <16 / >=40 / 高 28 位全 1) 四个比较直接挂在
            // S_remain / S_fmt_size / S_pos 的写使能上，起点是 S_chunk 的 64 个触发器，
            // TD 实测 S_chunk[20] → S_remain[13].ce 是 9.383 ns / 7 级 / 走线 6.49 ns
            // （走线占 70%：判据要跨很远去够那 32 个触发器的 CE）。
            S_CHUNK: begin
                O_state_code <= 4'd3;
                S_cs_zero    <= (W_chunk_size == 32'd0);
                S_cs_lt16    <= (W_chunk_size <  32'd16);
                S_cs_ge40    <= (W_chunk_size >= 32'd40);
                S_cs_huge    <= (&W_chunk_size[31:4]);
                S_state      <= S_CHUNK2;
            end

            // 第 2 拍：判据全是标志位，动作与原来一一对应
            S_CHUNK2: begin
                O_state_code <= 4'd3;
                if (S_is_data) begin
                    if (!S_has_fmt) begin
                        S_err_pend <= 1'b1;
                        S_err_code <= ERR_NO_FMT;
                    end
                    else if (S_cs_zero) begin
                        // 声明长度为 0 的 data 块：判据只用拼接出来的 chunk 头，
                        // 不要放到 S_CALC 里跟 dlen 一起判（那条链要过两个
                        // 32 位比较 + 一个减法，TD 实测 10 级 / 13.2 ns）
                        S_err_pend <= 1'b1;
                        S_err_code <= ERR_NO_DATA;
                    end
                    else begin
                        S_data_off     <= S_pos + 32'd8;
                        S_data_len_raw <= W_chunk_size;
                        S_state        <= S_CALC;
                    end
                end
                else if (S_is_fmt) begin
                    // fmt 至少 16 字节；EXTENSIBLE 要读到 +25 拿 SubFormat GUID
                    if (S_cs_lt16) begin
                        S_err_pend <= 1'b1;
                        S_err_code <= ERR_NO_FMT;
                    end
                    else begin
                        S_fmt_size <= W_chunk_size;
                        S_pos      <= S_pos + 32'd8;
                        S_remain   <= S_cs_ge40 ? 32'd26 : 32'd16;
                        S_rem_z    <= 1'b0;
                        S_got      <= 5'd0;
                        S_dst      <= D_FMT;
                        S_state    <= S_SEC_ADDR;
                    end
                end
                else begin
                    // LIST / JUNK / fact / bext …：按 size 跳过去
                    // 防死循环的判据不能写 (W_next_pos <= S_pos)——那要把
                    // 3 个 32 位加法器的结果再接进比较器，再进 S_pos 的写使能，
                    // TD 实测 8 级 / 10.07 ns。改成"当前位置已越界"或"size 高
                    // 28 位全 1"两条都只看寄存器/拼接，完全绕开加法链。
                    if (S_pos_ge_fs || S_cs_huge) begin
                        S_err_pend <= 1'b1;
                        S_err_code <= ERR_NO_DATA;
                    end
                    else begin
                        S_pos    <= W_next_pos;
                        S_sec_off <= W_next_pos >> 9;
                        S_remain <= 32'd8;
                        S_rem_z  <= 1'b0;
                        S_got    <= 5'd0;
                        S_dst    <= D_CHUNK;
                        S_state  <= S_SEC_ADDR;
                    end
                end
            end

            // 定 data 起点 + 格式校验（第 1 拍：只算结论，不做分支动作）
            //
            // 这一拍把"格式对不对"和"data 起点越界"的 32 位比较高 16 位
            // 各算一次存进寄存器（见 W_fmt_bad / W_off_hi_gt 那一段注释）。
            S_CALC: begin
                O_state_code <= 4'd3;
                S_v_err      <= W_fmt_bad;
                S_cmp_hi_gt  <= W_off_hi_gt;
                S_cmp_hi_eq  <= W_off_hi_eq;
                S_cmp_lo_ge  <= W_off_lo_ge;
                S_avail      <= S_file_size - S_data_off;   // 32 位减法单独占一拍
                S_state      <= S_CALC2;
            end

            // 第 2 拍：判断只剩"两个寄存器位"，动作与原来一一对应
            S_CALC2: begin
                O_state_code <= 4'd3;
                if (S_v_err) begin
                    S_err_pend <= 1'b1;
                    S_err_code <= ERR_FORMAT;
                end
                else if (W_off_ge) begin
                    S_err_pend <= 1'b1;
                    S_err_code <= ERR_SIZE;
                end
                else begin
                    // 数据参数：dlen 在这里定死成一个寄存器，后面 96 个触发器
                    // 全读它，不再各自背一套 32 位 mux（见 W_min_dlen 上面的注释）。
                    S_dlen        <= W_min_dlen;
                    S_dv_n        <= W_min_dlen;
                    S_dv_rem      <= 32'd0;
                    S_dv_quo      <= 32'd0;
                    S_dv_d        <= W_fb_bytes;
                    S_dv_cnt      <= 6'd0;
                    S_state       <= S_CALC_DIV;
                end
            end

            // 总帧数 = data 字节数 / 每帧字节数（移位减法，32 拍）
            S_CALC_DIV: begin
                O_state_code <= 4'd3;
                S_dv_rem <= W_dv_rem_nx;
                S_dv_quo <= W_dv_quo_nx;
                S_dv_n   <= {S_dv_n[30:0], 1'b0};
                S_dv_cnt <= S_dv_cnt + 6'd1;
                if (S_dv_cnt == 6'd31) begin
                    // 写使能只看 S_dv_cnt，不再依赖 S_data_off 那条长链
                    O_frame_total <= W_dv_quo_nx;      // 最后一拍的商还没进寄存器
                    O_hdr_ready   <= 1'b1;
                    O_data_bytes  <= S_dlen;
                    O_data_sector <= S_start_sector + (S_data_off >> 9);
                    S_sec_off     <= S_data_off >> 9;
                    S_pos         <= S_data_off;
                    S_remain      <= S_dlen;
                    S_rem_z       <= 1'b0;   // S_dlen>0：chunk_size!=0 且 data_off<file_size 已校验
                    S_got         <= 5'd0;
                    S_dst         <= D_PCM;
                    S_nb          <= 3'd0;
                    S_smp         <= 1'b0;
                    S_acc         <= 24'd0;
                    S_stereo      <= (O_channels == 16'd2);
                    S_bps         <= (O_bits == 16'd8)  ? 3'd1 :
                                     (O_bits == 16'd16) ? 3'd2 :
                                     (O_bits == 16'd24) ? 3'd3 : 3'd4;
                    S_state       <= S_SEC_ADDR;
                end
            end

            default: begin
                S_state      <= S_IDLE;
                O_state_code <= 4'd1;
            end
            endcase
        end
    end
end

assign O_busy      = W_busy;
assign O_frame_cnt = S_frame_cnt_r;

endmodule
