`timescale 1ns/1ps
//=============================================================================
// tb_heartbeat_synth —— 心跳合成的波形契约（训练模式"咚—哒"）
//-----------------------------------------------------------------------------
// 检查项（全部按**帧**计，不依赖绝对时间，时钟快慢不影响判定）：
//   1) 一拍长度 = 110 BPM → PERIOD = 26182 帧
//      （MCLK_HZ=12.288M → FS=(MCLK+128)/256=48000，(48000*60+55)/110=26182）；
//   2) 第 1 声从拍首起、"咚"峰值 ≈ 100% 量程，且前 5 ms 明显大于最后 5 ms
//      （包络确实在衰减，不是一整段等幅正弦）；
//   3) 第 2 声起点在第 3362 帧（70 ms = 0.07*48000）附近，峰值 = 第 1 声的 65%；
//   4) 第 2 声收尾后到下一拍之前（约 110 ms ~ 545 ms）必须是**全零静音**；
//   5) 左右声道完全一致（单声道复制）；
//   6) I_enable=0 时输出全零；再次使能从"咚"重来（不接在半声上）。
//   7) 发声中途拉低 I_enable 必须"收尾"而不是一刀切（2026-10-26 新增）：
//      O_busy 保持 1、输出在 8~60 帧内按包络跌到 0、最后一个非零样本必须
//      已经很小（≤2048，−72 dBFS），之后必须是全零。反证：若改回"立刻归零"，
//      最后一帧非零样本会等于当时的幅度（满量程量级），断言必然失败。
//   8) 收尾结束（O_busy=0）后重新使能，仍从"咚"的拍首开始、峰值满量程。
//   9) 音调（2026-10-26 新增）：第 1 声 150 Hz / 第 2 声 190 Hz。用**过零次数**
//      反推频率，比看波形稳：25 ms 里 150 Hz 有 3.75 个周期 → 7~8 次过零，
//      实测容差放到 6~9；第 2 声 35 ms 里 6.65 个周期 → 13~14 次，容差 11~16。
//      这条能证伪"改频率时不小心把相位增量算错"（75/95 Hz 只有 3~4 / 6~7 次，
//      必然失败），也顺带证明没把两声的频率写反。
//
// 对齐方式：不要假设"采集的第 0 帧就是拍首"。DUT 的输出比相位累加晚一拍，
// 采集窗口的起点也可能落在拍首前后一两帧，所以先量出第 1 声的真实起点 s0，
// 之后所有窗口都以 s0 为原点。
//=============================================================================
module tb_heartbeat_synth;

    localparam integer FRAME_CLK = 256;                                   // 一帧 = 256 个 MCLK
    localparam integer FS_CALC   = (12_288_000 + 128) / 256;              // 48000
    localparam integer PERIOD    = (FS_CALC * 60 + 55) / 110;             // 26182 → 110 BPM
    localparam integer GAP_S     = (FS_CALC * 70 + 500) / 1000;           // 3360
    localparam integer DUR1_S    = (FS_CALC * 25 + 500) / 1000;           // 1200
    localparam integer DUR2_S    = (FS_CALC * 35 + 500) / 1000;           // 1680
    localparam integer DUR1_MS   = 25;
    localparam integer DUR2_MS   = 35;
    localparam integer N_CAP     = PERIOD + 600;
    localparam integer FULL24    = 8388352;                               // 32767 << 8

    // 时钟：只关心"每 256 拍一帧"，所以跑快一点省仿真时间（DUT 逻辑按帧推进）
    reg clk = 0;
    always #4.069 clk = ~clk;

    reg rst = 1;
    reg enable = 0;
    reg frame_stb = 0;

    wire [23:0] left, right;
    wire        busy;

    heartbeat_synth dut (
        .I_clk       (clk),
        .I_rst       (rst),
        .I_frame_stb (frame_stb),
        .I_enable    (enable),
        .O_busy      (busy),
        .O_left      (left),
        .O_right     (right)
    );

    // ---- 帧节拍：每 FRAME_CLK 个时钟一个单拍 ----
    integer div = 0;
    always @(posedge clk) begin
        if (div == FRAME_CLK-1) begin
            div       <= 0;
            frame_stb <= 1'b1;
        end
        else begin
            div       <= div + 1;
            frame_stb <= 1'b0;
        end
    end

    // ---- 采集：每个帧节拍后 1 ns 取一次输出（此时寄存输出已稳定） ----
    integer cap [0:N_CAP-1];
    integer capr[0:N_CAP-1];
    integer n = 0;
    reg     cap_en = 0;
    always @(posedge clk) begin
        if (frame_stb && cap_en && n < N_CAP) begin
            #1;
            cap [n] = $signed(left);
            capr[n] = $signed(right);
            n = n + 1;
        end
    end

    // ---- 工具 ----
    function integer iabs;
        input integer v;
        begin iabs = (v < 0) ? -v : v; end
    endfunction

    task automatic first_nonzero(input integer a, input integer b, output integer pos);
        integer k;
        begin
            pos = -1;
            for (k = a; k < b; k = k + 1)
                if (pos < 0 && cap[k] !== 0) pos = k;
        end
    endtask

    task automatic peak_in(input integer a, input integer b, output integer pk);
        integer k;
        begin
            pk = 0;
            for (k = a; k < b; k = k + 1)
                if (iabs(cap[k]) > pk) pk = iabs(cap[k]);
        end
    endtask

    // 数窗口内的过零次数（跳过 0 样本，按"上一个非零符号"判翻转）
    task automatic count_cross(input integer a, input integer b, output integer cnt);
        integer k, sgn, prev;
        begin
            cnt  = 0;
            prev = 0;
            for (k = a; k < b; k = k + 1) begin
                if (cap[k] > 0) sgn =  1;
                else if (cap[k] < 0) sgn = -1;
                else sgn = 0;
                if (sgn != 0) begin
                    if (prev != 0 && sgn != prev) cnt = cnt + 1;
                    prev = sgn;
                end
            end
        end
    endtask

    integer s0, s1, s2, peak1, peak2, p_head, p_tail, i;
    integer xc1, xc2;
    integer n_drop, last, nonz, pk_cut, pk3, s3;

    initial begin
        // 复位期间 enable=0：内部序号被压在拍首
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (40) @(posedge clk);

        // ---- 6a) 未使能：必须全零 ----
        cap_en = 1'b1;
        n = 0;
        repeat (3000 * FRAME_CLK) @(posedge clk);
        cap_en = 1'b0;
        for (i = 0; i < n; i = i + 1)
            if (cap[i] !== 0)
                $fatal(1, "未使能时第 %0d 帧不是静音（%0d）", i, cap[i]);
        $display("  [1] 未使能 %0d 帧全静音 OK", n);

        // ---- 正式采集一拍多一点 ----
        n = 0;
        enable  = 1'b1;
        cap_en  = 1'b1;
        @(posedge clk);
        while (n < N_CAP) @(posedge clk);
        cap_en = 1'b0;
        enable = 1'b0;

        // ---- 拍首对齐 ----
        first_nonzero(0, 400, s0);
        if (s0 < 0 || s0 > 12)
            $fatal(1, "第 1 声起点在第 %0d 帧，应在前 12 帧内（相位从 0 起）", s0);

        // ---- 2) 第 1 声峰值 + 衰减 ----
        peak_in(s0, s0 + 1300, peak1);
        if (peak1 < FULL24*95/100 || peak1 > FULL24*101/100)
            $fatal(1, "第 1 声峰值 %0d，应在 %0d 附近（100%% 量程）", peak1, FULL24);
        peak_in(s0, s0 + 240, p_head);
        peak_in(s0 + 960, s0 + 1200, p_tail);
        if (p_tail * 3 > p_head)
            $fatal(1, "第 1 声没有衰减：前 5 ms 峰值 %0d，最后 5 ms 峰值 %0d", p_head, p_tail);
        $display("  [2] 第 1 声起点 %0d 帧、峰值 %0d、衰减 %0d→%0d OK",
                 s0, peak1, p_head, p_tail);

        // ---- 9a) 第 1 声音调 = 150 Hz（过零次数）----
        count_cross(s0, s0 + DUR1_S, xc1);
        if (xc1 < 6 || xc1 > 9)
            $fatal(1, "第 1 声 %0d 帧内过零 %0d 次，150 Hz 应约 7~8 次（75 Hz 只有 3~4 次）",
                   DUR1_S, xc1);
        $display("  [9a] 第 1 声过零 %0d 次 / %0d 帧 → 约 %0d Hz OK",
                 xc1, DUR1_S, xc1 * 1000 / 2 / DUR1_MS);

        // ---- 3) 第 2 声：起点 70 ms、峰值 65% ----
        first_nonzero(s0 + 3000, s0 + 3600, s2);
        if (s2 < 0 || s2 - s0 < GAP_S-6 || s2 - s0 > GAP_S+8)
            $fatal(1, "第 2 声起点在拍首后 %0d 帧，应在 %0d 帧（70 ms）", s2 - s0, GAP_S);
        peak_in(s0 + 3000, s0 + 5300, peak2);
        if (peak2 < peak1*60/100 || peak2 > peak1*70/100)
            $fatal(1, "第 2 声峰值 %0d，应为第 1 声的 65%%（%0d 附近）", peak2, peak1*65/100);
        $display("  [3] 第 2 声起点 %0d 帧、峰值 %0d（= %0d%% 第 1 声）OK",
                 s2 - s0, peak2, peak2*100/peak1);

        // ---- 9b) 第 2 声音调 = 190 Hz（35 ms 内约 13 次过零）----
        count_cross(s2, s2 + DUR2_S, xc2);
        if (xc2 < 11 || xc2 > 16)
            $fatal(1, "第 2 声 %0d 帧内过零 %0d 次，190 Hz 应约 13~14 次", DUR2_S, xc2);
        if (xc2 <= xc1)
            $fatal(1, "第 2 声过零 %0d 次不多于第 1 声 %0d 次：两声频率写反了", xc2, xc1);
        $display("  [9b] 第 2 声过零 %0d 次 / %0d 帧 → 约 %0d Hz OK",
                 xc2, DUR2_S, xc2 * 1000 / 2 / DUR2_MS);

        // ---- 4) 第 2 声之后到下一拍之前全静音 ----
        for (i = s0 + 5600; i < s0 + PERIOD; i = i + 1)
            if (cap[i] !== 0)
                $fatal(1, "第 %0d 帧（拍首+%0d）应为静音，实测 %0d", i, i - s0, cap[i]);
        $display("  [4] 第 2 声之后到拍尾（约 110~545 ms）全静音 OK");

        // ---- 5) 左右一致 ----
        for (i = 0; i < N_CAP; i = i + 1)
            if (cap[i] !== capr[i])
                $fatal(1, "第 %0d 帧左右声道不同：L=%0d R=%0d", i, cap[i], capr[i]);
        $display("  [5] 左右声道逐帧一致 OK");

        // ---- 1) 下一拍起点 = PERIOD（110 BPM） ----
        first_nonzero(s0 + PERIOD - 20, s0 + PERIOD + 40, s1);
        if (s1 < 0)
            $fatal(1, "拍首+%0d 附近没有找到下一拍", PERIOD);
        if (iabs((s1 - s0) - PERIOD) > 3)
            $fatal(1, "拍长 %0d 帧，期望 %0d 帧（110 BPM）", s1 - s0, PERIOD);
        $display("  [6] 拍长 %0d 帧（110 BPM，含 1 拍流水延迟）OK", s1 - s0);

        // 上面采完之后把 enable 拉低了，此刻 DUT 正在收尾：先等它真正静下来
        // （≤60 帧），让内部序号回到拍首，后面两段才有确定的起点。
        enable = 1'b0;
        repeat (120 * FRAME_CLK) @(posedge clk);

        // ---- 7) 发声中途退出：必须"收尾"，不许一刀切 ----
        // 先使能、进到"咚"的峰值区，然后拉低 I_enable，看输出是怎么落到 0 的。
        // 100 帧 ≈ 2.1 ms：150 Hz 的满幅保持只有 1.67 ms（80 帧），第一峰在
        // 82 帧左右，取 100 帧刚好落在峰后一点（幅度仍 >90%）；原来 75 Hz 时
        // 第一峰在 160 帧，所以旧值是 200 帧 —— 频率改了这条必须一起改，
        // 否则量到的是已经衰减到 40% 的样本，"满幅截断"这个前提就不成立。
        n = 0;
        cap_en = 1'b1;
        enable = 1'b1;
        repeat (100 * FRAME_CLK) @(posedge clk);
        n_drop = n;                            // 拉低那一刻已经采到多少帧
        enable = 1'b0;
        repeat (8 * FRAME_CLK) @(posedge clk);
        if (busy !== 1'b1)
            $fatal(1, "退出后第 8 帧 O_busy 就落了：选择器会立刻切源，收尾没生效");
        repeat (92 * FRAME_CLK) @(posedge clk);
        if (busy !== 1'b0)
            $fatal(1, "退出后 100 帧 O_busy 还是 1：收尾没有结束，选择器永远切不回去");
        cap_en = 1'b0;

        // 最后一个非零帧
        last = -1;
        for (i = 0; i < n; i = i + 1)
            if (cap[i] !== 0) last = i;
        if (last < 0)
            $fatal(1, "退出后一帧非零都没有：根本没出声，这条用例无效");
        if (last < n_drop + 8 || last > n_drop + 60)
            $fatal(1, "收尾用了 %0d 帧，应在 8~60 帧（0.17~1.25 ms）", last - n_drop);

        // 切点必须发生在"响着"的时候，否则这条用例证明不了什么
        peak_in(n_drop - 10, n_drop + 1, pk_cut);
        if (pk_cut < FULL24 * 50 / 100)
            $fatal(1, "拉低时幅度只有 %0d，太小，测不出满幅截断", pk_cut);

        // 包络是逐帧跌下去的：收尾段要有足够多的中间值
        nonz = 0;
        for (i = n_drop; i <= last; i = i + 1)
            if (cap[i] !== 0) nonz = nonz + 1;
        if (nonz < 10)
            $fatal(1, "收尾段只有 %0d 个非零帧，看起来是一刀切", nonz);

        // 最后一个非零样本必须已经很小（≤2048 = −72 dBFS），之后全零
        if (iabs(cap[last]) > 2048)
            $fatal(1, "最后一个非零样本 %0d 太大（应 ≤2048）：切点上仍有阶跃", cap[last]);
        for (i = last + 1; i < n; i = i + 1)
            if (cap[i] !== 0)
                $fatal(1, "收尾结束后第 %0d 帧又出声了（%0d）", i, cap[i]);
        $display("  [7] 退出收尾：拉低时幅度 %0d → %0d 帧内跌到 %0d（%0d 个非零帧）OK",
                 pk_cut, last - n_drop, cap[last], nonz);

        // ---- 8) 收尾结束后重新使能：还是从"咚"的拍首开始 ----
        n = 0;
        cap_en = 1'b1;
        enable = 1'b1;
        repeat (1400 * FRAME_CLK) @(posedge clk);
        cap_en = 1'b0;
        enable = 1'b0;
        first_nonzero(0, 20, s3);
        if (s3 < 0 || s3 > 12)
            $fatal(1, "重新使能后第 1 声起点在第 %0d 帧，应在前 12 帧内（要从拍首重来）", s3);
        peak_in(s3, s3 + 1300, pk3);
        if (pk3 < FULL24 * 95 / 100 || pk3 > FULL24 * 101 / 100)
            $fatal(1, "重新使能后峰值 %0d，应在 %0d 附近（满量程）", pk3, FULL24);
        $display("  [8] 重新使能：起点 %0d 帧、峰值 %0d OK", s3, pk3);

        $display("PASS: heartbeat_synth 双声心跳/包络/静音间隔/拍长");
        $finish;
    end

endmodule
