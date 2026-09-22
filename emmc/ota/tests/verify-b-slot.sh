#!/bin/sh
# b 槽启动后的完整验证（在板子上跑 ✓ 避免嵌套引号问题 ✓）
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

echo "  ★ 根设备   : $(mount | awk '/ \/ /{print $1}')   <- 期望 /dev/loop0"
echo "  uptime     : $(cut -d. -f1 /proc/uptime) 秒"
echo
echo "  ── 这次升级真正的意义：新包里的文件必须都在 ──"
check_file() {
	if [ -s "$1" ]; then
		printf "    %-28s 在 OK  %s 字节\n" "$1" "$(wc -c < "$1")"
	else
		printf "    %-28s 缺/空 FAIL\n" "$1"
	fi
}
check_file /etc/ota.conf
check_file /usr/bin/ota-client.sh
check_file /etc/init.d/S99otaconfirm
check_file /etc/ota-pub.pem
check_file /opt/launcher/launcher
echo "    权限自检:"
ls -l /etc/init.d/S99otaconfirm /usr/bin/ota-client.sh /etc/ota.conf /etc/ota-pub.pem | awk '{printf "      %s %s:%s %s\n", $1, $3, $4, $9}'
echo
echo "  ── /slots 状态（确认机制是否生效）──"
echo "    active      = $(cat /slots/active)"
echo "    ota-version = $(cat /slots/ota-version)"
echo "    tries       = $(cat /slots/tries)   <- 期望 0（已被 confirm 清零）"
echo "    confirmed.txt 内容:"
sed 's/^/      /' /slots/confirmed.txt 2>/dev/null || echo "      (无)"
echo "    boot-info.txt 内容:"
sed 's/^/      /' /slots/boot-info.txt 2>/dev/null || echo "      (无)"
echo
echo "  ── 桌面/服务是否正常起来 ──"
echo "    launcher pid : $(pidof launcher || echo 未运行)"
echo "    dropbear pid : $(pidof dropbear || echo 未运行)"
echo "    /dev/fb0     : $([ -e /dev/fb0 ] && echo '在 OK' || echo '无 FAIL')"
echo "    /dev/urandom : $([ -e /dev/urandom ] && echo '在 OK' || echo '无 FAIL')"
echo
echo "  ── /slots 挂载形态（必须 bind，不能 move）──"
mount | grep slots | sed 's/^/      /'
echo
echo "  ── 根文件系统 / 与 /slots 的挂载关系 ──"
mount | grep -E 'loop0|mmcblk1p2' | sed 's/^/      /'
