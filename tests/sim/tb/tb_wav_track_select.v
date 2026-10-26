`timescale 1ns/1ps
// wav_track_select 的契约（换页换曲的唯一决策点）：
//   1) 复位后锁定 PICTURE_1，且**不**产生换页脉冲（否则上电就先 abort 一次）；
//   2) 页号变了 → 等它连续稳定几拍才认，然后只给一个换页脉冲，
//      扇区表跟着换成对应 PICTURE_N；
//   3) 1 拍就消失的毛刺（含 2 bit 二进制码跨位翻转时冒出的中间值）
//      一律不认：不产生脉冲、扇区不变；
//   4) 页号保持不变时不重复产生脉冲（否则每帧都重启一次读取）；
//   5) 换页脉冲宽度 >= 2 拍：1 拍脉宽跨一道同步器容易被漏采。
module tb_wav_track_select;
    localparam [31:0] P1 = 32'd12000;
    localparam [31:0] P2 = 32'd14000;
    localparam [31:0] P3 = 32'd16000;
    localparam [31:0] P4 = 32'd18000;

    reg clk = 0;
    always #5 clk = ~clk;                       // 100 MHz，与 sd_card_clk 一致

    reg        rst = 1;
    reg  [1:0] sel = 2'd0;
    wire [31:0] sector;
    wire        changed;

    wav_track_select #(
        .PICTURE_1 (P1), .PICTURE_2 (P2), .PICTURE_3 (P3), .PICTURE_4 (P4)
    ) dut (
        .I_clk       (clk),
        .I_rst       (rst),
        .I_audio_sel (sel),
        .O_sector    (sector),
        .O_changed   (changed)
    );

    // 换页脉冲统计：上升沿个数 + 每次高电平持续几拍
    integer pulses = 0;
    integer high_cycles = 0;
    integer last_high = 0;
    reg changed_d = 0;
    always @(posedge clk) begin
        if (changed && !changed_d) begin
            pulses = pulses + 1;
            high_cycles = 0;
        end
        if (changed) high_cycles = high_cycles + 1;
        changed_d <= changed;
    end

    task wait_cycles(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge clk);
        end
    endtask

    task expect_sector(input [31:0] want, input [255:0] why);
        begin
            if (sector !== want)
                $fatal(1, "%0s: sector=%0d want %0d", why, sector, want);
        end
    endtask

    task expect_pulses(input integer want, input [255:0] why);
        begin
            if (pulses != want)
                $fatal(1, "%0s: %0d 个换页脉冲，期望 %0d", why, pulses, want);
        end
    endtask

    initial begin
        // ---- 1) 复位：锁 PICTURE_1，且不发脉冲 ----
        wait_cycles(6);
        rst = 1'b0;
        wait_cycles(40);
        expect_sector(P1, "复位后应指向 PICTURE_1");
        expect_pulses(0, "复位不许伪造换页");

        // ---- 2) 正常换页 0 -> 1 ----
        sel = 2'd1;
        wait_cycles(40);
        expect_sector(P2, "页 1 应指向 PICTURE_2");
        expect_pulses(1, "页号变化应产生一个换页脉冲");
        if (high_cycles < 2)
            $fatal(1, "换页脉冲只有 %0d 拍，跨同步器可能被漏采", high_cycles);

        // ---- 3) 跨位跳变 1 -> 3（01 -> 11）----
        sel = 2'd3;
        wait_cycles(40);
        expect_sector(P4, "页 3 应指向 PICTURE_4");
        expect_pulses(2, "1->3 应再产生一个脉冲");

        // ---- 4) 1 拍毛刺（页 2 冒一下又回来）：不许认 ----
        sel = 2'd2;
        wait_cycles(1);
        sel = 2'd3;
        wait_cycles(40);
        expect_sector(P4, "1 拍毛刺不该改扇区");
        expect_pulses(2, "1 拍毛刺不该产生脉冲");

        // ---- 5) 二进制码跨位翻转时会冒出的中间值 00（3->2 途中）：不许认 ----
        sel = 2'd0;
        wait_cycles(1);
        sel = 2'd3;
        wait_cycles(40);
        expect_sector(P4, "中间值 00 不该改扇区");
        expect_pulses(2, "中间值 00 不该产生脉冲");

        // ---- 6) 真换页 3 -> 2 ----
        sel = 2'd2;
        wait_cycles(40);
        expect_sector(P3, "页 2 应指向 PICTURE_3");
        expect_pulses(3, "3->2 应产生一个脉冲");

        // ---- 7) 长时间不变：不许重复脉冲（否则每帧都重启读卡）----
        wait_cycles(200);
        expect_sector(P3, "稳定后扇区不变");
        expect_pulses(3, "页号不变不该重复换页");

        // ---- 8) 复位中途页号是 2：复位后先回 PICTURE_1，再按当前页确认一次 ----
        rst = 1'b1;
        wait_cycles(4);
        rst = 1'b0;
        sel = 2'd2;                              // 复位释放时页号已经是 2
        wait_cycles(40);
        expect_sector(P3, "复位后应重新确认到当前页");
        if (pulses != 4)
            $fatal(1, "复位后重新确认应产生 1 个脉冲，实测总计 %0d", pulses);

        // ---- 9) 回到页 0 ----
        sel = 2'd0;
        wait_cycles(40);
        expect_sector(P1, "页 0 回到 PICTURE_1");

        $display("PASS: wav_track_select 页号→扇区/换页脉冲");
        $finish;
    end
endmodule
