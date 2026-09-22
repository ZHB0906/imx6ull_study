#!/bin/bash
#
# wait-qt-config.sh —— 等 qt5base 的 configure 摘要出现，抓出"平台/输入插件"相关结论
#
# 为什么需要它：Buildroot 2019.02 的 qt5base.mk 里**没有 -evdev 开关**，
# 所以 Qt 的 evdevtouch 插件能不能编出来，只能看 Qt 自己 configure 的结论；
# 而它决定板子上触摸能不能用（我们的 run.sh 靠 QT_QPA_GENERIC_PLUGINS=evdevtouch）。
#
set -uo pipefail

B=/home/zhb/linux-projects/emmc/buildroot/output/build
LOG=/home/zhb/linux-projects/emmc/out/build-buildroot.log

for i in $(seq 1 240); do          # 最多等 2 小时（30s 一次）
	sum=$(ls "$B"/qt5base-*/config.summary 2>/dev/null | head -1)
	if [ -n "$sum" ]; then
		echo "=== qt5base configure 摘要出现：$sum（$(date +%H:%M:%S)） ==="
		echo
		echo "--- ★ 触摸/输入/平台（决定板子上能否用 evdevtouch、linuxfb）---"
		grep -iE "evdev|tslib|libinput|linuxfb|eglfs|opengl|qpa|kms" "$sum" | sed 's/^/  /' || echo "  （摘要里没找到这些关键字）"
		echo
		echo "--- 其它可能影响 SerialTool 的能力 ---"
		grep -iE "fontconfig|freetype|harfbuzz|png|jpeg|gif|zlib|pcre|sql|test|network|printsupport|widgets|gui" "$sum" | sed 's/^/  /'
		echo
		echo "--- 摘要全文（前 60 行，便于回看）---"
		head -60 "$sum" | sed 's/^/  /'
		exit 0
	fi

	# 构建若已结束（正常或失败）就没必要等了
	if ! pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
		echo "!! br2-build.sh 已不在运行，停止等待"
		echo "--- 日志尾 ---"; tail -8 "$LOG" | cut -c1-140 | sed 's/^/  /'
		exit 1
	fi
	sleep 30
done

echo "!! 超时（2 小时）仍未见 configure 摘要"
tail -5 "$LOG" | cut -c1-140 | sed 's/^/  /'
exit 2
