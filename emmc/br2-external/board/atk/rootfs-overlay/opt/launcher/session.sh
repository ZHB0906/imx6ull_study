#!/bin/sh
#
# session.sh —— 桌面会话：让"桌面"与"SerialTool"**互斥运行**
#
# 为什么必须互斥：
#   evdev 的触摸事件会**发给所有打开了该设备的进程**（不是抢占式的）。
#   如果桌面常驻后台、SerialTool 也在跑，两个进程都会收到同一次点击 →
#   桌面可能被误触发（比如又去开一个 SerialTool）。
#   所以让桌面"退出"，由本脚本按退出码决定接着跑谁，应用退出后再回到桌面。
#
# 退出码约定：42 = 桌面里点了"启动 SerialTool"（见 main.cpp 的 EXIT_LAUNCH_SERIALTOOL）
#
# ★ 互斥锁：同一个桌面会话只允许一份。没有它时，重复执行 S90launcher start
#   （或 start 没把旧的杀干净）会出现**两个桌面实例**同时画屏、同时读触摸事件 ✗
PIDFILE=/tmp/atk-session.pid
if [ -f "$PIDFILE" ]; then
	old=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && [ "$old" != "$$" ]; then
		echo "[session] 已有一份会话在跑（PID $old），本次退出"
		exit 0
	fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

cd /opt/launcher || exit 1

export QT_QPA_PLATFORM=linuxfb
# ★ 键鼠支持（2026-09-22 加）
#
# 背景：之前只写了 evdevtouch ✗ → 插上 USB 键盘/鼠标**一点反应都没有** ✗
#       （Qt 的 evdevkeyboard / evdevmouse 插件其实板子上早就有 ✓，只是没让它加载 ✗）
#
# ★★ 但**不能无条件三个都开** ✗✗ —— 实测（QT_LOGGING_RULES=qt.qpa.input*=true 的日志 ✓）：
#      evdevmouse 会把**触摸屏自己**也认成鼠标 ✗：
#          Found new-style touchscreen at "/dev/input/event1"
#          Found matching devices ("/dev/input/event1")
#          Adding mouse at "/dev/input/event1"
#      → 触摸事件被**同时按鼠标处理一遍** ✗✗
#      → 一次点击可能触发两次 ✗
#        （"检查更新"抬手的瞬间又去按"立即升级" —— 这个双重触发很危险 ✗✗）
#      而 evdevkeyboard **不会**认领触摸屏 ✓（同一份日志可证 ✓）。
#
# 所以改成：**按实际插着的 USB 设备**决定要不要加载对应插件 ✓
#   · 没插 → 只有 evdevtouch ✓（和以前行为完全一致 ✓ 零风险 ✓）
#   · 插了 → 额外加载 ✓，且鼠标**显式指定设备** ✗ 免得它去抢触摸屏 ✓
#   （代价：Qt5 的 evdev 插件不监听热插拔 ✗ → 插上键鼠后要重启一次桌面会话才认 ✓；
#     正常使用中"退出 SerialTool 回桌面"时会话本来就会重启 ✓，会自动生效 ✓）
find_usb_input() {
	# $1 = kbd | mouse ✓  命中就打印 /dev/input/eventN ✓
	for d in /sys/class/input/event*; do
		[ -e "$d/device" ] || continue
		# 只认 USB 上的输入设备 ✗（板载的 snvs-powerkey / gpio_keys / goodix-ts 都要排除 ✓）
		readlink -f "$d/device" 2>/dev/null | grep -q usb || continue
		n=$(cat "$d/device/name" 2>/dev/null)
		case "$1:$n" in
		kbd:*[Kk]eyboard*|kbd:*[Kk]ey*) echo "/dev/input/${d##*/}"; return 0 ;;
		mouse:*[Mm]ouse*|mouse:*[Tt]ouchpad*) echo "/dev/input/${d##*/}"; return 0 ;;
		esac
	done
	return 1
}

PLUGINS=evdevtouch
USB_KBD=$(find_usb_input kbd || true)
USB_MOUSE=$(find_usb_input mouse || true)
[ -n "$USB_KBD" ] && PLUGINS="$PLUGINS:evdevkeyboard"
[ -n "$USB_MOUSE" ] && PLUGINS="$PLUGINS:evdevmouse"
export QT_QPA_GENERIC_PLUGINS="$PLUGINS"

# 显式指定触摸设备：板子上 event0/event2 是按键，只有 event1 是 GT911 触摸
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=/dev/input/event1

