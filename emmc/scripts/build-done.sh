#!/bin/bash
#
# build-done.sh —— 一条命令回答"编译完了没有？"
#
#   bash emmc/scripts/build-done.sh
#
# 退出码：0=编完了  1=还在编  2=编失败了（方便脚本里用）
#
# 判据说明：日志里那些 `Error 1` 大多是 Qt configure 的特性探测失败（属正常），
# 真失败只有 `pkg-generic.mk:...: Error` 和 `_all] Error` 两条信号。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
LOG=$NEW/out/build-buildroot.log
B=$BR/output/build
QT=$B/qt5base-5.11.3

echo "─────────────── $(date +'%H:%M:%S') ───────────────"

if pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
	phase=$(grep -oE '^>>> [^ ]+ [^ ]+ (Configuring|Building|Installing)' "$LOG" 2>/dev/null | tail -1)
	total=$(find "$QT" -name "*.o" 2>/dev/null | wc -l)
	recent=$(find "$QT" -name "*.o" -newermt "-5 minutes" 2>/dev/null | wc -l)
	rate=$(( recent / 5 ))
	echo "⏳ 还在编译"
	echo "   阶段：${phase:-（未识别）}"
	echo "   qtbase 已编译 .o：$total"
	if [ "$rate" -gt 0 ]; then
		remain=$(( 2000 - total )); [ "$remain" -lt 0 ] && remain=0
		echo "   速率：$rate 个/分钟 → 粗估 qtbase 还要 ~$(( remain / rate )) 分钟"
	fi
	echo
	echo "   想更详细：bash $NEW/scripts/build-progress.sh"
	exit 1
fi

# 没在跑 → 是真编完了还是挂了？
rfail=$(grep -c "pkg-generic.mk:[0-9]*: .*Error" "$LOG" 2>/dev/null); rfail=${rfail:-0}
tfail=$(grep -c "_all\] Error" "$LOG" 2>/dev/null); tfail=${tfail:-0}

if [ "$rfail" != 0 ] || [ "$tfail" != 0 ]; then
	echo "❌ 编译失败（包失败 $rfail 次 / 顶层失败 $tfail 次）"
	echo "   日志最后 8 行："
	tail -8 "$LOG" | cut -c1-130 | sed 's/^/     /'
	exit 2
fi

# 没在跑也没报错 → 查关键产物
echo "✅ 编译进程已结束，且没有真失败信号"
miss=0
for f in "$BR/output/host/bin/qmake" \
         "$BR/output/target/usr/lib/libQt5Core.so.5.11.3" \
         "$BR/output/target/usr/lib/libQt5Widgets.so.5.11.3" \
         "$BR/output/target/usr/lib/qt/plugins/platforms/libqlinuxfb.so" \
         "$BR/output/target/usr/lib/qt/plugins/generic/libqevdevtouchplugin.so" \
         "$BR/output/target/usr/bin/qmake" ; do
	if [ -e "$f" ]; then printf '   ✅ %s\n' "${f#$BR/output/}"
	else printf '   ⚠️ 缺 %s\n' "${f#$BR/output/}"; miss=$((miss+1)); fi
done
if [ "$miss" = 0 ]; then
	echo
	echo "🎉 可以往下走了，执行："
	echo "   bash $NEW/scripts/qt-finish.sh all"
	exit 0
else
	echo
	echo "⚠️ 有 $miss 项关键产物缺失 —— 可能没编到 Qt 的安装阶段，先看 qt-finish.sh check"
	exit 1
fi
