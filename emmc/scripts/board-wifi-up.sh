#!/bin/sh
#
# board-wifi-up.sh —— 在开发板上把 WiFi 拉起来并验证（M2 收尾 / 排查用）
#
# 为什么是脚本：板子上 `iw scan` 在这套 rtl8189fs 上会卡死，
#   前台跑会把 SSH 会话一起拖死（记录里的坑 19）。
#   所以整段流程丢后台 + 全量日志，你另开一条 SSH 读日志。
#
# 用法（在板子上）：
#   nohup /tmp/board-wifi-up.sh >/dev/null 2>&1 &
#   cat /tmp/wifi-up.log
#
# ★ 几条实测教训（2026-09-18，old 出厂系统 / wpa_supplicant v2.5）：
#   ① 别乱杀别人的 supplicant：先看是不是已经有一个在管 wlan0，在管就复用
#   ② v2.5 的 wpa_supplicant 没有 `-f` 选项，传了就 usage 退出（本次踩过）
#   ③ `ps w` 只列带 tty 的进程，要看全部得用 `ps -ef`
#   ④ 判定一律用 `wpa_cli status`，`iw dev wlan0 link` 在这驱动上恒报 Not connected
#
exec >/tmp/wifi-up.log 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

CONF=${CONF:-/etc/wpa_supplicant.conf}
IFACE=${IFACE:-wlan0}

echo "== 开始 $(date) =="

# ① rfkill 软阻塞（驱动注册时默认 soft=1，重启会复原）
#    写 sysfs，不依赖 rfkill 命令（Buildroot 里不一定有 rfkill 包）
echo "-- rfkill --"
for r in /sys/class/rfkill/rfkill*/; do
	[ -f "$r/soft" ] && echo 0 >"$r/soft" 2>/dev/null
done
for r in /sys/class/rfkill/rfkill*/; do
	echo "   $(basename "$r") soft=$(cat "$r/soft") hard=$(cat "$r/hard")"
done

ip link set "$IFACE" up

# ② 谁在管这个网卡？（别抢别人的 supplicant）
if wpa_cli -i "$IFACE" status >/dev/null 2>&1; then
	echo "-- 已有 supplicant 在管 $IFACE，直接复用它（不杀）--"
	ps -ef | grep "[w]pa_supplicant"
else
	ip addr flush dev "$IFACE" 2>/dev/null
	ip route del default dev "$IFACE" 2>/dev/null

	echo "-- 起 supplicant：wext 优先，nl80211 兜底 --"
	connected=no
	for D in wext nl80211; do
		echo "   尝试 -D$D"
		wpa_supplicant -B -i "$IFACE" -c "$CONF" -D"$D"
		i=0
		while [ $i -lt 20 ]; do
			i=$((i + 1))
			sleep 1
			s=$(
				wpa_cli -i "$IFACE" status 2>/dev/null |
					grep '^wpa_state=' | cut -d= -f2
			)
			echo "      ${i}s wpa_state=$s"
			[ "$s" = "COMPLETED" ] && {
				connected=yes
				break
			}
		done
		[ "$connected" = yes ] && break
		echo "      -D$D 没连上，换下一种"
		killall wpa_supplicant 2>/dev/null
		sleep 2
	done
fi

echo "-- wpa_cli status --"
wpa_cli -i "$IFACE" status 2>/dev/null
echo "-- iw link（预期就是 Not connected，别慌）--"
iw dev "$IFACE" link

# ③ 拿 IP
echo "-- udhcpc --"
udhcpc -i "$IFACE" -q -n -t 5
echo "-- addr --"
ip -4 addr show "$IFACE" | grep inet
echo "-- route --"
ip route

# ④ 通不通
GW=$(ip route | awk '/^default/ && /wlan0/ {print $3; exit}')
echo "-- ping 网关 $GW --"
[ -n "$GW" ] && ping -c3 -W3 "$GW"
echo "-- ping 223.5.5.5（不通多半是 eth0 假默认路由抢路，见下）--"
ping -c3 -W3 223.5.5.5

# ⑤ 老系统专用补丁：ConnMan 会在 eth0 上留一条无网关的 default，
#    比 wlan0 的 default 优先 → 公网 No route to host。
#    内核没编 IP_MULTIPLE_TABLES（ip rule 不可用），所以用 /1 + /1 最长前缀覆盖。
#    ★ 我们自己的 Buildroot rootfs 没有 ConnMan，不需要这段。
if ! ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && [ -n "$GW" ]; then
	echo "-- 公网不通，加 /1 路由覆盖 eth0 假默认路由 --"
	ip route add 0.0.0.0/1 via "$GW" dev wlan0 2>&1
	ip route add 128.0.0.0/1 via "$GW" dev wlan0 2>&1
	ping -c3 -W3 223.5.5.5
	wget -T 10 -O /tmp/t.html http://www.baidu.com/ 2>&1 | tail -2
	ls -l /tmp/t.html 2>/dev/null
fi

echo "== 结束 $(date) =="
