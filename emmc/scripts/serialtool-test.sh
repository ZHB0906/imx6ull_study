#!/bin/bash
#
# serialtool-test.sh —— SerialTool 上板验收测试（全程不需要人碰板子）
#
#   bash emmc/scripts/serialtool-test.sh serial      # 串口通路（i.MX UART 内部回环）
#   bash emmc/scripts/serialtool-test.sh tcp         # TCP 通路（TCP Server + 虚拟机灌数据）
#   bash emmc/scripts/serialtool-test.sh measure     # 采样 CPU/内存 + 截屏
#   bash emmc/scripts/serialtool-test.sh stop        # 停掉板上的 SerialTool
#
# 前置条件：
#   1) 板子跑的是带 Qt5 的 rootfs（dev 模式 NFS 根，或已固化的 eMMC）
#   2) /opt/serialtool/ 已由 build-serialtool.sh push 推上去
#   3) /tmp/uart-loopback 已推送（串口通路需要；uart-loopback.c 交叉编译而来）
#
# 设计要点（都是前面踩坑换来的）：
#   ★ 触摸无法远程注入（板子内核没编 uinput），所以靠 build-serialtool.sh 打的
#     env 测试钩子自动开端口：SERIALTOOL_TEST_AUTOOPEN / _PORT / _BAUD
#   ★ 串口名不写进配置，但 PortType/BaudRate/TCP 参数写进 config.ini
#     → 远程预置 /root/.config/SerialTool/config.ini 切换通路
#   ★ 内部回环必须在 SerialTool **打开端口之后**再开：imx_set_mctrl 是读改写，
#     Qt 开端口时的 termios/mctrl 操作会把 LOOP 位清掉（坑【42】）
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BOARD=192.168.10.2
BOARD6=fe80::8a2d:b6ff:fe8d:356d%ens37
APP=/opt/serialtool
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️ %s\n' "$*"; }

board_reach() {
	# ★ 不用 `ssh | grep -q`：脚本开了 pipefail，ssh 的非零退出码会污染管道状态，
	#   导致瞬时抖动被误判成"板子不可达"（踩过一次）。改成先取回输出再判断。
	local out
	out=$(timeout 20 $SSH root@$BOARD 'echo ok' 2>/dev/null) || true
	case "$out" in *ok*) echo "ipv4"; return 0 ;; esac
	out=$(timeout 25 $SSH root@$BOARD6 'echo ok' 2>/dev/null) || true
	case "$out" in *ok*) echo "ipv6"; return 0 ;; esac
	return 1
}
CH=""
BRUN() {
	[ -n "$CH" ] || CH=$(board_reach) || die "板子不可达（IPv4/IPv6 都试过）"
	if [ "$CH" = ipv6 ]; then timeout "${TIMEOUT:-120}" $SSH root@$BOARD6 "$@"
	else timeout "${TIMEOUT:-120}" $SSH root@$BOARD "$@"; fi
}

# ---------------------------------------------------------------- 公共前置检查
preflight() {
	say "① 前置检查"
	CH=$(board_reach) || die "板子不可达"
	echo "  板子可达（$CH）"
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
	  echo "  根文件系统: $(mount | awk "/ \/ /{print \$1\" (\"\$5\")\"}")"
	  # ★ 不要写 `ls xxx* | head -1 || echo 缺失`：管道里的 head 总是成功，
	  #   || 永远不触发（这个坑踩过多次）。用 ls 自己判断存在性。
	  show() { if ls $2 >/dev/null 2>&1; then echo "  $1: $(ls $2 | head -1)"; else echo "  $1: 缺失 ✗"; fi; }
	  show "Qt5 库    " "/usr/lib/libQt5Widgets.so.5*"
	  show "linuxfb   " "/usr/lib/qt/plugins/platforms/libqlinuxfb.so"
	  show "evdevtouch" "/usr/lib/qt/plugins/generic/libqevdevtouchplugin.so"
	  show "SerialTool" "/opt/serialtool/SerialTool"
	  show "回环工具  " "/tmp/uart-loopback"' | sed 's/^/  /'
}

# ---------------------------------------------------------------- 预置配置
write_config() { # $1 = Serial Port | TCP/UDP
	local ptype="$1"
	BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
mkdir -p /root/.config/SerialTool
cat > /root/.config/SerialTool/config.ini <<EOF
[Settings]
FontFamily=DejaVu Sans
FontStyle=normal
FontSize=10
Language=en
Theme=default
WindowOpacity=100
PortType=$ptype
UpdateInterval=25
UseOpenGL=false
UseAntialias=false

[SerialPort]
BaudRate=115200

[TcpUdpPort]
ServerAddress=localhost
PortNumber=8080
PortProtocol=TCP Server
EOF
echo '  已写入 config.ini：'; grep -E 'PortType|BaudRate|PortNumber|PortProtocol' /root/.config/SerialTool/config.ini | sed 's/^/    /'"
}

