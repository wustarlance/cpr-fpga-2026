`timescale 1ns/1ps
//=============================================================================
// tb_wave_painter.v —— wave_painter 自检 TB
//-----------------------------------------------------------------------------
// 激励：锯齿波 amp8 = ((n%200)-100) >> g，g = (n/200)%2 ∈ {0,1}
//   * 每 200 个样本一个周期，负→非负的零交叉恒在 n%200==100 → 触发点确定；
//   * 相邻两组增益不同（÷1 / ÷2）：一旦某个 bank 被"写了一半就显示"，
//     里面就是两种增益拼起来的数据，与"按触发点算出的期望"必然对不上。
//
// 判据不是硬编码的图案，而是**跟着实际触发点走**：
//   TB 观察到 DUT 的 W_cap_first 记下触发样本号 trig_n，攒满时记为 done_n，
//   换 bank 时把 done_n 锁进 shown_n；帧末就用 shown_n 算出这 200 列应有的
//   行范围，跟屏幕上实际画出来的 min/max 逐列比。这样：
//     * 列映射错位 1 列 → 立刻不符（相邻列的期望值不同）；
//     * 上一列的行没记住（点连不成线）→ min/max 只有一个值，不符；
//     * 显示的是旧 bank / 写了一半的 bank → 与 shown_n 对不上；
//     * 像素延迟不是 2 拍 → 记录到错误的列上，整体错位。
//
// 检查项：
//   C1 hit 必须在窗口内、DE=1、颜色只能是三种之一
//   C2 没有 X（未初始化的 bank 不能被画出来）
//   C3 每列的 COL_POINT 像素必须构成连续 min..max 段，且等于期望（200 列全对）
//   C4 200 列每列都要被画到
//   C5 存进去的数据必须就是那一串采样（写侧地址/指针没错）
//   C6 每帧都换过 bank（显示的是新数据，不是冻结的旧画面）
//   C7 中线、边框都画出来了
//=============================================================================
module tb_wave_painter;

/* ---------------- 与 DUT 一致的几何参数 ---------------- */
localparam integer COL_W = 200;
localparam integer ROW_H = 200;
localparam integer X0    = 8;
localparam integer Y0    = 8;

/* 缩小的"屏幕"：240×240 有效区，只为少跑点时钟（真实是 640×480） */
localparam integer HACT  = 240;
localparam integer VACT  = 240;
localparam integer HTOT  = 320;
localparam integer VTOT  = 250;

localparam integer SMPDIV = 524;        // 25.175 MHz / 48 kHz ≈ 524.48 → 524
localparam integer NFRAME = 16;

// 三段激励，覆盖两条路径：
//   [0, N1)      锯齿波（增益 ÷1）        → 正常触发采集
//   [N1, N2)     全 0（静音 ~16.6 ms）    → 没有零交叉，靠 TRIG_FREE_FRAMES 兜底
//   [N2, ∞)      锯齿波（增益 ÷2）        → 触发恢复，且幅度明显不同
// amp_of(n) 是 n 的纯函数，所以"跨段的那一次采集"也能算出准确期望（半段宽半段窄）。
localparam integer N1 = 600;
localparam integer N2 = 1400;

localparam [23:0] COL_POINT = 24'h30E040;
localparam [23:0] COL_AXIS  = 24'h303840;
localparam [23:0] COL_FRAME = 24'hC8C8C8;

/* ---------------- 时钟 / 复位 ---------------- */
reg clk = 1'b0;
always #(1000.0/25.175/2.0) clk = ~clk;      // 25.175 MHz

reg rst = 1'b1;

/* ---------------- 像素扫描 ---------------- */
reg  [11:0] hcnt, vcnt;
wire        de  = (hcnt < HACT) && (vcnt < VACT);

always @(posedge clk or posedge rst) begin
    if (rst) begin hcnt <= 12'd0; vcnt <= 12'd0; end
    else if (hcnt == HTOT-1) begin
        hcnt <= 12'd0;
        vcnt <= (vcnt == VTOT-1) ? 12'd0 : (vcnt + 12'd1);
    end
    else hcnt <= hcnt + 12'd1;
end

/* ---------------- 采样激励（48 kHz） ---------------- */
function integer amp_of(input integer n);
    integer base, g;
    begin
        if ((n >= N1) && (n < N2)) begin
            amp_of = 0;                     // 静音段
        end
        else begin
            base = (n % 200) - 100;         // -100 .. 99
            g    = (n / 200) % 2;           // 0 / 1（静音段之后整段是同一个增益）
            // 注意：必须用 >>>（算术右移）。Verilog 的 >> 是**逻辑**右移，
            // 对负数会补 0，-100>>1 得到 0x7FFFFFCE 而不是 -50 —— 这个坑在
            // 检查器里表现为"期望 0x7FFFFFCE、实测 0xCE"，很容易误判成 RTL 错。
            amp_of = base >>> g;
        end
    end
endfunction

integer    smp_div   = 0;
integer    smp_n     = 0;
reg        smp_valid = 1'b0;
reg [23:0] smp_data  = 24'd0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        smp_div   <= 0;
        smp_n     <= 0;
        smp_valid <= 1'b0;
        smp_data  <= 24'd0;
    end
    else begin
        smp_valid <= 1'b0;
        if (smp_div == SMPDIV-1) begin
            smp_div   <= 0;
            smp_valid <= 1'b1;
            smp_data  <= {(amp_of(smp_n) & 255), 16'h0000};  // 低 16 bit 恒 0
            smp_n     <= smp_n + 1;
        end
        else smp_div <= smp_div + 1;
    end
end

/* ---------------- DUT ---------------- */
wire        wave_hit;
wire [23:0] wave_rgb;
wire        wave_de;
wire [7:0]  dbg_wr_ptr;
wire        dbg_rd_bank, dbg_cap, dbg_pend;
wire [31:0] dbg_smp_cnt, dbg_frame_cnt;

wave_painter #(
    .COL_W   (COL_W),
    .ROW_H   (ROW_H),
    .DEPTH   (256),
    .ADDR_BITS (8),
    .X0      (X0),
    .Y0      (Y0),
    .TRIG_EN (1),
    .TRIG_FREE_FRAMES (4)
) u_dut (
    .I_clk      (clk),
    .I_rst      (rst),
    .I_smp_valid(smp_valid),
    .I_smp_data (smp_data),
    .I_pix_x    (hcnt),
    .I_pix_y    (vcnt),
    .I_pix_de   (de),
    .O_pix_hit  (wave_hit),
    .O_pix_rgb  (wave_rgb),
    .O_pix_de_d (wave_de),
    .O_wr_ptr   (dbg_wr_ptr),
    .O_rd_bank  (dbg_rd_bank),
    .O_capturing(dbg_cap),
    .O_bank_ready(dbg_pend),
    .O_smp_cnt  (dbg_smp_cnt),
    .O_frame_cnt(dbg_frame_cnt)
);

/* ---------------- 期望值模型（与 RTL 逐位对齐） ---------------- */
// amp8（-128..127）→ 窗口内行号 0..ROW_H-1
function integer row_of(input integer amp);
    integer a, off, r;
    begin
        if (amp < 0) begin a = -amp; off = (a*25)/32; r = 100 + off; end
        else         begin a =  amp; off = (a*25)/32; r = 100 - off; end
        if (r > ROW_H-1) r = ROW_H-1;
        if (r < 0)       r = 0;
        row_of = r;
    end
endfunction

/* ---------------- 跟踪"屏幕上那一组"样本 ---------------- */
integer trig_n  = -1;    // 最近一次起采的样本号
integer done_n  = -1;    // 最近一次攒满的 bank 的起采样本号
integer shown_n = -1;    // 正在显示的那个 bank 的起采样本号
reg     pend_d  = 1'b0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        trig_n <= -1; done_n <= -1; shown_n <= -1; pend_d <= 1'b0;
    end
    else begin
        // 起采那一拍：smp_n 已在同一沿自增，所以样本号是 smp_n-1
        if (u_dut.W_cap_first) trig_n <= smp_n - 1;
        // 攒满（S_pend 上升沿）
        if (dbg_pend && !pend_d) done_n <= trig_n;
        pend_d <= dbg_pend;
        // 换 bank：此刻起屏幕显示的就是 done_n 那一组
        if (u_dut.W_win_start && dbg_pend) shown_n <= done_n;
    end
end

/* ---------------- 2 拍对齐的像素监视器 ---------------- */
reg [11:0] hx0,hx1;  reg [11:0] vy0,vy1;  reg de0,de1;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        hx0<=12'd0; hx1<=12'd0; vy0<=12'd0; vy1<=12'd0; de0<=1'b0; de1<=1'b0;
    end
    else begin
        hx0 <= hcnt; hx1 <= hx0;
        vy0 <= vcnt; vy1 <= vy0;
        de0 <= de;   de1 <= de0;
    end
end

integer colmin [0:COL_W-1];
integer colmax [0:COL_W-1];
integer colcnt [0:COL_W-1];

integer err_total = 0;
integer n_frame   = 0;
integer n_ok      = 0;
integer n_checked = 0;
integer n_axis    = 0;
integer n_border  = 0;
integer n_point   = 0;
integer last_fcnt = 0;

integer k, cc, rr, mism, bad, exp_lo, exp_hi, exp_cur, exp_prv, mem_amp;

task clear_cols;
    begin
        for (k = 0; k < COL_W; k = k + 1) begin
            colmin[k] = 9999;
            colmax[k] = -1;
            colcnt[k] = 0;
        end
    end
endtask

initial clear_cols;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        err_total = 0;
        n_frame   = 0;
        n_ok      = 0;
        n_checked = 0;
        n_axis    = 0;
        n_border  = 0;
        n_point   = 0;
        last_fcnt = 0;
        clear_cols;
    end
    else begin
        /* ---- C2 ---- */
        if ((wave_hit === 1'bx) || (wave_rgb === 24'hxxxxxx)) begin
            $display("  [FAIL] t=%0t hit=%b rgb=%h（bank 未初始化就被画？）",
                     $time, wave_hit, wave_rgb);
            $display("         in1=%b bank_valid=%b rd_bank=%b lo=%0d hi=%0d y1=%0d ptr=%0d pend=%b",
                     u_dut.S_in1, u_dut.S_bank_valid, dbg_rd_bank,
                     u_dut.W_lo, u_dut.W_hi, u_dut.S_y1,
                     dbg_wr_ptr, dbg_pend);
            err_total = err_total + 1;
        end

        /* ---- C1 + 逐列记录 ---- */
        if (wave_hit === 1'b1) begin
            if (!de1) begin
                $display("  [FAIL] t=%0t DE=0 时出现 hit (%0d,%0d)", $time, hx1, vy1);
                err_total = err_total + 1;
            end
            else if (!((hx1 >= X0) && (hx1 < X0+COL_W) &&
                       (vy1 >= Y0) && (vy1 < Y0+ROW_H))) begin
                $display("  [FAIL] t=%0t hit 落在窗口外 (%0d,%0d)", $time, hx1, vy1);
                err_total = err_total + 1;
            end

            if (!((wave_rgb === COL_POINT) || (wave_rgb === COL_AXIS) ||
                  (wave_rgb === COL_FRAME))) begin
                $display("  [FAIL] t=%0t 非法颜色 %h", $time, wave_rgb);
                err_total = err_total + 1;
            end

            if (wave_rgb === COL_POINT) begin
                cc = hx1 - X0;
                rr = vy1 - Y0;
                n_point = n_point + 1;
                if (cc >= 0 && cc < COL_W) begin
                    if (rr < colmin[cc]) colmin[cc] = rr;
                    if (rr > colmax[cc]) colmax[cc] = rr;
                    colcnt[cc] = colcnt[cc] + 1;
                end
            end
            else if (wave_rgb === COL_AXIS) n_axis   = n_axis + 1;
            else                            n_border = n_border + 1;
        end

        /* ---- 帧末：C3/C4/C5/C6 ---- */
        if (de1 && (hx1 == HACT-1) && (vy1 == VACT-1)) begin
            n_frame = n_frame + 1;

            if (shown_n < 0) begin
                $display("  frame %0d: 还没有可显示的 bank（frame_cnt=%0d），跳过",
                         n_frame, dbg_frame_cnt);
            end
            else if (dbg_frame_cnt == last_fcnt) begin
                $display("  frame %0d: 本帧没换 bank（复显同一组），跳过", n_frame);
            end
            else begin
                /* C5：先看存进去的是不是那一串采样 */
                mism = 0; bad = -1;
                for (k = 0; k < COL_W; k = k + 1) begin
                    if (dbg_rd_bank) mem_amp = u_dut.S_smp_b1[k][23:16] - ((u_dut.S_smp_b1[k][23:16] >= 128) ? 256 : 0);
                    else             mem_amp = u_dut.S_smp_b0[k][23:16] - ((u_dut.S_smp_b0[k][23:16] >= 128) ? 256 : 0);
                    if (mem_amp != amp_of(shown_n + k)) begin
                        mism = mism + 1;
                        if (bad < 0) bad = k;
                    end
                end
                if (mism != 0) begin
                    $display("  [FAIL] frame %0d: bank 内容与采样流不符（%0d 列，首处 col=%0d 存 %0d 期望 %0d）",
                             n_frame, mism, bad,
                             (dbg_rd_bank ? u_dut.S_smp_b1[bad][23:16] : u_dut.S_smp_b0[bad][23:16]),
                             amp_of(shown_n + bad) & 255);
                    $display("         shown_n=%0d trig_n=%0d done_n=%0d cmp_rd_bank=%0d",
                             shown_n, trig_n, done_n, dbg_rd_bank);
                    for (k = 0; k < 3; k = k + 1)
                        $display("         col%0d mem=%h exp=%0d", k,
                                 (dbg_rd_bank ? u_dut.S_smp_b1[k] : u_dut.S_smp_b0[k]),
                                 amp_of(shown_n + k));
                    for (k = 99; k < 102; k = k + 1)
                        $display("         col%0d mem=%h exp=%0d", k,
                                 (dbg_rd_bank ? u_dut.S_smp_b1[k] : u_dut.S_smp_b0[k]),
                                 amp_of(shown_n + k));
                    err_total = err_total + 1;
                end

                /* C3 / C4：逐列比 min/max */
                mism = 0; bad = -1;
                for (k = 0; k < COL_W; k = k + 1) begin
                    exp_cur = row_of(amp_of(shown_n + k));
                    exp_prv = row_of(amp_of(shown_n + ((k == 0) ? 0 : (k-1))));
                    exp_lo  = (exp_cur < exp_prv) ? exp_cur : exp_prv;
                    exp_hi  = (exp_cur < exp_prv) ? exp_prv : exp_cur;
                    if (colcnt[k] == 0) begin
                        mism = mism + 1;
                        if (bad < 0) bad = k;
                    end
                    else if ((colmin[k] != exp_lo) || (colmax[k] != exp_hi)) begin
                        mism = mism + 1;
                        if (bad < 0) bad = k;
                    end
                end

                if (mism == 0) begin
                    n_ok = n_ok + 1;
                    $display("  frame %0d: 200 列全对（显示组 n0=%0d, bank=%0d, frame_cnt=%0d）",
                             n_frame, shown_n, dbg_rd_bank, dbg_frame_cnt);
                end
                else begin
                    $display("  [FAIL] frame %0d: %0d 列不符（首处 col=%0d 实测 %0d..%0d 期望 %0d..%0d）",
                             n_frame, mism, bad, colmin[bad], colmax[bad],
                             ((row_of(amp_of(shown_n+bad)) < row_of(amp_of(shown_n+((bad==0)?0:bad-1)))) ?
                               row_of(amp_of(shown_n+bad)) : row_of(amp_of(shown_n+((bad==0)?0:bad-1)))),
                             ((row_of(amp_of(shown_n+bad)) < row_of(amp_of(shown_n+((bad==0)?0:bad-1)))) ?
                               row_of(amp_of(shown_n+((bad==0)?0:bad-1))) : row_of(amp_of(shown_n+bad))));
                    err_total = err_total + 1;
                end
                n_checked = n_checked + 1;
                last_fcnt = dbg_frame_cnt;
            end

            clear_cols;

            if (n_frame >= NFRAME) begin
                $display("");
                $display("================ 结果 ================");
                $display("  帧数             : %0d", n_frame);
                $display("  受检/全对        : %0d / %0d", n_checked, n_ok);
                $display("  点/中线/边框像素 : %0d / %0d / %0d", n_point, n_axis, n_border);
                $display("  样本计数         : DUT %0d / TB 生成 %0d", dbg_smp_cnt, smp_n);
                $display("  换 bank 次数     : %0d", dbg_frame_cnt);
                if (n_checked == 0) begin
                    $display("  [FAIL] 没有任何一帧受检（bank 一直没换？）");
                    err_total = err_total + 1;
                end
                if (n_axis == 0 || n_border == 0) begin
                    $display("  [FAIL] 中线/边框没画出来");
                    err_total = err_total + 1;
                end
                if (err_total == 0)
                    $display("===== 全部检查通过（PASS） =====");
                else
                    $display("===== 有 %0d 项失败（FAIL） =====", err_total);
                $display("=====================================");
                $finish;
            end
        end
    end
end

initial begin
    rst = 1'b1;
    repeat (20) @(posedge clk);
    rst = 1'b0;
end

initial begin
    #120_000_000;                      // 兜底（16 帧约 51 ms）
    $display("[TIMEOUT] 120 ms 内没跑到 %0d 帧（n_frame=%0d）", NFRAME, n_frame);
    $finish;
end

endmodule
