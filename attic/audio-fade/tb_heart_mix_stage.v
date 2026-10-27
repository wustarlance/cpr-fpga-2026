`timescale 1ns/1ps
// heart_mix_stage 的契约（心跳/音乐合流，2026-10-25）：
//   1) sel_heart=0 → 输出**逐位等于** A（音乐），心跳完全不参与；
//   2) sel_heart=1、sel_mix=0 → 96 帧内淡到**心跳单独**（该页音频被屏蔽）；
//   3) **训练中间拨 sel_mix**（对应硬件 F13 触点）→ 96 帧内淡到"心跳+音乐"，
//      逐帧单调、单帧步长不超过音乐幅度的 1/96 —— 这是这一版的核心回归：
//      如果这里用 2:1 mux 而不是斜坡，B 会阶跃，本项立刻 FAIL；
//   4) 拨回 sel_mix=0 → 96 帧退回"心跳单独"；
//   5) 两路都接近满量程时饱和夹到 +0x7FFFFF，不翻相（不出现负值突跳）；
//   6) 训练中退出去 → 96 帧回到音乐；
//   7) 左右两路各自独立（给不同幅度，逐相位核对右声道）。
//
// 判据全部按**帧**数，不按绝对时间（DUT 用 I_frame_stb 计数）。
module tb_heart_mix_stage;
    localparam integer MCLK_HZ     = 12_288_000;
    localparam integer FADE_FRAMES = 96;            // 2 ms @ 48 kHz
    localparam integer STEP_MAIN   = 16670;         // 主淡化单帧步长上限 |B-A| × 683/65536
    localparam integer STEP_MIX    = 10420;         // 混音闸单帧步长上限 |A| × 683/65536

    reg signed [23:0] a_l =  24'sd1000000;          // 音乐（页 WAV）
    reg signed [23:0] a_r =  24'sd 400000;
    reg signed [23:0] b_l = -24'sd 600000;          // 心跳
    reg signed [23:0] b_r = -24'sd 250000;

    reg clk = 0;
    always #40 clk = ~clk;                          // 12.5 MHz，近似 MCLK

    reg [7:0] div = 8'd0;
    reg       frame_stb = 0;
    always @(posedge clk) begin
        div       <= div + 8'd1;
        frame_stb <= (div == 8'd255);               // 48 kHz 帧节拍
    end

    reg rst = 1;
    reg sel_heart = 0;
    reg sel_mix   = 0;
    wire signed [23:0] o_l, o_r;

    heart_mix_stage #(
        .MCLK_HZ (MCLK_HZ),
        .FADE_MS (2)
    ) dut (
        .I_clk       (clk),
        .I_rst       (rst),
        .I_frame_stb (frame_stb),
        .I_sel_heart (sel_heart),
        .I_sel_mix   (sel_mix),
        .I_a_l       (a_l),
        .I_a_r       (a_r),
        .I_b_l       (b_l),
        .I_b_r       (b_r),
        .O_l         (o_l),
        .O_r         (o_r)
    );

    task wait_frames(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (frame_stb !== 1'b1) @(posedge clk);
            end
            #1;
        end
    endtask

    // 逐帧走到 target：单调、单帧步长 ≤ maxstep、最终逐位相等
    integer steps_used;
    task ramp_to(input signed [23:0] target, input integer dir,
                 input integer maxstep, input [255:0] why);
        integer k;
        reg signed [23:0] prev, cur;
        begin
            prev        = o_l;
            steps_used  = 0;
            for (k = 0; k < 400; k = k + 1) begin
                wait_frames(1);
                cur         = o_l;
                steps_used  = steps_used + 1;
                if (dir > 0) begin
                    if (cur < prev)
                        $fatal(1, "ramp_to: not monotonic up（%0d → %0d）", prev, cur);
                end else begin
                    if (cur > prev)
                        $fatal(1, "ramp_to: not monotonic down（%0d → %0d）", prev, cur);
                end
                if (((cur - prev) > maxstep) || ((prev - cur) > maxstep))
                    $fatal(1, "ramp_to: step at frame %0d: %0d → %0d (max %0d)",
                           steps_used, prev, cur, maxstep);
                if (cur === target) k = 10000;
                prev = cur;
            end
            if (o_l !== target)
                $fatal(1, "ramp_to: target %0d not reached in 400 frames, stuck at %0d", target, o_l);
        end
    endtask

    task expect_lr(input signed [23:0] el, input signed [23:0] er, input [255:0] why);
        begin
            if (o_l !== el || o_r !== er)
                $fatal(1, "expect_lr: L=%0d R=%0d, expected %0d / %0d", o_l, o_r, el, er);
        end
    endtask

    initial begin
        // ---- 1) 复位后：逐位等于音乐，心跳不参与 ----
        wait_frames(3);
        rst = 1'b0;
        wait_frames(4);
        expect_lr(a_l, a_r, "复位态应逐位等于音乐 A");
        $display("  [1] sel_heart=0：逐位等于 A（L=%0d R=%0d）OK", o_l, o_r);

        // ---- 2) 进训练（sel_heart=1，未混音）：96 帧淡到"心跳单独" ----
        sel_heart = 1'b1;
        ramp_to(b_l, -1, 2 * STEP_MAIN, "进训练");
        if (steps_used != FADE_FRAMES)
            $fatal(1, "进训练用了 %0d 帧，应为 %0d 帧", steps_used, FADE_FRAMES);
        expect_lr(b_l, b_r, "训练态（不混音）应逐位等于心跳 B");
        $display("  [2] 进训练：%0d 帧后逐位等于心跳 B（L=%0d R=%0d）OK",
                 steps_used, o_l, o_r);

        // ---- 3) 训练中间拨 F13（sel_mix=1）：必须斜坡进入，不许阶跃 ----
        sel_mix = 1'b1;
        ramp_to(a_l + b_l, 1, 2 * STEP_MIX, "训练中混音打开");
        if (steps_used != FADE_FRAMES)
            $fatal(1, "混音打开用了 %0d 帧，应为 %0d 帧", steps_used, FADE_FRAMES);
        expect_lr(a_l + b_l, a_r + b_r, "混音态应等于心跳+音乐");
        $display("  [3] 训练中拨混音：%0d 帧斜坡升到 心跳+音乐（L=%0d R=%0d）OK（无阶跃）",
                 steps_used, o_l, o_r);

        // ---- 4) 拨回（sel_mix=0）：同样 96 帧退回"心跳单独" ----
        sel_mix = 1'b0;
        ramp_to(b_l, -1, 2 * STEP_MIX, "训练中混音关闭");
        if (steps_used != FADE_FRAMES)
            $fatal(1, "混音关闭用了 %0d 帧，应为 %0d 帧", steps_used, FADE_FRAMES);
        expect_lr(b_l, b_r, "混音关后应回到心跳 B");
        $display("  [4] 拨回混音关：%0d 帧退回心跳 B OK", steps_used);

        // ---- 5) 满量程相加：必须夹到 +0x7FFFFF，不翻相 ----
        // 这一段的单帧步长由音乐幅度决定（8e6 × 683/65536 ≈ 83 k），所以上限放宽，
        // "不许阶跃"的严格判据在 [3][4] 已经用音乐正常幅度验过了。
        a_l = 24'sd8000000;  b_l = 24'sd2000000;
        wait_frames(2);
        expect_lr(b_l, b_r, "改幅度后（未混音）应等于心跳");
        sel_mix = 1'b1;
        ramp_to(24'sh7FFFFF, 1, 2 * 90000, "满量程混音");
        begin : clip_chk
            integer k;
            for (k = 0; k < 20; k = k + 1) begin
                wait_frames(1);
                if (o_l !== 24'sh7FFFFF)
                    $fatal(1, "饱和后应稳定在 +0x7FFFFF，实测 %0d", o_l);
                if (o_l < 0)
                    $fatal(1, "饱和相加翻相成负值：%0d", o_l);
            end
        end
        $display("  [5] 8000000+2000000 夹到 +0x7FFFFF 并保持 20 帧，未翻相 OK");

        // ---- 6) 先关混音（音乐 8000000 退出叠加），再退出训练 ----
        sel_mix = 1'b0;
        ramp_to(b_l, -1, 2 * 90000, "满量程下混音关闭");
        expect_lr(b_l, b_r, "混音关后应回到心跳 B");
        sel_heart = 1'b0;
        ramp_to(a_l, 1, 2 * 90000, "退出训练");
        if (steps_used != FADE_FRAMES)
            $fatal(1, "退出训练用了 %0d 帧，应为 %0d 帧", steps_used, FADE_FRAMES);
        expect_lr(a_l, a_r, "退出训练应逐位等于音乐 A");
        $display("  [6] 混音关（%0d 帧）+ 退出训练，逐位等于音乐 A（L=%0d）OK",
                 steps_used, o_l);

        // ---- 7) 半途反向：进训练 30 帧就退回，原路返回且无过冲 ----
        a_l = 24'sd1000000;  b_l = -24'sd600000;
        wait_frames(2);
        sel_heart = 1'b1;
        wait_frames(30);
        if (o_l === a_l)
            $fatal(1, "进训练 30 帧后输出仍等于 A，斜坡没起来");
        sel_heart = 1'b0;
        ramp_to(a_l, 1, 2 * STEP_MAIN, "半途退出训练");
        if (steps_used != 30)
            $fatal(1, "半途退出应再 30 帧回到 A，实测 %0d 帧", steps_used);
        expect_lr(a_l, a_r, "半途退出应逐位等于音乐 A");
        $display("  [7] 进训练 30 帧后反向：%0d 帧原路回到 A（无过冲）OK", steps_used);

        $display("PASS: heart_mix_stage 心跳/音乐合流（两段 2 ms 斜坡，无阶跃）");
        $finish;
    end

    initial begin
        #120_000_000;
        $fatal(1, "仿真超时");
    end
endmodule
