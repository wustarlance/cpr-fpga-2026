// 合并已归一为高有效的板载和面板按键。
// bit0..5 依次为模式、上一页、下一页、亮度、清场、字幕。
// 未连接的上拉输入应在顶层反相为 0；字幕位仅由面板 K7 提供。
module key_source_merge(
    input  wire [5:0] onboard_keys,   // 已反相：1 = 按下
    input  wire [5:0] panel_keys,     // 已反相：1 = 按下
    output wire [5:0] keys
);
    assign keys = onboard_keys | panel_keys;
endmodule
