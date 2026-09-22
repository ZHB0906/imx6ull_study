#!/bin/sh
# SerialTool 启动器（linuxfb + 触摸）
cd "$(dirname "$0")" || exit 1

# 内核 printk 会直接写进 /dev/fb0，在 Qt 画面上叠字/花屏 —— 只留 emergency 级别
dmesg -n 1 2>/dev/null || true
# fbcon 与 Qt 共用 /dev/fb0，启动前解绑，避免桌面被开机 logo 覆盖
sh /usr/bin/fbcon-off >/dev/null 2>&1 || true

# 无 GPU → 软件渲染
# ★ 先把 HOME 钉死 ✓：init 传下来的 HOME 是 `/` ✗
#   → Qt 的 QSettings 会去读 `/.config/SerialTool/config.ini` ✗
#     那份里可能存着**坏布局** ✗ → 工具栏整条空白、连"退出"都点不到 ✗（实测踩到 ✓）
#   （同一份二进制：HOME=/root 时正常 ✓、HOME=/ 时工具栏空白 ✗）
export HOME=/root

export QT_QPA_PLATFORM=linuxfb
# 触摸：GT911 走 evdev（显式指定 event1，板子上 event0/2 是按键）
export QT_QPA_GENERIC_PLUGINS=evdevtouch
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=/dev/input/event1
export QT_QPA_FONTDIR=/usr/share/fonts
# 让它别去找 X11
unset DISPLAY

exec ./SerialTool "$@"
