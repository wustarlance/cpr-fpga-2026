`timescale 1ns/1ps
// audio_crossfade 的契约（训练进出时"不咔哒"的唯一保证）：
//   1) sel=0 且 α 已到底时，输出**逐位等于** A（不是"接近"，不能被淡化污染）；
//   2) sel=1 后，输出在 96 帧（= 2 ms @ 48 kHz）内线性走到 B，一帧不多一帧不少；
//   3) sel 退回 0 时同样 96 帧走回 A；
//   4) 全过程单调、无过冲：不能越过 A/B 的边界，也不能出现单帧跳变；
//   5) 淡到一半就反向（训练模式被快速切进切出）也要原路退回，不能"跳到底"；
//   6) 左右声道各自独立（这里给两个不同的常量，端点分开验，防接反）。
//
// 判据全部按**帧**数，不按绝对时间：DUT 内部用 I_frame_stb 计数，
// 所以仿真里的节拍周期只要远小于 2 ms 就不影响帧数结论。
module tb_audio_crossfade;
    localparam integer MCLK_HZ     = 12_288_000;
    localparam integer FADE_FRAMES = 96;            // 2 ms @ 48 kHz
    localparam integer STEP_NOM    = 16670;         // 标称单帧步长 = 1.6e6 × 683 / 65536

    localparam signed [23:0] A_L =  24'sd1000000;   // 常态音源（WAV）左
    localparam signed [23:0] A_R =  24'sd 400000;   // 常态音源右（故意不同）
    localparam signed [23:0] B_L = -24'sd 600000;   // 心跳源左
    localparam signed [23:0] B_R = -24'sd 250000;   // 心跳源右

    reg clk = 0;
    always #40 clk = ~clk;                          // 12.5 MHz，近似 MCLK

    // 48 kHz 帧节拍：MCLK/256（与 pcm_frame_tick 同一关系）
    reg [7:0] div = 8'd0;
    reg       frame_stb = 0;
    always @(posedge clk) begin
        div       <= div + 8'd1;
        frame_stb <= (div == 8'd255);
    end

    reg rst = 1;
    reg sel = 0;
    wire signed [23:0] o_l, o_r;
    wire               mixing;

    audio_crossfade #(
        .MCLK_HZ (MCLK_HZ),
        .FADE_MS (2)
    ) dut (
        .I_clk       (clk),
        .I_rst       (rst),
        .I_frame_stb (frame_stb),
        .I_sel       (sel),
        .I_a_l       (A_L),
        .I_a_r       (A_R),
        .I_b_l       (B_L),
        .I_b_r       (B_R),
        .O_l         (o_l),
        .O_r         (o_r),
        .O_mixing    (mixing)
    );

    // ---- 等 n 个帧节拍（对齐到 frame_stb 那一拍之后，取到的是新 α 的结果）----
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

    integer used_up, used_dn, used_mid;

    initial begin
        // ---- 1) 复位/静默态：输出必须逐位等于 A ----
        wait_frames(3);
        rst = 1'b0;
        wait_frames(5);
        if (o_l !== A_L || o_r !== A_R)
            $fatal(1, "复位/静默态输出不是 A：L=%0d R=%0d（应 %0d / %0d）",
                   o_l, o_r, A_L, A_R);
        if (mixing !== 1'b0)
            $fatal(1, "α=0 时 O_mixing 不该为 1");
        $display("  [1] α=0 逐位等于 A（L=%0d R=%0d）OK", o_l, o_r);

        // ---- 2) 上爬：sel=1，96 帧走到 B ----
        sel = 1'b1;
        used_up = 0;
        begin : up_loop
            integer k;
            reg signed [23:0] prev, cur;
            prev = o_l;                                  // = A
            for (k = 0; k < 300; k = k + 1) begin
                wait_frames(1);
                cur  = o_l;
                used_up = used_up + 1;
                if (cur > prev)
                    $fatal(1, "上爬不单调：第 %0d 帧 %0d → %0d", used_up, prev, cur);
                if ((prev - cur) > 2 * STEP_NOM)
                    $fatal(1, "上爬第 %0d 帧跳变 %0d → %0d（超过 2 倍标称步长）",
                           used_up, prev, cur);
                if (cur < B_L)
                    $fatal(1, "上爬越过 B：%0d < %0d", cur, B_L);
                if (cur === B_L) begin
                    k = 1000;                            // 到了就退出
                    prev = cur;
                end
                prev = cur;
            end
        end
        if (used_up != FADE_FRAMES)
            $fatal(1, "上爬用了 %0d 帧，应为 %0d 帧（2 ms）", used_up, FADE_FRAMES);
        if (o_l !== B_L || o_r !== B_R)
            $fatal(1, "上爬结束应逐位等于 B：L=%0d R=%0d（应 %0d / %0d）",
                   o_l, o_r, B_L, B_R);
        if (mixing !== 1'b0)
            $fatal(1, "α 满时 O_mixing 应为 0");
        $display("  [2] sel=1：%0d 帧（2 ms）后逐位等于 B（L=%0d R=%0d）OK",
                 used_up, o_l, o_r);

        // ---- 3) 停在 B：不许自己漂 ----
        wait_frames(10);
        if (o_l !== B_L) $fatal(1, "α 满后输出漂了：%0d", o_l);
        $display("  [3] α 满后 10 帧保持 B OK");

        // ---- 4) 下爬：sel=0，96 帧走回 A ----
        sel = 1'b0;
        used_dn = 0;
        begin : dn_loop
            integer k;
            reg signed [23:0] prev, cur;
            prev = o_l;                                  // = B
            for (k = 0; k < 300; k = k + 1) begin
                wait_frames(1);
                cur = o_l;
                used_dn = used_dn + 1;
                if (cur < prev)
                    $fatal(1, "下爬不单调：第 %0d 帧 %0d → %0d", used_dn, prev, cur);
                if ((cur - prev) > 2 * STEP_NOM)
                    $fatal(1, "下爬第 %0d 帧跳变 %0d → %0d", used_dn, prev, cur);
                if (cur > A_L)
                    $fatal(1, "下爬越过 A：%0d > %0d", cur, A_L);
                if (cur === A_L) k = 1000;
                prev = cur;
            end
        end
        if (used_dn != FADE_FRAMES)
            $fatal(1, "下爬用了 %0d 帧，应为 %0d 帧", used_dn, FADE_FRAMES);
        if (o_l !== A_L || o_r !== A_R)
            $fatal(1, "下爬结束应逐位等于 A：L=%0d R=%0d", o_l, o_r);
        $display("  [4] sel=0：%0d 帧后逐位等于 A OK", used_dn);

        // ---- 5) 半途反向：爬 30 帧就退回，必须原路回去且不过冲 ----
        sel = 1'b1;
        wait_frames(30);
        if (o_l === A_L)
            $fatal(1, "爬 30 帧后输出仍等于 A，斜坡没有起来");
        used_mid = 0;
        begin : mid_loop
            integer k;
            reg signed [23:0] prev, cur;
            prev = o_l;
            sel  = 1'b0;
            for (k = 0; k < 300; k = k + 1) begin
                wait_frames(1);
                cur = o_l;
                used_mid = used_mid + 1;
                if (cur < prev)
                    $fatal(1, "半途反向后继续下降：%0d → %0d", prev, cur);
                if (cur > A_L)
                    $fatal(1, "半途反向越过 A：%0d > %0d", cur, A_L);
                if (cur === A_L) k = 1000;
                prev = cur;
            end
        end
        if (used_mid != 30)
            $fatal(1, "半途反向（已爬 30 帧）应再 30 帧回到 A，实测 %0d 帧", used_mid);
        $display("  [5] 淡化中途反向：%0d 帧原路回到 A（无过冲）OK", used_mid);

        $display("PASS: audio_crossfade 2 ms 线性交叉淡化（96 帧）");
        $finish;
    end

    // 超时保护：有任何一帧卡住都要报错，而不是挂死
    initial begin
        #40_000_000;
        $fatal(1, "仿真超时");
    end
endmodule
