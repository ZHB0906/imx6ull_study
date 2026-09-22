#!/bin/bash
#
# verify-m4m5.sh —— M4/M5 一键验证（在虚拟机上跑，通过 telnet/ssh 问板子）
#
#     bash emmc/scripts/verify-m4m5.sh
#
# M4 判据：板子跑的是**我们的** rootfs（/etc/issue + 内核 release + 模块目录）
# M5 判据：不干预的情况下 WiFi 自动连上（wpa_state=COMPLETED + IP + 公网）
#
# 为什么用 telnet 优先：新 rootfs 里文件属主是 uid 1000（我不是 root，解包时
# 没法 chown），dropbear 的密钥认证可能因此拒绝；而 S50telnetd 是无认证的，
# 一定进得去。dropbear 作为后备（密码 root）。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
KREL=$(cat "$NEW/linux/IMX6ULL/linux-imx/include/config/kernel.release")
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa \
     -o ConnectTimeout=6 -o LogLevel=ERROR -o BatchMode=yes"

pass=0; fail=0
ok()   { printf '  ✅ %-42s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  ❌ %-42s %s\n' "$1" "$2"; fail=$((fail+1)); }

echo "=== 0. 板子在不在 ==="
if ! ping -c2 -W2 "$BOARD" >/dev/null 2>&1; then
	echo "  ❌ ping 不通 $BOARD —— 板子可能还停在 U-Boot/panic（只有串口能看）"
	exit 1
fi
ok "ping $BOARD" "通"

# 挑一条能用的登录通道
run() { timeout 60 $SSH root@$BOARD "$@" 2>/dev/null; }
if ! run 'echo ok' | grep -q ok; then
	echo "  ⚠️ SSH 进不去，试 telnet（board.py）"
	# 新 rootfs 的 23 端口是【登录式】telnetd，old 的 board.py 会把命令当用户名敲进去，
	# 所以改用带登录的助手（root/root）
	run() { timeout 40 python3 "$NEW/scripts/board-telnet-login.py" "$@" 2>/dev/null; }
	run 'echo ok' | grep -q ok || { echo "  ❌ SSH 和 telnet 都进不去"; exit 1; }
	CH=telnet
else
	CH=ssh
fi
ok "登录通道" "$CH"

echo
echo "=== 1. M4：是不是我们的 rootfs ==="
ISSUE=$(run 'cat /etc/issue 2>/dev/null | head -2')
echo "$ISSUE" | grep -q "new/" && ok "/etc/issue 是我们的" "$(echo "$ISSUE" | head -1)" \
	|| bad "/etc/issue 不是我们的（还在老系统？）" "$(echo "$ISSUE" | head -1)"

REAL=$(run 'uname -r')
[ "$REAL" = "$KREL" ] && ok "内核 release" "$REAL" || bad "内核 release" "期望 $KREL，实际 $REAL"

run "ls /lib/modules/$KREL/8189fs.ko" | grep -q 8189fs.ko \
	&& ok "WiFi 模块在位" "/lib/modules/$KREL/8189fs.ko" || bad "WiFi 模块" "缺失"

run 'test -x /etc/init.d/S45wifi' >/dev/null && ok "S45wifi 可执行" "在" || bad "S45wifi" "缺失"
run 'test -x /root/set-wifi.sh' >/dev/null && ok "set-wifi.sh 可执行" "在" || bad "set-wifi.sh" "缺失"

echo
echo "=== 2. M5：WiFi 是否自己连上（不干预）==="
ST=$(run 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; wpa_cli -i wlan0 status 2>/dev/null | grep "^wpa_state=" | cut -d= -f2')
[ "$ST" = "COMPLETED" ] && ok "wpa_state" "$ST" || bad "wpa_state" "${ST:-空}（没连上）"

SSID=$(run 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; wpa_cli -i wlan0 status 2>/dev/null | grep "^ssid=" | cut -d= -f2')
[ -n "$SSID" ] && ok "已连 AP" "$SSID" || bad "已连 AP" "无"

IP=$(run 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; ip -4 addr show wlan0 2>/dev/null | sed -n "s/.*inet \([0-9.]*\).*/\1/p"')
[ -n "$IP" ] && ok "wlan0 拿到 IP" "$IP" || bad "wlan0 IP" "无"

RFK=$(run 'cat /sys/class/rfkill/rfkill0/soft 2>/dev/null')
[ "$RFK" = "0" ] && ok "rfkill 已解阻塞" "soft=0" || bad "rfkill" "soft=${RFK:-未知}"

echo
echo "=== 3. 公网（判据用 TCP，别只看 ping —— 有些网封 ICMP）==="
run 'rm -f /tmp/v.html; export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; wget -T 25 -O /tmp/v.html http://www.baidu.com/ >/dev/null 2>&1 && wc -c < /tmp/v.html' \
	| grep -qE '^[0-9]{3,}$' && ok "公网 HTTP" "取回首页" || bad "公网 HTTP" "失败"
run 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; ping -c2 -W3 223.5.5.5 >/dev/null 2>&1 && echo yes' \
	| grep -q yes && ok "公网 ICMP" "通" || echo "  ⚠️ 公网 ICMP 不通（可能被上游封，看上一行 HTTP）"

echo
echo "===================================="
echo "  通过 $pass 项，失败 $fail 项"
[ "$fail" = 0 ] && echo "  🎉 M4 + M5 全部达成" || echo "  ⚠️ 有未达成项，见上"
exit $([ "$fail" = 0 ] && echo 0 || echo 1)
