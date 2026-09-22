#!/bin/bash
#
# watch-detached-build.sh —— 等"脱离会话的构建"结束，然后退出（退出即通知会话）
#
# 为什么需要：为了不被会话中断杀掉，构建是用 setsid nohup 起的（独立会话），
# 但它因此**不再是本会话的后台作业**，我就收不到完成通知了。
# 这个哨兵只做一件事：每 30 秒看一眼构建进程还在不在，不在了就退出（= 通知我）。
# 它自己被杀掉也无所谓（构建不受影响），会话恢复后重挂一个即可。
#
set -uo pipefail
LOG=/home/zhb/linux-projects/emmc/out/build-buildroot.log

for i in $(seq 1 400); do        # 最多等 ~3.3 小时
	if ! pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
		echo "构建进程已结束（$(date +%H:%M:%S)）"
		echo "--- 真失败信号 ---"
		echo "  pkg-generic: $(grep -c 'pkg-generic.mk:[0-9]*: .*Error' "$LOG" 2>/dev/null)"
		echo "  _all] Error: $(grep -c '_all\] Error' "$LOG" 2>/dev/null)"
		echo "--- 日志尾 ---"
		tail -6 "$LOG" | cut -c1-130
		exit 0
	fi
	sleep 30
done

echo "!! 等待超时（3.3 小时）—— 构建可能还在跑，手动看一眼"
exit 2
