#!/bin/bash
# ============================================================================
# dsh-bt-reset — 重置 MediaTek MT7925 蓝牙控制器
#
# 硬件形态：MT7925 是组合模块，WiFi 走 PCIe（mt7925e），蓝牙走 USB
#           （Foxconn 0489:e111，内核里是一个独立的 USB 设备，端口 3-14）。
#
# 已知的两种失败形态：
#   A) hci0 因 WMT 命令超时而初始化失败（怀疑 Windows 快速启动导致芯片卡死）。
#      → 重载内核模块即可恢复。
#   B) hci0 启动时正常，运行中 USB reset 后 btusb 不再绑定接口，
#      内核里彻底没有 hci0（/sys/class/bluetooth 为空，btusb 引用计数为 0）。
#      → 仅重载模块不一定够，需要 USB 设备级重新枚举。
#
# 本脚本依次尝试：解 rfkill → 重载模块 → USB 重新枚举 → 再次重载，
# 并严格判定控制器是否真的可用。
#
# 安全设计：本脚本必须 root 拥有且不可被普通用户修改（chown root:root,
#           chmod 755）。sudoers 只授权这一个脚本，不授权 modprobe 本身，
#           因此调用者无法借此加载任意内核模块。
#
# 判定标准的演进：
#   v1    只看 /sys/class/bluetooth 目录非空 —— 但初始化失败时内核同样会留下
#         空壳目录，导致误报成功。
#   v2    改为要求 hci0/address 存在且非全零。
#   v3    新增失败形态 B 的处理：模块重载后仍无控制器时，对该 USB 设备做
#         authorized 0→1 重新枚举，再重载模块。
#   v3.1  修正误报：内核 6.8 已从 sysfs 移除 hci0 的 address/name 属性
#         （实测 /sys/class/bluetooth/hci0/ 下只剩 uevent/device/power/rfkill），
#         于是 v2 的判据恒为假，会把已经修好的控制器报成失败。
#         现改为优先用 hciconfig（ioctl 直接问内核，非 root 下也可读），
#         退回 bluetoothctl（bluetoothd 的 D-Bus 属性），sysfs 仅作老内核兜底。
# ============================================================================
set -u

BT_SYSFS=/sys/class/bluetooth
MODULES="btusb btmtk"
# MT7925 蓝牙的 USB ID 前缀（Foxconn 0489:e111 / MediaTek 0e8d:*）
BT_USB_IDS="0489:e111 0e8d:"

# 取控制器 BD 地址；取不到则输出空
controller_address() {
  local a
  # 1) 首选 hciconfig：直接问内核，不依赖 bluetoothd
  if command -v hciconfig >/dev/null 2>&1; then
    a="$(hciconfig hci0 2>/dev/null \
      | sed -n 's/.*BD Address: *\([0-9A-Fa-f:]\{17\}\).*/\1/p')"
    if [ -n "$a" ]; then printf '%s' "$a"; return 0; fi
  fi
  # 2) 退回 bluetoothd 的 D-Bus 属性
  if command -v bluetoothctl >/dev/null 2>&1; then
    a="$(timeout 8 bluetoothctl list 2>/dev/null \
      | sed -n 's/^Controller \([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -1)"
    if [ -n "$a" ]; then printf '%s' "$a"; return 0; fi
  fi
  # 3) 老内核的 sysfs 属性（6.8 已移除，仅兜底）
  cat "$BT_SYSFS/hci0/address" 2>/dev/null
  return 0
}

controller_ok() {
  local addr
  addr="$(controller_address)"
  [ -n "$addr" ] || return 1
  case "$addr" in
    00:00:00:00:00:00) return 1 ;;
  esac
  return 0
}

