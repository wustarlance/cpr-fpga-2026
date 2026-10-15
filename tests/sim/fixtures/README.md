# 独立期望表

sd_crc_sector.mem：512项测试数据 `(13*i+7) & 255`，再接CRC高、低两字节（56 ed），共514项。CRC由Python标准库 `binascii.crc_hqx(data, 0)` 独立计算；SD命令自检同时验证字节顺序、成功CRC和故意损坏CRC。

contrast_golden.mem：索引level*256+x，2048项8位期望值，按契约的Python整数向下取整生成。
glyph5x7_golden.mem：索引ASCII码，256项35位；从固定版本原glyph函数解析7行位图，默认空白。
scroll_text_ascii.mem：32项8位ASCII，只用于接口/字形测试。

training_panel_golden.mem：4组×15行×14列ASCII，依次为普通演示、普通ADC、告警演示、告警ADC。固定期望字符串与分区几何来自显示契约，详见training_panel_layout.json；不读取DUT内部字符、坐标、BCD或评级信号来计算期望结果。

测试使用原始表，不能在发现失败后修改表去匹配实现。字体位图一致性不证明新滚动逻辑正确，须另做坐标/计数参考检查。
