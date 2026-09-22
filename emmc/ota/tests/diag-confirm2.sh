#!/bin/sh
# 硬数据：rcS 是否还在跑 / 各进程启动时刻 / confirmed.txt 写入时刻
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

UP=$(cut -d. -f1 /proc/uptime)
HZ=100   # 内核 USER_HZ，i.MX6ULL 默认 100
echo "  当前 uptime = $UP 秒"
echo

echo "════════ ① 进程树（rcS 还在不在？）════════"
ps -o pid,ppid,stat,etime,args 2>/dev/null | sed 's/^/    /' || ps | sed 's/^/    /'
echo

echo "════════ ② 关键进程的启动时刻（从 /proc/PID/stat 第22字段换算）════════"
for p in 1 342 350; do
	if [ -r "/proc/$p/stat" ]; then
		ST=$(awk '{print $22}' /proc/$p/stat)
		NAME=$(awk '{print $2}' /proc/$p/stat)
		echo "    pid=$p ($NAME)  启动于 uptime $((ST / HZ)) 秒"
	else
		echo "    pid=$p 不存在"
	fi
done
echo "    （若 launcher/dropbear 启动时刻 > 确认脚本执行时刻 → 健康检查必然失败 ✗）"
echo

echo "════════ ③ /slots 里每个文件的 mtime（谁在什么时候写的）════════"
ls -l /slots/ | sed 's/^/    /'
echo
echo "    confirmed.txt 的 mtime 是本次启动之前还是之后？"
echo "      本次启动时刻 ≈ $(date -d "@$(( $(date +%s) - UP ))" 2>/dev/null || echo '无法计算')"
echo "      confirmed.txt mtime = $(date -r /slots/confirmed.txt 2>/dev/null || echo '取不到')"
echo "      boot-info.txt  mtime = $(date -r /slots/boot-info.txt 2>/dev/null || echo '取不到')"
echo

echo "════════ ④ 本次启动 S99 是否真的被执行过：看它有没有留下 stdout 痕迹 ════════"
echo "    （rcS 是前台顺序执行 ✓ 若 S99 跑过，控制台会有 [otaconfirm] 一行 ✓）"
echo "    dmesg 尾部 15 行（看有没有 init 脚本的输出）:"
dmesg 2>/dev/null | tail -15 | sed 's/^/      /'
echo

echo "════════ ⑤ 手动执行一次确认脚本（系统现在是健康的 ✓ 应当成功）════════"
sh -x /etc/init.d/S99otaconfirm start 2>&1 | sed 's/^/    /'
echo
echo "    执行后 /slots 状态:"
echo "      tries       = $(cat /slots/tries)"
echo "      confirmed   :"; sed 's/^/        /' /slots/confirmed.txt