# ★★ 关键（实测两轮才定性 ✗✗）：
#   Qt5 的 **linuxfb 平台集成会无条件创建 evdev 键盘/鼠标管理器** ✗
#   证据：`QT_QPA_GENERIC_PLUGINS=evdevtouch`（只有触摸 ✓）且**完全没设**这两个 *_PARAMETERS ✓，
#         运行中的 launcher 环境里也确实没有它们 ✓，
#         但日志里依然出现 'evdevmouse: Using device discovery' ＋ 'Adding mouse at /dev/input/event1' ✗
#   → 光"不设参数"是**挡不住**它的 ✗
#
#   而它一旦去 discovery，就会把**触摸屏自己**认成鼠标 ✗
#     （日志：Found new-style touchscreen at event1 → Adding mouse at event1 ✗）
#   → 触摸事件被同时按鼠标处理一遍 ✗ → 一次点击可能触发两次 ✗
#     （"检查更新"抬手瞬间又按"立即升级" —— 这个双重触发很危险 ✗✗）
#
#   解法：**显式给插件指定设备** ✓ —— 指定了它就不再做 discovery ✓
#     插了鼠标 → 指向真鼠标 ✓
#     没插     → 指向一个不存在的设备 = 空操作 ✓ 从此不碰触摸屏 ✓✓
#   （grab=0：不 EVIOCGRAB 独占 ✓ 永远不影响触摸 ✓）
# ★ 结论（实测三轮才定性 ✓）：**这两个参数变量不用设** ✗
#   因为 Qt5 的 linuxfb 集成**本来就无条件**建 evdev 键盘/鼠标管理器 ✓，
#   它会自己 discovery 到插着的 USB 键鼠 ✓ ——
#   · 设了参数 → 只会**再**多出一个管理器 ✗ → 同一个设备被处理两遍 ✗（更糟）
#   · 所以这里**保持最小** ✓，只在下面把探测结果打出来方便排障 ✓
export QT_QPA_FONTDIR=/usr/share/fonts
unset DISPLAY

# 把探测结果写进日志 ✓（插了键鼠却没反应时，第一眼就该看到这行 ✓）
echo "[session] 输入插件=$PLUGINS  键盘=${USB_KBD:-无}  鼠标=${USB_MOUSE:-无}"

# 内核 printk 会直接写进 /dev/fb0，在画面上叠字/花屏 —— 只留 emergency
dmesg -n 1 2>/dev/null || true

# fbcon 与 Qt 共用 /dev/fb0，启动前必须解绑，否则桌面会被开机 logo 覆盖
sh /usr/bin/fbcon-off >/dev/null 2>&1 || true

while true; do
	./launcher
	rc=$?
	echo "[session] 桌面退出码=$rc  $(date '+%H:%M:%S')"

	if [ "$rc" = "42" ] && [ -x /opt/serialtool/run.sh ]; then
		echo "[session] 启动 SerialTool…"
		# 7 寸 1024x600 屏上，SerialTool 默认窗口只有 715x430、四周大片黑边，
		# 所以这里让启动器默认带上"最大化"（应用侧的 env 开关）
		export SERIALTOOL_TEST_MAXIMIZE=1
		# ★ 默认停在 Text Tx/Rx 页（序号 0）：SerialTool 原本默认停在 File Transmit 页，
		#   那一页中间一大片白区**没有任何可交互的东西**，用户点了会以为"触摸坏了"。
		#   Text Tx/Rx 页有接收区 + 发送输入框 + 按钮，交互反馈明显。
		export SERIALTOOL_TEST_VIEW=0
		# linuxfb 下点菜单栏会卡死 -> 隐藏菜单栏、工具栏加"退出"按钮
		export SERIALTOOL_TOUCH_UI=1
		# ★ 防御（踩过一次，界面整块空白）：SerialTool 正常退出时会 saveConfig() 存下
		#   MainWindowGeometry / MainWindowState（dock 布局的二进制 blob）。若那一刻布局
		#   是坏的（异常退出、屏幕尺寸变化、或曾经用过 setGeometry hack），下次启动
		#   restoreState() 就会恢复坏布局 —— 现象是**菜单栏和 dock 区域整块消失**，
		#   只剩工具栏+状态栏、中间一片白，看起来像"程序坏了/触摸没反应"。
		#   所以每次启动前把这两个键清掉，让它用默认布局。
		# ★★ 关键（实测踩到 ✓）：**必须先把 HOME 设好** ✗✗
		#   init 传下来的 HOME 是 **`/`** ✗ → SerialTool 会去读 `/.config/SerialTool/config.ini` ✗
		#   → 而下面这几行只清了 `/root/...` ✗ → **等于一直没生效** ✗✗
		#   → 结果：从桌面按钮启动时用的是 `.config` 里那份**坏布局** ✗
		#     现象就是"串口助手坏了"：工具栏整条空白 ✗（连唯一能退出的「退出」都没有 ✗）
		#   而我从 SSH 手动启动时 HOME=/root ✓ 用的是干净配置 ✓ → 一切正常 ✓
		#   （同一个二进制、两种表现 —— 差别只在 HOME ✓）
		export HOME=/root
		# 两份都清一遍 ✓ 双保险（万一还有别的启动路径带不同的 HOME ✓）
		for CFG in /root/.config/SerialTool/config.ini /.config/SerialTool/config.ini; do
			[ -f "$CFG" ] && sed -i '/^MainWindowGeometry=/d; /^MainWindowState=/d' "$CFG"
		done
		( cd /opt/serialtool && ./run.sh )
		echo "[session] SerialTool 已退出，回到桌面  $(date '+%H:%M:%S')"
	fi
	sleep 1
done
