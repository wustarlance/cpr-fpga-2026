// 按键来源合并：板载 KEY 与外接八位按键面板并存。
//
// cpr_control 的 raw_keys[4:0] 含义固定：bit0 模式、bit1 上一页、bit2 下一页、
// bit3 亮度、bit4 清除训练。本模块只负责把多个来源按位相或，全部转成高有效。
//
// 两个来源都带内部上拉（pin.adc 里 PULLTYPE = PULLUP），未接时读高电平，
// 反相后为 0，因此"没有接某个来源"不会产生误触。
module key_source_merge(
    input  wire [4:0] onboard_keys,   // 已反相：1 = 按下
    input  wire [4:0] panel_keys,     // 已反相：1 = 按下
    output wire [4:0] keys
);
    assign keys = onboard_keys | panel_keys;
endmodule
