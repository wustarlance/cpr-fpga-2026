# TD 6.2.168116 验收排查

当前严格验收仍为 **failed**。本轮使用用户现有 TD 6.2.168116 / EG4S20BG256，在 D123 基础上完成 `top`、`top_adc` 的综合、布局、布线、Slow/Fast 两角 setup/hold 分析与位流生成。没有下载这轮位流，也没有更改 RTL、PLL、引脚或已有白线保护参数。工具升级不是本轮验收前提。

## 已修正的约束问题

页面状态与 ADC 邮箱原来将 `get_regs` 结果先存进 Tcl 变量，再在 SDC 中引用变量。本机 TD 回放这类约束时，页面邮箱报告为“没有路径”，40 ns 最大数据延迟边界实际未绑定。本轮改成内联端点查询，保留原来的 40 ns 边界，没有扩大时序例外范围。

`build.tcl` 同时按本机 SWUG105 的 single-run 流程，在 `legalize_phy_inst` 后重新读入公共、选定顶层及 FIFO SDC。新增 gate/place/route QoR、最终时钟交互和时序例外报告，并保存物理检查点用于只读分析。EG4 本版本不支持 `report_clock_utilization`，时钟实际布线以日志中的 CTS Local Wire Summary 为证。

| 本轮结果 | top | top_adc |
|---|---:|---:|
| Setup WNS | +0.103 ns | +0.141 ns |
| Hold WNS | +0.004 ns | +0.011 ns |
| Setup / Hold TNS | 0 / 0 | 0 / 0 |
| 未绑定路径的约束 | 0 | 0 |
| 页面邮箱最大延迟 Total / Dominated | 24 / 24 | 24 / 24 |
| ADC 邮箱最大延迟 Total / Dominated | 不使用 | 24 / 24 |
| 两组 FIFO Gray 最大延迟 | 各 36 / 36 | 各 36 / 36 |
| Shadowed / Ignored | 0 / 0 | 0 / 0 |
| STA coverage（工具报告） | 99.65% | 99.67% |
| 严重告警条数 | 5 | 6 |
| 严格验收 | failed | failed |

时序例外摘要中帧发布邮箱的计数为0，不能据此断言它未绑定；对保存的路由检查点单独查询该路径，可得到2个有效终点、25 ns datapath-only预算与正余量。页面邮箱原来的两条“no path”诊断则已在本轮消失。

结构化结果与位流哈希见 [验证记录](td-acceptance-20261023.json)。已有 D123 实板结果属于先前位流，不能移作本轮新位流的上板证据。

## 尚未解决的验收项

1. **USR-6135：三个 PLL 的 Normal / CLKC0_EXT 反馈被报告为本地网络。**
   在只包含原三个 PLL 和计数器的最小工程中，仍复现三个相同告警；指定有效物理网名并要求专用时钟路由后仍复现。最小工程没有 SDRAM、HDMI 和训练逻辑。它说明告警可独立复现，不能证明告警可豁免，也不能证明完整产品时钟补偿可靠。需要针对当前6.2.168116版本，确认支持的反馈连接/约束及实际专用反馈路径。
2. **PHY-5079：SDRAM 转发时钟有本地布线。**
   已定位到 `U3/u2_ram/SDRAM_CLK` 通往封装内 SDRAM 时钟输出 IOL 的连接。离线最小实验使用本机原语库支持的 ODDR 输出后，可消除该布线告警；但最初正余量同时伴随缺失时钟与覆盖率下降。补充生成时钟的实验恢复了数据路径覆盖，却仍有时钟根检查问题和负 setup。因此整个 ODDR 尝试未进入产品，不能报告为修复。
3. **PHY-7002：内置 SDRAM 宏的初始位置在 ECO 阶段被重定位。**
   `top`一次、`top_adc`两次；需要核对宏的合法位置及该版本的物理映射。位流成功生成不能自动证明该诊断无害。
4. **接口与结构审查。**
   两个顶层都报告19个输入无接口延迟、29个输出无接口延迟、32项封装内SDRAM输入延迟异常提示。2026-10-24逐项核对发现，dangling摘要中的3/4实际对应模型分组数，明细分别列出458/537个原语引脚，不能称为3/4个悬空引脚，也不能直接等同于458/537项功能故障。默认`USE_EXTERNAL_IO=0`时，9个外接输入不参与应用逻辑；按键/拨码经同步滤波，LED/数码管属于状态输出。上述事实需要按端口和最终配置记录，不能给所有端口填任意延迟来消除提示。SD SPI、HDMI DDC/串行输出及封装内SDRAM参考时钟关系仍需相应接口/IP依据。
5. **SDRAM运行条件。**
   APUG011_1.2对连续写入给出至少64 MHz的要求；本工程仍使用实板验证过的40 MHz有限突发配置。64拍保护是实验值，对文档适用范围的疑问仍未解决。本轮没有擅自改变时钟或用物理DQ多周期例外掩盖它。

本轮在PLL和SDRAM时钟问题上保留了不收敛的最小实验与原始诊断，没有继续试加无依据的时序例外。下一步应针对当前工具版本核实上述具体连接和工作条件，再实施有依据的修正。

## 验收脚本的门禁

`verify_td.py`现在拒绝所有ERROR/FATAL/CRITICAL-WARNING，单独保留重定位观察信息但不自动豁免。成功构建后，额外调用`td_report_checks.py`检查完整的约束摘要、缺失时钟、未绑定路径、失效约束、FIFO Gray边界与所用邮箱边界。接口延迟和dangling节点需明确审查时，返回`needs_review`，不会自动通过完整验收。

本次两顶层布局布线由原运行器执行；新的覆盖检查随后对保留的原始报告独立复核，两者均为`blocking=0, review=4`。新的运行器报告复制、旧位流拒绝及诊断门禁通过10项Python自检；没有声称修改后的运行器又完整重跑了两遍实现。RTL未变，本轮没有重复全部功能仿真。

以上为首轮历史记录。随后已用修改后的运行器完整重跑两个顶层，见[2026-10-24续查记录](td-acceptance-followup-20261024.md)；本文件配套JSON保留首轮事实与哈希。

复现完整构建（不会操作板卡）：

```powershell
python project/verify_td.py --td "E:/BaiduNetdiskDownload/HX4S20_Contest_202606/anlu/td/bin/td_commands_prompt.exe" --tops top top_adc --stage full --timeout 1200
```

单独复核已有报告，`--output`必须使用新文件：

```powershell
python project/td_report_checks.py --check project/build/top/timing_check.rpt --top top --output review-top.json
python -m unittest discover -s tests -p test_td_report_checks.py -v
```

`project/build/verify_<UTC时间>/`保留该次报告和结果；更新后的运行器也会复制该次位流与补充报告，避免后续构建覆盖。`.rpt/.qor/.log/.bit/.db`保留在本地证据目录，不提交到Git；仓库只保存源码、测试、摘要和哈希。
