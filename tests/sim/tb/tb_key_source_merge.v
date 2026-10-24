`timescale 1ns/1ps
// 板载 KEY 与外接八位面板并存：任何一个来源按下都必须被看到，互不屏蔽。
module tb_key_source_merge;
    reg [4:0] onb, panel;
    wire [4:0] keys;
    key_source_merge u(.onboard_keys(onb), .panel_keys(panel), .keys(keys));

    integer i;
    initial begin
        // 全松开
        onb = 5'b00000; panel = 5'b00000; #1;
        if (keys !== 5'b00000) $fatal(1, "idle must be all clear");
        // 板载单独
        for (i = 0; i < 5; i = i + 1) begin
            onb = 5'b00001 << i; panel = 5'b00000; #1;
            if (keys !== (5'b00001 << i)) $fatal(1, "onboard bit %0d lost", i);
        end
        // 面板单独
        for (i = 0; i < 5; i = i + 1) begin
            onb = 5'b00000; panel = 5'b00001 << i; #1;
            if (keys !== (5'b00001 << i)) $fatal(1, "panel bit %0d lost", i);
        end
        // 两个来源同时按下：按位相或，一个都不能丢
        onb = 5'b00101; panel = 5'b01010; #1;
        if (keys !== 5'b01111) $fatal(1, "merge must OR both sources, got %b", keys);
        // 同一功能两处同按
        onb = 5'b00100; panel = 5'b00100; #1;
        if (keys !== 5'b00100) $fatal(1, "same function from both sources");
        // 全部按下
        onb = 5'b11111; panel = 5'b11111; #1;
        if (keys !== 5'b11111) $fatal(1, "all pressed");
        $display("PASS tb_key_source_merge onboard+panel coexist per bit");
        $finish;
    end
endmodule
