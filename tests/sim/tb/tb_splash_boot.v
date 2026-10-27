`timescale 1ns/1ps

// 开机画面自检：
//   1) 按 640x480 的有效像素节奏灌一遍帧（每行前后留消隐，专治地址预取）；
//   2) 对整帧 RGB 流做 FNV-1a 摘要，和 gen_splash_rom.py 打印的值比对；
//   3) 再点两块贴图的非黑像素数（能定位"区域/地址偏了"这类错误）。
// 期望值默认写死，可用 +digest= +lit_art= +lit_load= 覆盖（改图重新生成后）。
module tb_splash_boot;
    // 三个窗口（与 splash_boot.v 的 localparam 一致）：W3 是底部加载提示
    localparam [10:0] LD_X0  = 256, LD_X1  = 383, LD_Y0  = 416, LD_Y1  = 455;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         vs  = 1'b0;
    reg         de  = 1'b0;
    reg         hide = 1'b0;
    wire [23:0] rgb;
    wire        active;

    always #20 clk = ~clk;           // 25 MHz，与 video_clk 一致

    splash_boot #(.DWELL_CYCLES(64)) dut (
        .clk   (clk),
        .rst   (rst),
        .vs    (vs),
        .de    (de),
        .hide  (hide),
        .rgb   (rgb),
        .active(active)
    );

    // ---- 帧统计 ----
    integer digest;
    integer lit_art, lit_load;
    integer exp_digest, exp_art, exp_load;
    integer px_seen;
    integer x_now, y_now;

    initial begin
        digest   = 32'h811c9dc5;
        lit_art  = 0;
        lit_load = 0;
        px_seen  = 0;
        if (!$value$plusargs("digest=%h", exp_digest))  exp_digest = 32'hd58e492d;
        if (!$value$plusargs("lit_art=%d", exp_art))    exp_art    = 8130;
        if (!$value$plusargs("lit_load=%d", exp_load))  exp_load   = 546;
    end

    // 采样点：posedge 之前的值就是这一拍输出的像素
    always @(posedge clk) begin
        if (!rst && de) begin
            digest = (digest ^ {8'h00, rgb}) * 32'h01000193;
            if (rgb != 24'h000000) begin
                // W3 是底部加载提示；其余非黑像素都算"上图"（窗口外一定是黑的）
                if (x_now >= LD_X0 && x_now <= LD_X1 && y_now >= LD_Y0 && y_now <= LD_Y1)
                    lit_load = lit_load + 1;
                else
                    lit_art = lit_art + 1;
            end
            px_seen = px_seen + 1;
        end
    end

    integer y, x;
    integer errors = 0;

    task feed_frame;
        begin
            for (y = 0; y < 480; y = y + 1) begin
                if (y == 0) begin
                    vs = 1'b1; repeat (4) @(posedge clk); vs = 1'b0;
                end
                de = 1'b0; repeat (20) @(posedge clk);   // 行消隐
                de = 1'b1;
                for (x = 0; x < 640; x = x + 1) begin
                    x_now = x;
                    y_now = y;
                    @(posedge clk);
                end
            end
            de = 1'b0; repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        x_now = 0;
        y_now = 0;
        repeat (10) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        if (active !== 1'b1) begin
            $display("[FAIL] hide=0 时 active 应为 1，实际 %b", active);
            errors = errors + 1;
        end

        // 刚上电、dwell 还没到：即使已经有图（hide=1），也要继续显示 logo，
        // 否则会正好落在显示器还没锁定的窗口里（板上实测就是这个现象）。
        hide = 1'b1;
        @(posedge clk);
        #1;
        if (active !== 1'b1) begin
            $display("[FAIL] dwell 未到 + hide=1 时仍应显示 logo，实际 active=%b", active);
            errors = errors + 1;
        end
        hide = 1'b0;

        feed_frame;

        if (px_seen !== 640 * 480) begin
            $display("[FAIL] 有效像素计数 %0d，应为 307200", px_seen);
            errors = errors + 1;
        end
        if (digest !== exp_digest) begin
            $display("[FAIL] 帧摘要 0x%08x，应为 0x%08x", digest, exp_digest);
            errors = errors + 1;
        end else begin
            $display("INFO frame digest 0x%08x ok", digest);
        end
        if (lit_art !== exp_art) begin
            $display("[FAIL] 上图非黑像素 %0d，应为 %0d", lit_art, exp_art);
            errors = errors + 1;
        end
        if (lit_load !== exp_load) begin
            $display("[FAIL] 加载提示非黑像素 %0d，应为 %0d", lit_load, exp_load);
            errors = errors + 1;
        end

        // 这里已经跑了 >64 拍（dwell 早就到了），有图后必须让位
        hide = 1'b1;
        @(posedge clk);
        #1;
        if (active !== 1'b0) begin
            $display("[FAIL] dwell 已到 + hide=1 时 active 应为 0，实际 %b", active);
            errors = errors + 1;
        end

        if (errors == 0) $display("[PASS] splash_boot frame matches generated ROM");
        else             $display("[FAIL] splash_boot: %0d 项不符", errors);
        $finish;
    end

endmodule
