# 安路 TD 开发工具 · Linux 版获取速查

> 抓取日期：2026-09-12
> 来源：安路官网「服务支持 → 工具与资料下载」的真实后端接口（页面是 JS 渲染的，直链不在 HTML 里）

---

## ⚠️ 本机现状（2026-09-18 更新）

**本节优先于下文。** 下文是官网下载信息（仍然有效），但"本机装的是什么"已经变了：

| 项目 | 现状 |
|---|---|
| 本机在用的版本 | **TD 6.2.1 SP1（178840）**，装在 **工作区内** `../.tools/anlogic-td/TD_6.2.1_SP1_178840_NL/` |
| 为什么不在 `/opt` | 助手所在沙箱把 `/` 只读挂载且 `sudo` 被 `no_new_privs` 封死，`/opt` 动不了 —— **只影响助手，不影响你自己的终端** |
| 怎么启动 | 系统命令 **`td`** 已经是 6.2.1（`/usr/local/bin/td` 已转发到 `../.tools/td`） |
| TD 6.2.3 | ✅ **已卸载**（`/opt/anlogic-td` 整个目录已移除，回收 2.7 GB）；原启动器备份为 `/usr/local/bin/td.bak-623` |
| 安装包 | ✅ 已删除（回收 1.9 GB）；需重下见下文直链 |
| 验收状态 | ✅ 已端到端自检通过（综合→布局布线→位流，许可证正常签出） |
| 磁盘 | ✅ 14 GB 可用（86%） |

**📄 完整记录见 `04_环境与工具/TD6.2.1安装记录与自检.md`** —— 含环境真相、安装步骤、自检证据、GPIO 坑。

### 🔴 官网标签错位（下文第二节的坑）

官网 2025-09-26 那批有**两个** 6.2.1 文件，**列表标签和实际下载内容是对调的**：

| 官网条目 | 列表显示 | 实际下载到 | SHA-256 |
|---|---|---|---|
| `data-id=1111` | `TD_6.2.1_Release_175876_NL.zip` | **`TD_6.2.1_SP1_178840_NL.zip`** | `c5917d6ae54e118e0b607063e4612d5ae21ab8bfb5b4a4988b28f67160b86839` |
| `data-id=1107` | （无标签） | `TD_6.2.1_Release_175876_NL.zip` | `2bb8d82947c205617268961b37650203ea90c73a348f227bc03e4c904c6408c2` |

直链：

```
# 6.2.1 SP1（178840）—— 本机装的这个
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_6.2.1_SP1_178840_NL.zip

# 6.2.1 Release（175876）—— 真正的 9 月首发版，本机没有
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_6.2.1_Release_175876_NL.zip
```

> ⏳ **待确认**：比赛说"统一 6.2.1"，是否接受 **SP1（178840）**。两者大版本号都是 6.2.1，建议问一下组委会。

---

## 一、结论速览

| 项目 | 结果 |
|---|---|
| U 盘里有什么 | **只有 Windows 版**（`TD_6.2.1_Engineer_168116.exe`），无任何 Linux 文件 |
| Linux 版存在吗 | **存在**，官网有独立的 Linux 分类 |
| 最新 Linux 版 | **TD 6.2.3**（`TD_Release_2026.2_NL.zip`），2026-09-11 发布 |
| 比你套件的版本 | 更新（套件是 6.2.1） |
| 文件大小 | **约 1.87 GB**（2,007,853,391 字节） |
| 许可证 | **U 盘里那份就能用**，有效期到 2029-08-17，`HOST_ID = ANY` |

---

## 二、下载直链

### 1. TD 主程序（Linux 版）

**最新：TD 6.2.3**

```
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_Release_2026.2_NL.zip
```

- 版本：TD6.2.3（内部号 210850）
- 日期：2026-09-11
- 大小：2,007,853,391 字节（≈ 1.87 GB）
- SHA-256：`e624280f5bbfca3d685e8527c26a45f46ae1a6f534974fb759f4d182d604de4d`

**备选：TD 6.2.2**

```
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_Release_2026.1_SP3_NL.zip
```

- 版本：TD6.2.2（210004），日期 2026-09-03

### 2. 下载工具 BW（Linux 版，43 MB）

```
https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/工具与资料下载/软件工具/下载工具/DSAD64Eadsae54a/BW_1.0.0_154147.zip
```

- SHA-256：`27e86e75490e34ac581fe39ce9c09e3c325bbd9f5fc8cb1c1cb07482a70a5e86`
- 日期：2025-03-21

> **注意**：下载时 URL 里的中文和空格会被 curl 拒绝，需要用 `--data-urlencode` 或让 curl 自动编码（见下方命令）。

### 3. 许可证 —— ⚠️ 不要用官网那个

官网 `TD License/license.lic` 下到的其实是 **FD（FutureDynasty）**的许可证，**不是 TD 的**：

```
官网那份：NODELOCKED license for FD   （2025-12-09 生成）
U 盘那份：NODELOCKED license for TD   （2024-08-13 生成，2029-08-17 到期）✅
```

**TD 用 U 盘里这份**：

```
/media/.../1_安路开发工具和常用软件/必须看！！重要！安装前必看！/Anlogic.lic
```

内容：
```
FEATURE  TD  Anlogic  2029-08-17  a3c61cf2...
HOST_ID = ANY
```

`HOST_ID = ANY` 表示不锁定机器，换电脑也能用。