# ---------------------------------------------------------------- 启动应用
start_app() {
	say "③ 启动 SerialTool（linuxfb + 自动开端口测试钩子）"
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
# ★ 板上 busybox 没有 pgrep/pkill，只有 pidof（这个 rootfs 的 busybox 更精简）
for p in $(pidof SerialTool 2>/dev/null); do kill "$p" 2>/dev/null; done; sleep 1
cd /opt/serialtool || exit 1
if command -v setsid >/dev/null 2>&1; then
  SERIALTOOL_TEST_AUTOOPEN=1 SERIALTOOL_TEST_PORT=/dev/ttymxc2 SERIALTOOL_TEST_BAUD=115200 \
    setsid ./run.sh > /tmp/serialtool.log 2>&1 < /dev/null &
else
  SERIALTOOL_TEST_AUTOOPEN=1 SERIALTOOL_TEST_PORT=/dev/ttymxc2 SERIALTOOL_TEST_BAUD=115200 \
    nohup ./run.sh > /tmp/serialtool.log 2>&1 < /dev/null &
fi
sleep 6
echo "  进程数: $(ps -ef | grep -c "[S]erialTool")"
echo "  --- 启动日志 ---"
head -25 /tmp/serialtool.log | sed "s/^/    /"' | sed 's/^/  /'
}

# ---------------------------------------------------------------- 串口通路
do_serial() {
	preflight
	say "② 预置配置：串口通路"
	write_config "Serial Port"
	start_app
	say "④ 开内部回环（★ 必须在应用打开端口之后，否则被 mctrl 读改写清掉）"
	BRUN '/tmp/uart-loopback /dev/ttymxc2 on' | sed 's/^/  /'
	say "⑤ 灌数据：从 shell 写 /dev/ttymxc2，经内部回环回到 SerialTool"
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
# 不要用 stty（会清回环位）；直接写设备文件即可
i=0
while [ $i -lt 200 ]; do
  printf "CH1:%d CH2:%d\r\n" $((i % 100)) $(((i * 7) % 100)) > /dev/ttymxc2
  i=$((i + 1))
done
echo "  已写入 200 行数据"'
	say "⑥ 采样 CPU/内存 + 截屏"
	measure_inner "serial"
}

# ---------------------------------------------------------------- TCP 通路
do_tcp() {
	preflight
	say "② 预置配置：TCP 通路（TCP Server :8080）"
	write_config "TCP/UDP"
	start_app
	say "④ 虚拟机侧连上去灌数据"
	python3 - <<'PY'
import socket, time
try:
    s = socket.create_connection(("192.168.10.2", 8080), timeout=5)
except Exception as e:
    print("  ❌ 连不上 192.168.10.2:8080 ——", e); raise SystemExit(1)
print("  ✅ 已连上 TCP Server")
payload = 0
t0 = time.time()
for i in range(2000):
    line = ("CH1:%d CH2:%d CH3:%d\r\n" % (i % 100, (i*7) % 100, (i*13) % 100)).encode()
    try:
        s.sendall(line); payload += len(line)
    except Exception as e:
        print("  发送中断:", e); break
print("  共发送 %d 字节，用时 %.2fs" % (payload, time.time() - t0))
time.sleep(1)
s.close()
PY
	say "⑤ 采样 CPU/内存 + 截屏"
	measure_inner "tcp"
}

# ---------------------------------------------------------------- 采样
measure_inner() {
	local tag="$1"
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
PID=$(pidof SerialTool 2>/dev/null | awk "{print \$1}")
[ -n "$PID" ] || { echo "  ❌ 进程不在"; exit 1; }
# ★ 板上是 busybox ash：不能用进程替换 < <(...)，用临时文件；getconf 也可能没有
CLK=$(getconf CLK_TCK 2>/dev/null); [ -z "$CLK" ] && CLK=100
awk "{print \$14, \$15}" /proc/$PID/stat > /tmp/.st1
RSS=$(awk "/VmRSS/{print \$2}" /proc/$PID/status)
THR=$(awk "/Threads/{print \$2}" /proc/$PID/status)
echo "  PID=$PID  VmRSS=${RSS} kB  Threads=${THR}  CLK_TCK=$CLK"
echo "  采样 5 秒…"
sleep 5
awk "{print \$14, \$15}" /proc/$PID/stat > /tmp/.st2
set -- $(cat /tmp/.st1); u1=$1; s1=$2
set -- $(cat /tmp/.st2); u2=$1; s2=$2
CPU=$(awk -v a="$u1" -v b="$s1" -v c="$u2" -v d="$s2" -v clk="$CLK" \
      "BEGIN{printf \"%.1f\", ((c+d)-(a+b))/clk/5*100}")
echo "  ★ CPU 占用: ${CPU}%   （单核满载 = 100%）"
echo "  ★ 内存 VmRSS: ${RSS} kB"
echo "  --- 应用日志尾部 ---"
tail -10 /tmp/serialtool.log | sed "s/^/    /"' | sed 's/^/  /'

	say "⑥ 远程截屏（看界面到底渲染成什么样）"
	bash "$NEW/scripts/board-screenshot.sh" "$NEW/out/serialtool-$tag-$(date +%H%M%S).png" 2>&1 | tail -4 | sed 's/^/  /'
}

do_stop() {
	CH=$(board_reach) || die "板子不可达"
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
for p in $(pidof SerialTool 2>/dev/null); do kill "$p" 2>/dev/null; done; sleep 1
/tmp/uart-loopback /dev/ttymxc2 off 2>/dev/null
echo "  已停掉应用并关闭回环"'
}

case "${1:-serial}" in
serial)   do_serial ;;
tcp)      do_tcp ;;
preflight) preflight ;;
measure)  CH=$(board_reach) || die "板子不可达"; measure_inner manual ;;
stop)     do_stop ;;
*) sed -n '2,12p' "$0"; exit 1 ;;
esac
