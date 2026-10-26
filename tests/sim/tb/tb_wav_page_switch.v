`timescale 1ns/1ps
//=============================================================================
// tb_wav_page_switch.v —— 换页换曲的集成回归
//-----------------------------------------------------------------------------
// 场景来自上板实测：连续换过四首歌之后，再前进/后退到某一张照片对应的歌，
// 音乐会"卡"在那一首上，之后换图不再换曲。
//
// 做法：给 wav_audio_sd_top 接一个合成 SD 卡（4 段 48k/16bit/立体声 WAV，
// 每段的样本值是各自唯一的常量），按"前进/后退"的节奏改 I_audio_sel，
// 每一步都从 HDMI 音频口读回当前样本，判断是否换成了目标那一首。
//
// 判定：每一步之后限时内必须出现目标曲目的样本值；否则报 FAIL 并打印
// 当时的状态码 / 播放位置 / FIFO 水位。
//
// 2026-10-26 补的那一段（原来 ch0 接 1'b0，"BMP 通道空着"）：换页的同时给
// ch0 喂 4 ms 的读图突发（实测 776 个扇区），把 SD 总线占住。上板就是这样：
// 手指一按换页，画面立刻连读上千扇区，WAV 的读请求只能挂在仲裁器里；挂起的
// 请求一旦跨过 abort，就会在 BMP 让出总线后补发一整扇区、撞进新曲目的头部
// 解析，表现正是"图换了歌不换"。这条在把仲裁器改回电平触发时会必挂
// （state=1 err=1 ecode=3 pos=0，40 ms 内听不到新曲目），已做过反证。
//
// 最后一段验训练模式的音频口二选一：I_heart_en=1 时输出必须是心跳
// （|样本| 远大于 WAV 那点 0x0100*k），I_heart_en=0 时立刻回到该页 WAV。
// 顺带验两件事（2026-10-26 新增）：
//   * 训练期间 I_play 被压 0（顶层 wav_play_gate 就是这么接的）：
//     O_play_pos 必须冻住 —— 说明真的没在读卡、位置也没丢；
//   * 退出训练后 I_play 回 1，音频口立刻回到当前页的 WAV（断点续播）。
//=============================================================================
module tb_wav_page_switch;

    /* ---------------- 时钟 ---------------- */
    reg sd_clk = 0;   always #5.0    sd_clk = ~sd_clk;    // 100 MHz
    reg mclk   = 0;   always #40.690 mclk   = ~mclk;      // 12.288 MHz
    reg vclk   = 0;   always #19.860 vclk   = ~vclk;      // 25.175 MHz

    /* ---------------- 复位 / 控制 ---------------- */
    reg sd_rst = 1, m_rst = 1, v_rst = 1;
    reg [2:0] sel = 3'd0;                              // 选曲码：0..3 页，4 = FREE_SONG
    reg       play = 1'b1, stop = 1'b0, mute = 1'b0, loop_en = 1'b1;
    reg       heart_en = 1'b0;          // 音频口 2:1 选择：0 = 该页 WAV，1 = 心跳

    wire        bmp_ready;
    wire        bmp_read;
    reg  [31:0] bmp_addr   = 32'd100;      // 图区 LBA，与四段 WAV 不重叠
    wire [7:0]  bmp_data;
    wire        bmp_valid, bmp_end;

    /* ---------------- DUT ---------------- */
    wire [31:0] wav_addr;
    wire        wav_read;
    wire [7:0]  wav_data;
    wire        wav_valid, wav_end, wav_sec_ready;

    // 仲裁器（BMP 通道在本 TB 里空着，只走 WAV 一路，但保留真实互锁）
    wire        sd_read;
    wire [31:0] sd_addr;
    reg         sd_ready;
    reg  [7:0]  sd_data;
    reg         sd_valid, sd_end;

    wire        audio_valid;
    wire [23:0] audio_l, audio_r;
    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;
    wire        wav_ready, wav_error;
    wire [3:0]  wav_ecode, wav_state;
    wire [31:0] file_size, sample_rate, frame_total, play_pos;
    wire [15:0] channels, bits;
    wire        play_end, underrun;
    wire [10:0] buf_level;

    wav_audio_sd_top #(.ACR_N(6144)) dut (
        .I_sd_clk        (sd_clk),
        .I_mclk          (mclk),
        .I_video_clk     (vclk),
        .I_sd_rst        (sd_rst),
        .I_mclk_rst      (m_rst),
        .I_video_rst     (v_rst),
        .I_audio_sel     (sel),          // 3 bit：0..3 页，4 = FREE_SONG
        .I_play          (play),
        .I_stop          (stop),
        .I_mute          (mute),
        .I_loop          (loop_en),
        .I_heart_en      (heart_en),      // 音频口 2:1 选择（末尾一段专门验它）
        .I_sd_init_done  (1'b1),
        .I_sd_sec_ready  (wav_sec_ready),
        .O_sd_sec_addr   (wav_addr),
        .O_sd_sec_read   (wav_read),
        .I_sd_sec_data   (wav_data),
        .I_sd_sec_valid  (wav_valid),
        .I_sd_sec_end    (wav_end),
        .O_audio_valid      (audio_valid),
        .O_audio_left_data  (audio_l),
        .O_audio_right_data (audio_r),
        .O_acr_valid        (acr_valid),
        .O_acr_cts          (acr_cts),
        .O_acr_n            (acr_n),
        .O_wav_ready      (wav_ready),
        .O_wav_error      (wav_error),
        .O_wav_error_code (wav_ecode),
        .O_wav_state      (wav_state),
        .O_file_size      (file_size),
        .O_sample_rate    (sample_rate),
        .O_channels       (channels),
        .O_bits           (bits),
        .O_frame_total    (frame_total),
        .O_play_pos       (play_pos),
        .O_play_end       (play_end),
        .O_buf_level      (buf_level),
        .O_underrun       (underrun)
    );

    sd_sec_arbiter u_arb (
        .clk         (sd_clk),
        .rst         (sd_rst),
        .I_sd_ready  (sd_ready),
        .O_sd_read   (sd_read),
        .O_sd_addr   (sd_addr),
        .I_sd_data   (sd_data),
        .I_sd_valid  (sd_valid),
        .I_sd_end    (sd_end),
        .O_ch0_ready (bmp_ready),
        .I_ch0_read  (bmp_read),
        .I_ch0_addr  (bmp_addr),
        .O_ch0_data  (bmp_data),
        .O_ch0_valid (bmp_valid),
        .O_ch0_end   (bmp_end),
        .O_ch1_ready (wav_sec_ready),
        .I_ch1_read  (wav_read),
        .I_ch1_addr  (wav_addr),
        .O_ch1_data  (wav_data),
        .O_ch1_valid (wav_valid),
        .O_ch1_end   (wav_end)
    );

    /*=========================================================================
     * 合成 SD 卡：4 段 WAV
     *=======================================================================*/
    localparam integer NTRACK = 5;                 // 4 页 + 第 5 段 FREE_SONG
    localparam integer DLEN   = 4096;              // data 4096 B = 1024 帧 @48k/16bit/stereo
    localparam integer TOTAL  = 44 + DLEN;         // 4140 B = 9 个扇区
    localparam integer PSEC   = 9;                 // 每段占 9 个扇区
    localparam integer PERIOD = 8192;              // 数组槽宽

    localparam [31:0] BASE0 = 32'd12000;
    localparam [31:0] BASE1 = 32'd123000;
    localparam [31:0] BASE2 = 32'd250000;
    localparam [31:0] BASE3 = 32'd370000;
    localparam [31:0] BASE4 = 32'd500000;           // 与 wav_track_select 的默认值一致

    reg [7:0] rom [0:NTRACK*PERIOD-1];

    task put32(input integer t, input integer off, input [31:0] v);
        begin
            rom[t*PERIOD + off + 0] = v[7:0];
            rom[t*PERIOD + off + 1] = v[15:8];
            rom[t*PERIOD + off + 2] = v[23:16];
            rom[t*PERIOD + off + 3] = v[31:24];
        end
    endtask

    task put16(input integer t, input integer off, input [15:0] v);
        begin
            rom[t*PERIOD + off + 0] = v[7:0];
            rom[t*PERIOD + off + 1] = v[15:8];
        end
    endtask

    integer k, i;
    initial begin
        for (k = 0; k < NTRACK*PERIOD; k = k + 1) rom[k] = 8'h00;
        for (k = 0; k < NTRACK; k = k + 1) begin
            put32(k,  0, 32'h46464952);            // "RIFF"
            put32(k,  4, 32'd36 + DLEN);           // 文件长度 - 8
            put32(k,  8, 32'h45564157);            // "WAVE"
            put32(k, 12, 32'h20746D66);            // "fmt "
            put32(k, 16, 32'd16);                  // fmt 块长
            put16(k, 20, 16'd1);                   // PCM
            put16(k, 22, 16'd2);                   // 2 声道
            put32(k, 24, 32'd48000);
            put32(k, 28, 32'd48000 * 4);           // byte rate
            put16(k, 32, 16'd4);                   // block align
            put16(k, 34, 16'd16);                  // 16 bit
            put32(k, 36, 32'h61746164);            // "data"
            put32(k, 40, DLEN);
            // 每帧：L = 0x0100*(k+1)，R 取反（只为区分，不参与判定）
            for (i = 0; i < DLEN; i = i + 4) begin
                put16(k, 44 + i,     16'h0100 * (k + 1));
                put16(k, 44 + i + 2, 16'h0100 * (k + 1));
            end
        end
    end

    // 扇区地址 → 字节（越界返回 0，模拟卡上后续都是空白）
    function [7:0] sector_byte(input [31:0] addr, input integer offs);
        integer t, idx;
        reg [31:0] base;
        begin
            t    = 0;
            base = BASE0;
            if      (addr >= BASE4 && addr < BASE4 + PSEC) begin t = 4; base = BASE4; end
            else if (addr >= BASE3 && addr < BASE3 + PSEC) begin t = 3; base = BASE3; end
            else if (addr >= BASE2 && addr < BASE2 + PSEC) begin t = 2; base = BASE2; end
            else if (addr >= BASE1 && addr < BASE1 + PSEC) begin t = 1; base = BASE1; end
            else if (addr >= BASE0 && addr < BASE0 + PSEC) begin t = 0; base = BASE0; end
            else begin
                t = 0; base = 32'hFFFF_FFFF;        // 不在任何一段里
            end
            idx = (addr - base) * 512 + offs;
            sector_byte = (base != 32'hFFFF_FFFF && idx < TOTAL) ? rom[t*PERIOD + idx] : 8'h00;
        end
    endfunction

    /* ---------------- 扇区字节流（同 sd_card_sec_read_write 的语义） ----------------
     * 关键点：O_sd_read 只是授权那一刻的 1 拍脉冲；一旦事务开始，512 字节和
     * 一个 end 必定发完，**不理会请求是否已经撤销**（vendor 状态机就是这样）。
     * 换页换曲的卡死正是栽在这个语义上，所以模型必须如实照抄。
     * ------------------------------------------------------------------------- */
    reg        xfer = 1'b0, fin = 1'b0;
    integer    xcnt = 0;
    reg [31:0] xaddr = 32'd0;

    initial begin
        sd_ready = 1'b1;
        sd_data  = 8'h00;
        sd_valid = 1'b0;
        sd_end   = 1'b0;
    end

    always @(posedge sd_clk) begin
        if (sd_rst) begin
            xfer <= 1'b0; fin <= 1'b0; xcnt <= 0;
            sd_valid <= 1'b0; sd_end <= 1'b0;
        end
        else begin
            sd_end <= 1'b0;
            if (fin) begin
                fin      <= 1'b0;
                sd_end   <= 1'b1;
                sd_valid <= 1'b0;
            end
            else if (!xfer) begin
                sd_valid <= 1'b0;
                if (sd_read) begin
                    xfer  <= 1'b1;
                    xcnt  <= 0;
                    xaddr <= sd_addr;
                end
            end
            else begin
                sd_valid <= 1'b1;
                sd_data  <= sector_byte(xaddr, xcnt);
                xcnt     <= xcnt + 1;
                if (xcnt == 511) begin
                    xfer <= 1'b0;
                    fin  <= 1'b1;
                end
            end
        end
    end

    /* ---------------- 音频口取样 ---------------- */
    reg [23:0] last_l = 24'hFFFFFF;
    always @(posedge vclk) if (audio_valid) last_l <= audio_l;

    function [23:0] want_l(input integer track);
        begin
            want_l = ({8'd0, 16'h0100 * track}) << 8;   // 16 bit 样本左对齐到 24 bit
        end
    endfunction

    integer errors = 0;
    integer steps  = 0;
    integer r;
    integer pos_train;
    integer t0 = 0;

    /*=========================================================================
     * BMP 读图通道（2026-10-26 新增）
     * ------------------------------------------------------------------------
     * 这里原来是 I_ch0_read(1'b0)、I_ch0_addr(32'd0) —— "BMP 通道空着"。
     * 于是一直没测到上板最容易出事的那种时序：换页那一刻，画面正在连读
     * 上千个扇区把 SD 总线占住，WAV 的读请求只能挂起在仲裁器里。
     * 挂起的请求一旦跨过 abort（换曲），就是"换图了音乐不换"的现场。
     * 现在按真实节奏给它喂突发：拿到 ready 发一拍 read，收完 end 再发下一个。
     *=======================================================================*/
    reg         bmp_go    = 1'b0;
    reg         bmp_wait  = 1'b0;
    integer     bmp_run   = 0;        // 本轮已经跑了多少拍
    integer     bmp_limit = 0;        // 跑到多少拍自动收手
    integer     bmp_done  = 0;        // 真正读完的扇区数

    // read 必须是**组合**的：一旦 ready 就同拍发，不隔一拍。仲裁器给 BMP 的
    // 优先权就是"这一拍谁在要就给谁"，隔一拍就抢不过 WAV 那个已经挂起的
    // pending（它一直在等 idle），于是 BMP 永远只拿到零星几个扇区 ——
    // 那样测出来的"占线"根本不占线。
    assign bmp_read = bmp_go && !bmp_wait && bmp_ready;

    always @(posedge sd_clk) begin
        if (sd_rst) begin
            bmp_wait <= 1'b0;
            bmp_go   <= 1'b0;
            bmp_run  <= 0;
            bmp_addr <= 32'd100;
        end
        else begin
            if (bmp_wait && bmp_end) begin
                bmp_wait <= 1'b0;
                bmp_done <= bmp_done + 1;
            end
            else if (bmp_read) begin
                bmp_wait <= 1'b1;
                bmp_addr <= bmp_addr + 32'd1;
            end

            // 按时间收手，而不是按扇区数：一扇区 512 拍，扇区数不好估时间
            if (bmp_go) begin
                bmp_run <= bmp_run + 1;
                if (bmp_run >= bmp_limit) begin
                    bmp_go   <= 1'b0;
                    bmp_wait <= 1'b0;
                end
            end
        end
    end
    integer reads_before;

    /*=========================================================================
     * 扇区读请求计数（2026-10-26 新增）
     * ------------------------------------------------------------------------
     * "训练模式不读卡"这条契约没法靠 play_pos 单独证明：pos 冻住也可能只是
     * 欠载了。这里直接数 wav_reader 发出来的扇区读请求（wav_read 的上升沿），
     * 用"训练 30 ms 内一次都没有 / 正常播放 30 ms 内至少有一次"来双向证伪。
     * 参考量级：FIFO 1024 帧 = 21.3 ms 补一次，每次 9 个扇区。
     *=======================================================================*/
    integer sec_reads = 0;
    reg     wav_read_d = 1'b0;
    always @(posedge sd_clk) begin
        wav_read_d <= wav_read;
        if (wav_read && !wav_read_d) sec_reads = sec_reads + 1;
    end

    // 改页号并等目标曲目出现
    task step_to(input [2:0] page, input integer us_window, input [255:0] why);
        integer n, limit, found;
        begin
            sel   = page;
            limit = us_window * 100;          // 1 us = 100 个 sd_clk
            found = 0;
            n     = 0;
            while (n < limit && !found) begin
                @(posedge sd_clk);
                if (last_l === want_l(page + 1)) found = 1;
                n = n + 1;
            end
            steps = steps + 1;
            if (!found) begin
                errors = errors + 1;
                $display("[FAIL] %0s: 页 %0d（第 %0d 段）%0d us 内没听到；样本=0x%06h 期望=0x%06h state=%0d err=%0d ecode=%0d pos=%0d level=%0d",
                         why, page, page + 1, us_window, last_l, want_l(page + 1),
                         wav_state, wav_error, wav_ecode, play_pos, buf_level);
            end
            else
                $display("[ ok ] %0s: 页 %0d → 第 %0d 段（%0d us）", why, page, page + 1, n / 100);
        end
    endtask

    // 等心跳出现：WAV 样本最大 0x040000（第 4 段），心跳峰值约 ±0x7F7F00，
    // 用 |样本| > 0x200000 判定"这一帧一定是心跳，不可能是 WAV"。
    task wait_heart(input integer us_window, input [255:0] why);
        integer n, limit, found;
        begin
            limit = us_window * 100;
            found = 0;
            n     = 0;
            while (n < limit && !found) begin
                @(posedge sd_clk);
                if ($signed(last_l) > 24'sd2097152 ||
                    $signed(last_l) < -24'sd2097152) found = 1;
                n = n + 1;
            end
            if (!found) begin
                errors = errors + 1;
                $display("[FAIL] wait_heart: %0d us 内心跳没出来；样本=0x%06h state=%0d pos=%0d",
                         us_window, last_l, wav_state, play_pos);
            end
            else
                $display("[ ok ] wait_heart: %0d us 内出心跳（样本=0x%06h）", n / 100, last_l);
        end
    endtask

    // 训练模式下"该页 WAV 被屏蔽"的硬判据：
    //   WAV 每帧都输出同一个常量（合成卡里每段就是一个固定样本值），
    //   心跳每帧都在变（正弦+包络）。所以只要训练期间**连续 20 帧**都等于
    //   该页 WAV 的常量，就说明选择器根本没选中心跳。
    task expect_wav_masked(input [23:0] v, input integer nrun, input [255:0] why);
        integer hits, frames, n;
        begin
            hits   = 0;
            frames = 0;
            n      = 0;
            while (frames < 4000 && hits < nrun) begin
                @(posedge vclk);
                if (audio_valid) begin
                    frames = frames + 1;
                    if (last_l === v) hits = hits + 1;
                    else              hits = 0;
                    n = n + 1;
                end
            end
            if (hits >= nrun) begin
                errors = errors + 1;
                $display("[FAIL] expect_wav_masked: 训练中出现了 %0d 连帧的 WAV 常量 0x%06h", hits, v);
            end
            else
                $display("[ ok ] expect_wav_masked: %0d 帧内没有 WAV 常量，该页音频确实被屏蔽", n);
        end
    endtask

    /* ---------------- 主流程 ---------------- */
    initial begin
        $display("=== tb_wav_page_switch: 换页换曲集成回归 ===");
        repeat (40) @(posedge sd_clk);
        sd_rst = 0; m_rst = 0; v_rst = 0;

        step_to(3'd0, 20000, "上电");
        step_to(3'd1, 20000, "前进 1");
        step_to(3'd2, 20000, "前进 2");
        step_to(3'd3, 20000, "前进 3");
        step_to(3'd0, 20000, "前进 4 回卷");

        // 用户场景：连续走完四首之后立刻后退 / 再前进
        step_to(3'd1, 20000, "再前进 5");
        step_to(3'd2, 20000, "再前进 6");
        step_to(3'd3, 20000, "再前进 7");
        step_to(3'd2, 20000, "后退到 3");
        step_to(3'd1, 20000, "后退到 2");
        step_to(3'd0, 20000, "后退到 1");
        step_to(3'd2, 20000, "跨越到 3");
        step_to(3'd3, 20000, "前进到 4");
        step_to(3'd0, 20000, "回卷到 1");
        step_to(3'd3, 20000, "后退到 4");
        step_to(3'd1, 20000, "后退到 2");
        step_to(3'd2, 20000, "前进到 3");

        // 连打：不等音频换完就继续换，间隔只有几百微秒 —— 上板连按 next/prev
        // 就是这个节奏，旧实现在这里最容易撞上"旧扇区还没发完就重启"。
        $display("--- 连打阶段：每 400 us 换一页 ---");
        for (r = 0; r < 10; r = r + 1) begin
            sel = (r < 4) ? r[2:0] : (3'd3 - {1'b0, (r[1:0] & 2'd3)});
            repeat (40000) @(posedge sd_clk);      // 400 us
        end
        step_to(3'd0, 20000, "连打后回第 1 页");
        step_to(3'd3, 20000, "连打后再到第 4 页");
        step_to(3'd2, 20000, "连打后到第 3 页");

        // ---- 换页时画面正在读卡 ----
        // 上板真实场景：手指一按换页，画面刷新立刻连读上千扇区，WAV 的读请求
        // 被压成 pending。此刻若再换页（abort），挂起的请求必须随撤销一起丢弃，
        // 否则它会在 BMP 让出总线之后补发一整扇区，撞进新曲目的头部解析，
        // 表现就是"图换了，歌还是老的"。
        $display("--- 换页时 BMP 正在占线 ---");
        step_to(3'd1, 30000, "contend: 先停在第 2 页");

        // 上板一次换页的读图量约 1800 扇区、70+ ms。这里按 4 ms（40 万拍）
        // 占住总线，足够让 WAV 的读请求从"当拍就发"变成"一直挂着"。
        bmp_addr  = 32'd100;
        bmp_run   = 0;
        bmp_limit = 400000;
        bmp_go    = 1'b1;
        t0 = 0;
        while (bmp_done < 6 && t0 < 20000) begin @(posedge sd_clk); t0 = t0 + 1; end
        if (bmp_done < 6) begin
            errors = errors + 1;
            $display("[FAIL] contend: BMP burst never got the bus (done=%0d)", bmp_done);
        end
        $display("        BMP 已读 %0d 个扇区、仍占着总线，此刻换页", bmp_done);
        step_to(3'd3, 40000, "contend: BMP 占线时换页");
        bmp_go    = 1'b0;
        $display("        BMP 共读 %0d 个扇区，音乐仍按页切换", bmp_done);

        // ---- 训练模式：音频口二选一 ----
        // 训练模式只换选择端，不碰 sel，所以"屏蔽该页音频"完全靠选择器本身成立；
        // 退出训练时 sel 还是第 3 页，应当立刻听到第 3 段。
        // I_play 跟着压 0：这就是顶层 wav_play_gate = wav_play_en & ~heart_en 的接法。
        $display("--- 训练模式：I_heart_en 二选一 ---");
        pos_train = play_pos;                     // 进训练那一刻的位置（正播着）
        heart_en = 1'b1;
        play     = 1'b0;                          // 等价于顶层的 wav_play_gate
        wait_heart(5000, "进训练");

        // 训练中不许读卡：位置必须冻住（允许 2 帧还在管道里）
        repeat (40000) @(posedge sd_clk);         // 400 us
        if (play_pos > pos_train + 2) begin
            errors = errors + 1;
            $display("[FAIL] 训练中 play_pos 从 %0d 涨到 %0d：WAV 还在读卡", pos_train, play_pos);
        end
        else
            $display("[ ok ] 训练中 play_pos 冻在 %0d（进训练时 %0d），WAV 没在读",
                     play_pos, pos_train);

        // 训练中换页：画面换，但音频仍然是心跳（WAV 被完全屏蔽）
        sel = 3'd0;
        repeat (40000) @(posedge sd_clk);          // 400 us
        wait_heart(5000, "训练中换页仍是心跳");
        expect_wav_masked(want_l(1), 20, "训练中 WAV 被屏蔽");

        // 训练 30 ms 内一次扇区读都不许发（换页那次补填 FIFO 早就结束了）
        reads_before = sec_reads;
        repeat (3000000) @(posedge sd_clk);        // 30 ms
        if (sec_reads != reads_before) begin
            errors = errors + 1;
            $display("[FAIL] 训练 30 ms 内又发了 %0d 个扇区读请求：WAV 仍在读卡",
                     sec_reads - reads_before);
        end
        else
            $display("[ ok ] 训练 30 ms 内 0 个扇区读请求（累计仍是 %0d）", sec_reads);

        heart_en = 1'b0;
        play     = 1'b1;                          // 退出训练：恢复读卡
        step_to(3'd0, 20000, "退出训练回到第 1 页 WAV");
        step_to(3'd2, 20000, "退出训练后换到第 3 页 WAV");

        // ---- 第 5 段 FREE_SONG（2026-10-26 新增）----
        // 自动展播时顶层把选曲码钉在 4，页号怎么翻都不变 —— 也就是说
        // "翻页不换曲"这条在 RTL 层面就是"码不变"。这里先验证码 4 真的能
        // 选中第 5 段（样本 0x0500），再验证停在 4 上不会反复重启。
        $display("--- 自动展播：第 5 段 FREE_SONG ---");
        step_to(3'd4, 20000, "进自动展播 → FREE_SONG");
        pos_train = play_pos;                     // 借用同一个整数变量
        repeat (2000000) @(posedge sd_clk);       // 20 ms 停在码 4（相当于翻了几次页）
        if (last_l !== want_l(5)) begin
            errors = errors + 1;
            $display("[FAIL] 停在 FREE_SONG 上却听到 0x%06h（期望 0x%06h）",
                     last_l, want_l(5));
        end
        else if (play_pos <= pos_train) begin
            errors = errors + 1;
            $display("[FAIL] FREE_SONG 的位置没前进（%0d → %0d）：码不变被当成反复重启了",
                     pos_train, play_pos);
        end
        else
            $display("[ ok ] 码 4 稳定播放：位置 %0d → %0d，曲目没被翻页打断",
                     pos_train, play_pos);
        step_to(3'd1, 20000, "退出自动展播 → 回第 2 页");
        step_to(3'd4, 20000, "再进自动展播 → FREE_SONG");
        step_to(3'd3, 20000, "再退出 → 第 4 页");

        // 反向对照：正常播放 30 ms 内必须重新出现扇区读请求，
        // 否则上面那个"0 次"可能只是因为计数器根本没动。
        reads_before = sec_reads;
        repeat (3000000) @(posedge sd_clk);        // 30 ms
        if (sec_reads == reads_before) begin
            errors = errors + 1;
            $display("[FAIL] 正常播放 30 ms 内没有任何扇区读请求：计数器无效，反证失败");
        end
        else
            $display("[ ok ] 正常播放 30 ms 内发了 %0d 个扇区读请求（对照成立）",
                     sec_reads - reads_before);

        if (errors == 0) begin
            $display("PASS: wav_page_switch 共 %0d 步换页换曲全部正确", steps);
            $finish;
        end
        else begin
            $display("FAIL: wav_page_switch %0d/%0d 步没换过来", errors, steps);
            $fatal(1, "换页换曲失败");
        end
    end

    initial begin
        #200_000_000;                        // 200 ms 仿真上限
        $display("FAIL: wav_page_switch 仿真超时 state=%0d pos=%0d level=%0d", wav_state, play_pos, buf_level);
        $fatal(1, "timeout");
    end

endmodule