show_controllers() {
  local found=0
  # 首选 hciconfig，能同时给出 UP/RUNNING 这类真实状态
  if command -v hciconfig >/dev/null 2>&1; then
    local out
    out="$(hciconfig -a 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" \
        | grep -E '^(hci[0-9]+:|[[:space:]]+(BD Address|Name):|[[:space:]]+(UP|RUNNING))' \
        | sed 's/^/  /'
      return 0
    fi
  fi
  # 退回 bluetoothd
  if command -v bluetoothctl >/dev/null 2>&1; then
    local lst
    lst="$(timeout 8 bluetoothctl list 2>/dev/null)"
    if [ -n "$lst" ]; then printf '%s\n' "$lst" | sed 's/^/  /'; return 0; fi
  fi
  # 最后看 sysfs 目录（能区分"完全没设备"和"有设备但取不到属性"）
  local h
  for h in "$BT_SYSFS"/*; do
    [ -e "$h" ] || continue
    found=1
    printf '  %s  address=%s\n' "$(basename "$h")" \
      "$(cat "$h/address" 2>/dev/null || echo '(属性不存在)')"
  done
  [ "$found" -eq 0 ] && echo "  (无 hci 设备)"
  return 0
}

show_rfkill() {
  for r in /sys/class/rfkill/rfkill*; do
    [ -e "$r" ] || continue
    [ "$(cat "$r/type" 2>/dev/null)" = "bluetooth" ] || continue
    printf '    %s soft=%s hard=%s name=%s\n' \
      "$(basename "$r")" "$(cat "$r/soft" 2>/dev/null)" \
      "$(cat "$r/hard" 2>/dev/null)" "$(cat "$r/name" 2>/dev/null)"
  done
}

# 输出匹配到的 USB 设备名（如 3-14），每行一个
find_bt_usb() {
  local d vid pid id pair
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    vid="$(cat "$d/idVendor" 2>/dev/null)"
    pid="$(cat "$d/idProduct" 2>/dev/null)"
    id="$vid:$pid"
    for pair in $BT_USB_IDS; do
      case "$id" in
        "$pair"*)
          echo "$(basename "$d")"
          break 2
          ;;
      esac
    done
  done
}

# authorized 0→1：让内核把这个 USB 设备整体断开并重新枚举，从而重新 probe 驱动
reenumerate_usb() {
  local dev="$1"
  local auth="/sys/bus/usb/devices/$dev/authorized"
  [ -w "$auth" ] || { echo "  ⚠️ $auth 不可写，跳过"; return 1; }
  if echo 0 > "$auth" 2>/dev/null; then
    echo "  $dev: authorized=0（断开设备）"
  else
    echo "  ⚠️ $dev: 写 authorized=0 失败"
    return 1
  fi
  sleep 2
  if echo 1 > "$auth" 2>/dev/null; then
    echo "  $dev: authorized=1（重新枚举）"
  else
    echo "  ⚠️ $dev: 写 authorized=1 失败，请手动执行：echo 1 > $auth"
    return 1
  fi
  return 0
}

echo "===== 1. 重置前 ====="
show_controllers
echo "  rfkill(bluetooth):"
show_rfkill
if controller_ok; then
  echo
  echo "结果：✅ 控制器本来就正常，无需重置（address=$(controller_address)）"
  exit 0
fi

echo
echo "===== 2. 解除 rfkill 软阻塞 ====="
if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock bluetooth 2>&1 && echo "  已执行 rfkill unblock bluetooth"
else
  echo "  rfkill 命令不可用，跳过"
fi

echo
echo "===== 3. 卸载蓝牙模块 ====="
for m in $MODULES; do
  if modprobe -r "$m" 2>&1; then echo "  已卸载 $m"; else echo "  $m 卸载失败（可能未加载）"; fi
done
sleep 3

echo
echo "===== 4. 重新加载 ====="
if modprobe btusb 2>&1; then echo "  已加载 btusb"; else echo "  ❌ btusb 加载失败"; fi
sleep 8

echo
echo "===== 5. 重启 bluetooth 服务 ====="
if systemctl restart bluetooth 2>&1; then echo "  已重启"; else echo "  ⚠️ 重启失败"; fi
sleep 3

if ! controller_ok; then
  echo
  echo "===== 6. 模块重载无效，改为 USB 设备级重新枚举（失败形态 B）====="
  bt_devs="$(find_bt_usb)"
  if [ -z "$bt_devs" ]; then
    echo "  ⚠️ 未在 USB 总线上找到 MT7925 蓝牙设备，芯片可能已完全掉线"
  else
    for dev in $bt_devs; do
      echo "  发现蓝牙 USB 设备：$dev"
      reenumerate_usb "$dev" || true
    done
    sleep 8
    echo "  重新加载蓝牙模块 ..."
    modprobe -r btusb 2>/dev/null || true
    modprobe -r btmtk 2>/dev/null || true
    sleep 2
    if modprobe btusb 2>&1; then echo "  已加载 btusb"; else echo "  ❌ btusb 加载失败"; fi
    sleep 8
    if systemctl restart bluetooth 2>&1; then echo "  已重启 bluetooth"; else echo "  ⚠️ 重启失败"; fi
    sleep 3
  fi
fi

echo
echo "===== 7. 重置后 ====="
show_controllers
echo "  rfkill(bluetooth):"
show_rfkill

echo
if controller_ok; then
  echo "结果：✅ 控制器已恢复（address=$(controller_address)）"
  hciconfig hci0 2>/dev/null | sed 's/^/    /'
  exit 0
fi

echo "结果：❌ 控制器仍未就绪（无 BD 地址或地址全零）"
echo
echo "----- 最近的内核日志 -----"
dmesg 2>/dev/null | grep -iE 'hci0|btusb|btmtk|bluetooth' | tail -12 | sed 's/^/  /' \
  || journalctl -k --since "3 min ago" --no-pager 2>/dev/null | grep -iE 'hci0|btusb|btmtk' | tail -12 | sed 's/^/  /'
echo
echo "----- 下一步建议 -----"
echo "  软件复位已用尽，说明芯片被彻底锁死，需要断电复位："
echo "    关机（不是重启）→ 拔掉电源适配器和扩展坞 → 长按电源键 30 秒 → 再开机"
echo "  若是 Windows 双系统：在 Windows 里关闭“快速启动”"
echo "    （控制面板 → 电源选项 → 选择电源按钮的功能 → 更改当前不可用的设置"
echo "      → 取消勾选“启用快速启动”），否则每次从 Windows 关机都会让芯片卡住。"
exit 1
