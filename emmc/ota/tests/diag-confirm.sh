#!/bin/sh
# 诊断 S99otaconfirm 为什么没在 b 槽自动确认
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

echo "════════ ① rcS / rcK 是怎么调 S* 脚本的 ════════"
echo "── /etc/init.d/rcS ──"
cat /etc/init.d/rcS 2>/dev/null | sed 's/^/    /'
echo "── /etc/init.d/rcK ──"
cat /etc/init.d/rcK 2>/dev/null | sed 's/^/    /'
echo
echo "════════ ② 是否存在 K* 链接（关机时才跑）════════"
ls -l /etc/init.d/ | sed 's/^/    /'
echo
echo "════════ ③ 确认脚本依赖的能力自检 ════════"
echo "    pidof      : $(command -v pidof || echo '缺 FAIL')"
echo "    sleep      : $(command -v sleep || echo '缺 FAIL')"
echo "    date       : $(command -v date || echo '缺 FAIL')"
echo "    awk        : $(command -v awk || echo '缺 FAIL')"
echo "    mount      : $(command -v mount || echo '缺 FAIL')"
echo "    pidof launcher = $(pidof launcher || echo '(无)')"
echo "    pidof dropbear = $(pidof dropbear | head -1 || echo '(无)')"
echo
echo "════════ ④ 关键：脚本里取根设备的那行表达式到底算出什么 ════════"
echo "    mount | awk '/ \\/ /{print \$1}'  =>  [$(mount | awk '/ \/ /{print $1}')]"
echo "    （b 槽这里应该是 /dev/loop0；若输出 mmcblk1p2 就是匹配错了 ✓）"
echo "    ---- mount 原文 ----"
mount | sed 's/^/      /'
echo
echo "════════ ⑤ 本次启动的日志里有没有 otaconfirm 的痕迹 ════════"
if [ -f /var/log/messages ]; then
	grep -i 'otaconfirm\|otaconf' /var/log/messages | tail -20 | sed 's/^/    /' || echo "    （日志里没有 otaconfirm 记录）"
else
	echo "    /var/log/messages 不存在"
fi
echo "    dmesg 里的痕迹:"
dmesg 2>/dev/null | grep -i 'otaconfirm' | tail -10 | sed 's/^/      /' || echo "      （无）"
echo
echo "════════ ⑥ /slots 相关文件时间戳（判断谁在什么时候写的）════════"
ls -l --time-style=full-iso /slots/ 2>/dev/null | sed 's/^/    /' || ls -l /slots | sed 's/^/    /'
echo
echo "    uptime = $(cut -d. -f1 /proc/uptime) 秒"
echo "    date   = $(date)"
echo "    /proc/stat btime = $(grep btime /proc/stat)"
