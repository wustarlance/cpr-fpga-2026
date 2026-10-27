`timescale 1ns/1ps
// 板载 KEY 与外接八位面板并存：任何一个来源按下都必须被看到，互不屏蔽。
module tb_key_source_merge;
    reg [5:0] onb, panel;
    wire [5:0] keys;
    key_source_merge u(.onboard_keys(onb), .panel_keys(panel), .keys(keys));

    integer i;
    initial begin
        // 全松开
        onb = 6'b000000; panel = 6'b000000; #1;
        if (keys !== 6'b000000) $fatal(1, "idle must be all clear");
        // 板载单独
        for (i = 0; i < 6; i = i + 1) begin
            onb = 6'b000001 << i; panel = 6'b000000; #1;
            if (keys !== (6'b000001 << i)) $fatal(1, "onboard bit %0d lost", i);
        end
        // 面板单独
        for (i = 0; i < 6; i = i + 1) begin
            onb = 6'b000000; panel = 6'b000001 << i; #1;
            if (keys !== (6'b000001 << i)) $fatal(1, "panel bit %0d lost", i);
        end
        // K7 = bit5（字幕开关）必须能从面板进来，且不被板载那 5 位挤掉
        onb = 6'b000000; panel = 6'b100000; #1;
        if (keys !== 6'b100000) $fatal(1, "panel K7 (subtitle) lost: %b", keys);
        // 两个来源同时按下：按位相或，一个都不能丢
        onb = 6'b000101; panel = 6'b110010; #1;
        if (keys !== 6'b110111) $fatal(1, "merge must OR both sources, got %b", keys);
        // 同一功能两处同按
        onb = 6'b000100; panel = 6'b000100; #1;
        if (keys !== 6'b000100) $fatal(1, "same function from both sources");
        // 全部按下
        onb = 6'b111111; panel = 6'b111111; #1;
        if (keys !== 6'b111111) $fatal(1, "all pressed");
        $display("PASS tb_key_source_merge onboard+panel coexist per bit");
        $finish;
    end
endmodule
