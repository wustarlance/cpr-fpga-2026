`timescale 1ns/1ps
//=============================================================================
// tb_contrast_controls —— 对比度档位的契约（2026-10-26 只剩 K6 一路）
//-----------------------------------------------------------------------------
// 检查项：
//   1) 复位后 = 3'd3（100 %，恒等直通），不因为按键悬空/上电沿乱跳；
//   2) 按一次前进一档：3→4→5→1→2→3
//      （50 %、75 %、100 %、125 %、150 % 五档循环）；
//   3) 短于消抖窗口（STABLE_MS 个 tick）的毛刺不算一次按键；
//   4) 开关通路已经删除：本 TB 不再给 raw_switches 任何激励 —— 如果哪天有人
//      把 SW1..3 的绝对译码接回来，端口会变，这个 TB 编译就过不去。
//=============================================================================
module tb_contrast_controls;
    reg clk=0, rst_n=0;
    reg raw_key=0;
    wire [2:0] level;
    reg [3:0] divider=0;
    wire tick_ms = (divider==9);          // 10 个 clk = 1 ms
    always #5 clk=~clk;
    always @(posedge clk) divider <= (divider==9) ? 4'd0 : divider+4'd1;

    contrast_controls #(.STABLE_MS(3)) dut(
        .clk(clk), .rst_n(rst_n), .tick_ms(tick_ms),
        .raw_key(raw_key), .contrast_level(level));

    // 按一次（按下保持够长 → 松开，也等到稳定）
    task press_key;
        begin
            @(negedge clk); raw_key=1;
            repeat(80) @(negedge clk);
            raw_key=0;
            repeat(80) @(negedge clk);
        end
    endtask

    // 毛刺：只按 2 个 tick（20 clk），短于 STABLE_MS=3
    task glitch_key;
        begin
            @(negedge clk); raw_key=1;
            repeat(20) @(negedge clk);
            raw_key=0;
            repeat(80) @(negedge clk);
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        repeat(10) @(negedge clk);
        if (level !== 3'd3) $fatal(1, "复位后应为 100%% 档 3，实测 %0d", level);

        // ---- 毛刺不算按键 ----
        glitch_key();
        if (level !== 3'd3) $fatal(1, "2 个 tick 的毛刺改动了档位（%0d）", level);

        // ---- 逐档前进 + 回卷 ----
        press_key(); if (level !== 3'd4) $fatal(1, "第 1 次按键应到 125%%，实测 %0d", level);
        press_key(); if (level !== 3'd5) $fatal(1, "第 2 次按键应到 150%%，实测 %0d", level);
        press_key(); if (level !== 3'd1) $fatal(1, "第 3 次按键应回卷到 50%%，实测 %0d", level);
        press_key(); if (level !== 3'd2) $fatal(1, "第 4 次按键应到 75%%，实测 %0d", level);
        press_key(); if (level !== 3'd3) $fatal(1, "第 5 次按键应回到 100%%，实测 %0d", level);

        // ---- 异步复位：任何档位都回 100% ----
        press_key();                       // 100% -> 125%
        if (level !== 3'd4) $fatal(1, "复位前应停在 125%%，实测 %0d", level);
        #2 rst_n=0; #1;
        if (level !== 3'd3) $fatal(1, "异步复位应立刻回 100%%（3），实测 %0d", level);
        #1 rst_n=1; repeat(10) @(negedge clk);
        if (level !== 3'd3) $fatal(1, "复位释放后应仍为 100%%（3），实测 %0d", level);

        $display("PASS: tb_contrast_controls 只剩 K6 逐档步进（SW1~3 已下线）");
        $finish;
    end
    always @(negedge clk) if(rst_n && level===0) $fatal(1,"0 percent became selectable");
    initial begin #200000; $fatal(1,"tb_contrast_controls TIMEOUT"); end
endmodule
