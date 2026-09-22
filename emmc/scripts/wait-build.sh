#!/bin/bash
#
# wait-build.sh —— "看门"脚本：等 Buildroot 编完（或失败）再退出
#
# 为什么需要它：
#   真正的编译是用 setsid 脱离启动的（这样我自己的命令被中止也杀不到它），
#   但代价是运行环境不知道它存在、编完不会通知我。
#   所以再起一个**管理型**后台任务跑这个脚本：
#   它只等 make 消失就退出 —— 它一退出，运行环境就会给我发通知，我就能自动接着做 M4/M5。
#
# 用法（由 agent 以 run_in_background 方式启动）：
#   bash emmc/scripts/wait-build.sh
#
NEW=/home/zhb/linux-projects/emmc
LOG=$NEW/out/build-buildroot.log

echo "看门开始 $(date +%H:%M:%S)（等 make 消失，最多 5 小时）"
for i in $(seq 1 900); do
	if ! pgrep -x make >/dev/null 2>&1; then
		echo "make 已消失，判定构建结束"
		break
	fi
	sleep 20
done

echo
echo "================ Buildroot 结束汇报 $(date +%H:%M:%S) ================"
echo "--- 错误数 ---"
grep -cE "Error [0-9]" "$LOG" 2>/dev/null || echo 0
echo "--- 日志尾部 8 行 ---"
tail -8 "$LOG" 2>/dev/null | cut -c1-140
echo "--- 真实进度（按 stamp）---"
B=$NEW/buildroot/output/build
for d in "$B"/*/; do
	n=$(basename "$d")
	[ "$n" = buildroot-config ] && continue
	st="还在编"
	[ -f "$d/.stamp_built" ] && st="built"
	[ -f "$d/.stamp_target_installed" ] && st="installed"
	printf '  %-26s %s\n' "$n" "$st"
done
echo "--- 产物判据 ---"
for f in "$NEW/buildroot/output/target/bin/busybox" \
         "$NEW/buildroot/output/target/etc/init.d/S45wifi" \
         "$NEW/buildroot/output/target/usr/sbin/wpa_supplicant" \
         "$NEW/buildroot/output/target/usr/sbin/dropbear" \
         "$NEW/buildroot/output/target/lib/modules/4.1.15-ge48931b1-dirty/8189fs.ko"; do
	if [ -e "$f" ]; then echo "  ✅ $(echo "$f" | sed "s|$NEW/buildroot/output/target||")"; else echo "  ❌ $(echo "$f" | sed "s|$NEW/buildroot/output/target||")"; fi
done
echo "--- 交叉工具链 ---"
ls "$NEW/buildroot/output/host/bin/" 2>/dev/null | grep -E "^arm-.*-gcc$|^arm-.*-g\+\+$" | head -3
echo "======================================================================"
