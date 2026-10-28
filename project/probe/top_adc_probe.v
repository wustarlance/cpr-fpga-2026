`timescale 1ns/1ps
//=============================================================================
// top_adc_probe.v —— 按压盒标定专用探针（独立顶层，不参与正式工程）
//-----------------------------------------------------------------------------
// 为什么单独做一个：正式工程 `top_adc` 的 ADC 域 hold 余量只有 +0.003 ns，
// 往里加任何显示逻辑都会被 TD 判成 "Too much hold violation"（11 条异常路径
// 直接跳过），实测两次都构建失败。所以这里把 **ADC 链原样抽出来**：
//
//   50 MHz clk ── PLL_HDMI_AUDIO C2 ── 12.295082 MHz
//        └─ EG_PHY_ADC（CH1 = M10 = J2-35，VREF 内部 L11）
//             └─ cpr_sensor_path（和正式工程同一份：200 kSa/s、4 点均值、
//                                  FALLING_WITH_FORCE 归一化、峰值检测）
//                  ├─ raw_data   → 数码管右 4 位（十进制原始码值）
//                  └─ peak_value → 数码管左 4 位（最近一次按压的归一化峰值）
//
// 整条显示逻辑都在 clk（50 MHz）域，和 cpr_sensor_path 的 app_clk 同一个时钟，
// 没有额外跨域；设计只有几百 LUT，布局宽松，不会再挤坏 ADC 域。
//
// 数码管约定（共阳，位选高有效）：
//   左 4 位 = PEAK（归一化峰值，0..4095）
//   右 4 位 = LIVE（原始 ADC 码值 0..4095，空载接近 4095，压下变小）
// LED：LED1=音频 PLL 锁定  LED2=传感器故障  LED3=一次按压完成  LED4=有采样
//=============================================================================
module top_adc_probe (
    input  wire       clk,        // 50 MHz 晶振（R7）
    input  wire       rst_n,      // 复位键（A2），低有效
    output wire [7:0] seg_sel,
    output wire [7:0] seg_data,
    output wire [3:0] led
);

//-----------------------------------------------------------------------------
// 1) ADC 时钟：与正式工程同一份 PLL 配置（C2 = 12.295082 MHz）
//-----------------------------------------------------------------------------
wire audio_mclk_pll, audio_mclk, audio_lock;
wire clk_g;

PLL_HDMI_AUDIO u_audio_pll (
    .refclk   (clk),
    .reset    (1'b0),
    .extlock  (audio_lock),
    .clk0_out (),
    .clk1_out (),
    .clk2_out (audio_mclk_pll)     // IP 里只有 C0 走 BUFG，C2 出来是裸的
);

// 显式全局缓冲：50 MHz 直接驱动逻辑、PLL C2 直接驱动 ADC，两个时钟原来都不在
// 全局时钟网上（探针面积报告 #gclk = 0），ADC 很可能因此不出数据。
EG_LOGIC_BUFG u_adc_clk_buf (.i(audio_mclk_pll), .o(audio_mclk));
EG_LOGIC_BUFG u_sys_clk_buf (.i(clk),            .o(clk_g));

//-----------------------------------------------------------------------------
// 2) ADC 硬核原语：CH1(M10) + 内部 VREF(L11)
//-----------------------------------------------------------------------------
wire        adc_soc, adc_pd, adc_eoc;
wire [2:0]  adc_channel;
wire [11:0] adc_dout;

EG_PHY_ADC #(.CH4("ENABLE"), .VREF("ENABLE")) u_adc (
    .clk  (audio_mclk),
    .pd   (adc_pd),
    .s    (adc_channel),
    .soc  (adc_soc),
    .eoc  (adc_eoc),
    .dout (adc_dout)
);

//-----------------------------------------------------------------------------
// 2.5) 诊断：在 ADC 域按 EOC 直接抓一次 dout，不经过 adc_ctrl / mailbox。
//      左侧数码管显示这个"原始抓取"值，右侧显示正式链路的值：
//        左边 ≈ 3xxx、右边 0  → adc_ctrl 抓错拍（RTL 问题）
//        两边都是 0           → ADC 引脚上真的没有电压（接线/引脚问题）
//-----------------------------------------------------------------------------
reg [11:0] adc_dout_at_eoc;
always @(posedge audio_mclk or negedge rst_n) begin
    if (!rst_n)           adc_dout_at_eoc <= 12'd0;
    else if (adc_eoc)     adc_dout_at_eoc <= adc_dout;
end

// 慢速搬到显示域：值在两次转换之间是稳定的，1 Hz 取一次足够
reg [11:0] adc_dout_disp;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) adc_dout_disp <= 12'd0;
    else if (raw_cnt_tick) adc_dout_disp <= adc_dout_at_eoc;
end

//-----------------------------------------------------------------------------
// 3) 和正式工程完全相同的采样/归一化/峰值链路
//    参数与 top_tf_hdmi_audio.v 的默认值一致，标定出来的数可以直接搬过去。
//-----------------------------------------------------------------------------
wire        raw_valid, peak_event, sensor_fault;
wire [11:0] raw_data, peak_value;
wire [1:0]  peak_grade;

cpr_sensor_path #(
    .ADC_CLK_HZ       (12295082),
    .SAMPLE_HZ        (200000),
    .CHANNEL          (4),
    .RELEASE_BASELINE (12'd4095),
    .FALLING_WITH_FORCE (1),
    .FILTER_SHIFT     (2),
    .TRIGGER_LEVEL    (12'd150),
    .RELEASE_LEVEL    (12'd100),
    .TARGET_LOW       (12'd800),
    .TARGET_HIGH      (12'd1600)
) u_sensor (
    .adc_clk       (audio_mclk),
    .adc_rst_n     (rst_n),
    .app_clk       (clk_g),
    .app_rst_n     (rst_n),
    .adc_eoc       (adc_eoc),
    .adc_dout      (adc_dout),
    .adc_soc       (adc_soc),
    .adc_pd        (adc_pd),
    .adc_channel   (adc_channel),
    .enabled       (audio_lock),   // PLL 锁定后才开始采样，避免上电误报故障
    .clear_session (1'b0),
    .peak_event    (peak_event),
    .peak_grade    (peak_grade),
    .peak_value    (peak_value),
    .raw_valid     (raw_valid),
    .raw_data      (raw_data),
    .sensor_fault  (sensor_fault)
);

//-----------------------------------------------------------------------------
// 3.5) 对比通路：ADC 域按 EOC 直抓 dout（绕开 adc_ctrl/mailbox），1 Hz 搬到显示域
//      左 4 位 = 这条直抓值；右 4 位 = 正式链路（adc_ctrl→mailbox）的 raw_data
//      左有数、右 0  → adc_ctrl 抓错拍（RTL 问题）
//      两边一致      → 链路没问题，读数小是接线（节点悬空）
//-----------------------------------------------------------------------------
reg [11:0] dbg_dout_raw;
reg [11:0] dbg_dout_disp;
always @(posedge audio_mclk or negedge rst_n) begin
    if (!rst_n)       dbg_dout_raw <= 12'd0;
    else if (adc_eoc) dbg_dout_raw <= adc_dout;
end
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n)            dbg_dout_disp <= 12'd0;
    else if (raw_cnt_tick) dbg_dout_disp <= dbg_dout_raw;
end

//-----------------------------------------------------------------------------
// 4) 十进制转换：时钟化 double-dabble（每拍一位，12 拍一次，约 30 LUT）
//    live / peak 交替转换，48 拍一轮（50 MHz 下 < 1 us），肉眼无感。
//-----------------------------------------------------------------------------
function [27:0] dd_step;
    input [27:0] v;
    reg [27:0] c;
    begin
        c = v;
        if (c[27:24] >= 4'd5) c[27:24] = c[27:24] + 4'd3;
        if (c[23:20] >= 4'd5) c[23:20] = c[23:20] + 4'd3;
        if (c[19:16] >= 4'd5) c[19:16] = c[19:16] + 4'd3;
        if (c[15:12] >= 4'd5) c[15:12] = c[15:12] + 4'd3;
        dd_step = c << 1;
    end
endfunction

reg        bcd_busy;
reg  [3:0] bcd_step;
reg [27:0] bcd_sh;
reg        bcd_sel;                  // 0 = live，1 = peak
reg [15:0] bcd_live_q, bcd_peak_q;

wire [11:0] bcd_src  = bcd_sel ? dbg_dout_disp : raw_data;
wire [27:0] bcd_next = dd_step(bcd_sh);

always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) begin
        bcd_busy <= 1'b0; bcd_step <= 4'd0; bcd_sh <= 28'd0; bcd_sel <= 1'b0;
        bcd_live_q <= 16'd0; bcd_peak_q <= 16'd0;
    end else if (!bcd_busy) begin
        bcd_sh   <= {16'd0, bcd_src};
        bcd_step <= 4'd0;
        bcd_busy <= 1'b1;
    end else begin
        bcd_sh   <= bcd_next;
        bcd_step <= bcd_step + 4'd1;
        if (bcd_step == 4'd11) begin
            bcd_busy <= 1'b0;
            if (bcd_sel) bcd_peak_q <= bcd_next[27:12];   // 现在是 EOC 直抓值
            else         bcd_live_q <= bcd_next[27:12];
            bcd_sel  <= ~bcd_sel;
        end
    end
end

//-----------------------------------------------------------------------------
// 4.5) 自检计数器（1 Hz）的十进制：直接维护 4 位 BCD，省一个转换器
//-----------------------------------------------------------------------------
reg [15:0] self_bcd;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) self_bcd <= 16'd0;
    else if (raw_cnt_tick) begin
        if (self_bcd[3:0] == 4'd9) begin
            self_bcd[3:0] <= 4'd0;
            if (self_bcd[7:4] == 4'd9) begin
                self_bcd[7:4] <= 4'd0;
                if (self_bcd[11:8] == 4'd9) begin
                    self_bcd[11:8] <= 4'd0;
                    self_bcd[15:12] <= (self_bcd[15:12] == 4'd9) ? 4'd0 : self_bcd[15:12] + 4'd1;
                end else self_bcd[11:8] <= self_bcd[11:8] + 4'd1;
            end else self_bcd[7:4] <= self_bcd[7:4] + 4'd1;
        end else self_bcd[3:0] <= self_bcd[3:0] + 4'd1;
    end
end

//-----------------------------------------------------------------------------
// 5) 七段码 + 动态扫描：左 4 位峰值，右 4 位实时
//-----------------------------------------------------------------------------
function [6:0] seg7;
    input [3:0] d;
    begin
        case (d)
            4'd0: seg7 = 7'b100_0000; 4'd1: seg7 = 7'b111_1001;
            4'd2: seg7 = 7'b010_0100; 4'd3: seg7 = 7'b011_0000;
            4'd4: seg7 = 7'b001_1001; 4'd5: seg7 = 7'b001_0010;
            4'd6: seg7 = 7'b000_0010; 4'd7: seg7 = 7'b111_1000;
            4'd8: seg7 = 7'b000_0000; 4'd9: seg7 = 7'b001_0000;
            default: seg7 = 7'b111_1111;
        endcase
    end
endfunction

cpr_seg_scan #(.CLK_FREQ(50_000_000)) u_seg_scan (
    .clk     (clk_g),
    .rst_n   (rst_n),
    .seg_sel (seg_sel),
    .seg_data(seg_data),
    .digit0  ({1'b1, seg7(bcd_peak_q[15:12])}),   // 左 4 位 = EOC 直抓的 adc_dout
    .digit1  ({1'b1, seg7(bcd_peak_q[11:8])}),
    .digit2  ({1'b1, seg7(bcd_peak_q[7:4])}),
    .digit3  ({1'b1, seg7(bcd_peak_q[3:0])}),
    .digit4  ({1'b1, seg7(bcd_live_q[15:12])}),
    .digit5  ({1'b1, seg7(bcd_live_q[11:8])}),
    .digit6  ({1'b1, seg7(bcd_live_q[7:4])}),
    .digit7  ({1'b1, seg7(bcd_live_q[3:0])})
);

//-----------------------------------------------------------------------------
// 6) 板载 LED 当状态灯：锁定 / 故障 / 一次按压完成 / 有采样
//-----------------------------------------------------------------------------
// 一次按压完成 → 亮 100 ms（50 MHz 下 5,000,000 拍），肉眼可见
localparam integer BLINK_CYCLES = 5_000_000;
reg [22:0] blink_cnt;
// 2 秒自动切换：右 4 位在 [实时 ADC 码值] 和 [自检计数] 之间轮换。
// 不依赖任何按键，看数码管就能同时判断"显示通路"和"ADC 数据"两条线。
reg        alt_mode;      // 0 = 实时码值，1 = 自检计数
reg [26:0] alt_div;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) begin
        alt_mode <= 1'b0;
        alt_div  <= 27'd0;
    end else if (alt_div == 27'd99_999_999) begin    // 2 s @50 MHz
        alt_div  <= 27'd0;
        alt_mode <= ~alt_mode;
    end else begin
        alt_div  <= alt_div + 27'd1;
    end
end

// 1 Hz tick：50,000,000 拍一个脉冲（给自检 BCD 加 1）
reg [25:0] sec_div;
reg        raw_cnt_tick;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) begin
        sec_div      <= 26'd0;
        raw_cnt_tick <= 1'b0;
    end else if (sec_div == 26'd49_999_999) begin
        sec_div      <= 26'd0;
        raw_cnt_tick <= 1'b1;
    end else begin
        sec_div      <= sec_div + 26'd1;
        raw_cnt_tick <= 1'b0;
    end
end

// mailbox 是否真的在送样本（raw_valid 只有一拍，拉长到 ~10 ms 才看得见）
reg [18:0] raw_stretch;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n)                    raw_stretch <= 19'd0;
    else if (raw_valid)            raw_stretch <= 19'h3FFFF;
    else if (raw_stretch != 19'd0) raw_stretch <= raw_stretch - 19'd1;
end

reg        peak_blink;

// 1 Hz 心跳：证明 50 MHz 时钟在跑（数码管扫描同样依赖它）
reg [24:0] hb_cnt;
reg        heartbeat;
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) begin hb_cnt <= 25'd0; heartbeat <= 1'b0; end
    else if (hb_cnt == 25'd24_999_999) begin hb_cnt <= 25'd0; heartbeat <= ~heartbeat; end
    else hb_cnt <= hb_cnt + 25'd1;
end

// EOC 活动：ADC 每完成一次转换会出一拍 eoc，用它点亮 LED2 表示"ADC 在转换"
reg [19:0] eoc_stretch;
always @(posedge audio_mclk or negedge rst_n) begin
    if (!rst_n)                    eoc_stretch <= 20'd0;
    else if (adc_eoc)              eoc_stretch <= 20'hF_FFFF;   // 约 85 ms
    else if (eoc_stretch != 20'd0) eoc_stretch <= eoc_stretch - 20'd1;
end
always @(posedge clk_g or negedge rst_n) begin
    if (!rst_n) begin
        blink_cnt  <= 23'd0;
        peak_blink <= 1'b0;
    end else if (peak_event) begin
        blink_cnt  <= BLINK_CYCLES[22:0];
        peak_blink <= 1'b1;
    end else if (blink_cnt != 23'd0) begin
        blink_cnt  <= blink_cnt - 23'd1;
        peak_blink <= 1'b1;
    end else begin
        peak_blink <= 1'b0;
    end
end

assign led[0] = audio_lock;                 // LED1：PLL 锁定（必须亮）
assign led[1] = (eoc_stretch != 20'd0);     // LED2：ADC 在转换（应亮/闪）
assign led[2] = heartbeat;                  // LED3：1 Hz 心跳
assign led[3] = (raw_stretch != 19'd0) | peak_blink;  // LED4：mailbox 在送样本

endmodule