---

## 三、下载命令（可直接复制）

```bash
# TD Linux 版（1.87 GB，建议挂后台下）
curl -L -C - --retry 3 -o TD_Release_2026.2_NL.zip \
  "https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/%E5%B7%A5%E5%85%B7%E4%B8%8E%E8%B5%84%E6%96%99%E4%B8%8B%E8%BD%BD/%E8%BD%AF%E4%BB%B6%E5%B7%A5%E5%85%B7/TD_Linux/TD_6.2/ggshdjsgkdjh/TD_Release_2026.2_NL.zip"

# 校验（必须做，1.87 GB 下坏了很难发现）
echo "e624280f5bbfca3d685e8527c26a45f46ae1a6f534974fb759f4d182d604de4d  TD_Release_2026.2_NL.zip" | sha256sum -c

# 下载工具
curl -L -C - -o BW_1.0.0_154147.zip \
  "https://anlogic.oss-cn-shanghai.aliyuncs.com/web_doc/%E5%B7%A5%E5%85%B7%E4%B8%8E%E8%B5%84%E6%96%99%E4%B8%8B%E8%BD%BD/%E8%BD%AF%E4%BB%B6%E5%B7%A5%E5%85%B7/%E4%B8%8B%E8%BD%BD%E5%B7%A5%E5%85%B7/DSAD64Eadsae54a/BW_1.0.0_154147.zip"
echo "27e86e75490e34ac581fe39ce9c09e3c325bbd9f5fc8cb1c1cb07482a70a5e86  BW_1.0.0_154147.zip" | sha256sum -c
```

`-C -` 支持断点续传，网络断了重跑同一条命令即可。

---

## 四、安装步骤（Linux）

```bash
# 1. 解压到 /opt
sudo mkdir -p /opt/anlogic-td
sudo unzip TD_Release_2026.2_NL.zip -d /opt/anlogic-td/

# 2. 放许可证（文件名必须是 Anlogic.lic）
sudo cp "Anlogic.lic" /opt/anlogic-td/*/license/

# 3. udev 规则 —— 让普通用户能用下载器（USB 0547:1002）
sudo tee /etc/udev/rules.d/91-anlogic-jtag.rules <<'EOF'
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0547", ATTRS{idProduct}=="1002", GROUP="plugdev", MODE="0660"
EOF
sudo usermod -aG plugdev "$USER"     # 需要重新登录才生效
sudo udevadm control --reload-rules

# 4. 启动 GUI
/opt/anlogic-td/*/bin/td -gui
```

**已知坑**（Sipeed 记录）：**JTAG 下载速度限制在 400kbps 或更低**，高了会失败。在下载对话框里调。

---

## 五、下载位流的替代方案（推荐）

你的 `oss-cad-suite` 里**已经有 `openFPGALoader`，而且原生支持你的芯片和下载线**：

```
0x0a014c35  anlogic  eagle s20  EG4S20BG256      ← 正是 HX4S20C 的芯片
anlogicCable  0x0547:1002                        ← 正是安路下载线
```

用法：

```bash
openFPGALoader -c anlogicCable 你的工程.bit
openFPGALoader --detect          # 先确认能识别到设备
```

**好处**：不用碰 TD 的 USB 驱动，也不用管那个 400kbps 的限制。

所以完整工作流可以是：

| 步骤 | 工具 | 平台 |
|---|---|---|
| 写 RTL | 任意编辑器 | Linux |
| 功能仿真 | Verilator / Icarus + GTKWave | Linux |
| 综合 + 布局布线 + 生成位流 | **TD（Linux 版）** | Linux |
| **下载到板子** | **openFPGALoader** | Linux |

---

## 六、后台接口（以后自己查用）

页面是 JS 渲染的，但接口是明文的。

**① 列文件**

```
POST https://www.anlogic.com/Cn/Index/getFile.html?p=<页码>
Header: X-Requested-With: XMLHttpRequest
        Referer: https://www.anlogic.com/support/tools-downloads
Body:   id=<分类号>&type=1&sort=&p=<页码>&dev=1
返回:   { html: "<文件列表HTML片段>", pagepc: "...", pageph: "..." }
```

`type=1` 按分类浏览；`type=2` 按关键词搜索（此时 `id` 填关键词）。

**② 取下载地址**

```
POST https://www.anlogic.com/Skippower/setDownCount.html
Header: 同上
Body:   id=<文件条目的 data-id>
返回:   { code: 1, count: "下载次数", url: "<真实下载直链>" }
```

**③ 已知分类号**

| 分类号 | 内容 |
|---|---|
| 83 | 软件工具（总） |
| 137 | 下载工具 |
| 779 / 780 | TD 6.1 **Linux** / Windows |
| **781 / 782** | **TD 6.2 Windows / Linux** ← Linux 在 782 |
| 81 | 技术文档 |
| 82 | 开发板设计 |

规律：**同一版本号出现两次，`.zip` 是 Linux，`.exe`/`.msi` 是 Windows。**

---

## 七、备注

- 下载速度取决于阿里云 OSS，1.87 GB 建议夜间挂机或找百度网盘分流（Sipeed 下载站有）
- 如果 1.87 GB 太大，可先用 TD 6.1 Linux 版（`.zip` 更小）验证流程，够用再升
- 官网页面本身也支持手动点选，只是路径深、加载慢
