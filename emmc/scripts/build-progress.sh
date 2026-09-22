#!/bin/bash
#
# build-progress.sh —— 一眼看清"现在编到哪、还要多久、有没有出错"
#
#   bash emmc/scripts/build-progress.sh
#
# 判据说明（★ 很重要，我踩过坑）：
#   日志里 `Error 1` 有一大堆，但**大部分是 Qt configure 的特性探测失败**
#   （例如 config.tests/libudev 因为没装 libudev 而报错 = 该特性关闭，属预期行为）。
#   真正的失败信号只有：
#       pkg-generic.mk:<行号>: ... Error      ← 包构建失败
#       _all] Error                            ← 顶层目标失败
#   所以别看 `grep -c 'Error [0-9]'`，会被吓到（我曾以为构建又挂了）。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
LOG=$NEW/out/build-buildroot.log
B=$BR/output/build
QT=$B/qt5base-5.11.3

# ── 当前在编哪个包（从日志最后若干行里找最近的 ">>> xxx Configuring/Building"）──
last_pkg=$(grep -oE '^>>> [^ ]+ [^ ]+ (Downloading|Extracting|Patching|Configuring|Building|Installing)' "$LOG" 2>/dev/null | tail -1)

echo "════════════════════════════════════════════════════════"
echo " 构建进度  $(date +'%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════"

# ── 进程 ──
if pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
	echo " 状态：运行中 ✅"
else
	echo " 状态：❌ 没在跑（编完了？还是挂了？看下面的失败信号）"
fi
echo " 最近阶段：${last_pkg:-（日志里没找到）}"

# ── 真失败信号 ──
# ★ 别写 `grep -c xxx || echo 0`：无匹配时 grep 已经输出 "0" 且返回 1，
#   `|| echo 0` 会再追加一行 → 变量变成 "0\n0"，判据全乱（刚踩过）。
real_fail=$(grep -c "pkg-generic.mk:[0-9]*: .*Error" "$LOG" 2>/dev/null)
top_fail=$(grep -c "_all\] Error" "$LOG" 2>/dev/null)
real_fail=${real_fail:-0}
top_fail=${top_fail:-0}
if [ "$real_fail" = 0 ] && [ "$top_fail" = 0 ]; then
	echo " 健康度：真失败信号 0 ✅（日志里的 'Error 1' 多为 configure 探测失败，属正常）"
else
	echo " 健康度：❌ 包构建失败 $real_fail 次 / 顶层失败 $top_fail 次 —— 去看日志尾部"
fi

# ── qt5base 细粒度进度 ──
if [ -d "$QT" ]; then
	echo
	echo "── qt5base 5.11.3 ──────────────────────────────────────"
	total=$(find "$QT" -name "*.o" 2>/dev/null | wc -l)
	echo " 已编译 .o：$total"
	# 速率：同时看 3 分钟和 10 分钟窗口，取较大值
	# ★ 构建刚重启后的 5/10 分钟窗口里含"中断的死时间"，会严重低估速率
	#   （曾因此算出"还要 628 分钟 / 175 分钟"这种鬼数字）。3 分钟窗口恢复得快。
	recent3=$(find "$QT" -name "*.o" -newermt "-3 minutes" 2>/dev/null | wc -l)
	recent10=$(find "$QT" -name "*.o" -newermt "-10 minutes" 2>/dev/null | wc -l)
	r3=$(( recent3 / 3 )); r10=$(( recent10 / 10 ))
	rate=$r3; [ "$r10" -gt "$rate" ] && rate=$r10
	if [ "$rate" -gt 0 ]; then
		echo " 速率：约 $rate 个/分钟（3 分钟窗口 $r3，10 分钟窗口 $r10）"
		# 参考：corelib+gui+widgets 约 900 个 .cpp，加上 moc 生成、tools、plugins、3rdparty，
		# 整个 qtbase 约 1500~1600 个 .o（比按 2000 估更贴合实际）
		remain=$(( 1550 - total ))
		[ "$remain" -lt 0 ] && remain=0
		echo " 粗估：还要约 $(( remain / rate )) 分钟编完 qtbase（Gui/Widgets 单文件更大，实际可能略慢）"
	else
		echo " 速率：最近 5 分钟没有新增（可能在链接、装插件，或卡住了）"
	fi
	echo
	echo " 分模块："
	for m in "src/corelib:QtCore" "src/tools/uic:uic" "src/tools/moc:moc" "src/tools/rcc:rcc" \
	         "src/gui:QtGui" "src/widgets:QtWidgets" "src/network:QtNetwork" "src/plugins:插件"; do
		d=${m%%:*}; name=${m##*:}
		c=$(find "$QT/$d" -name "*.o" 2>/dev/null | wc -l)
		[ "$c" -gt 0 ] && printf "   %-12s %4d\n" "$name" "$c"
	done
	echo
	echo " 已产出的库："
	ls "$QT"/lib/libQt5*.so.5.11.3 2>/dev/null | sed 's|.*/|   |' || echo "   （还没有，QtCore 尚未完成链接）"
else
	echo
	echo "（qt5base 还没开始解包）"
fi

# ── 其它 Qt 模块 ──
echo
echo "── 其它 Qt 模块 ────────────────────────────────────────"
for p in qt5serialport qt5charts qt5script qscintilla; do
	if ls -d "$B"/$p-* >/dev/null 2>&1; then
		if [ -f "$B"/$p-*/.stamp_target_installed ]; then
			printf "   %-16s ✅ 已完成\n" "$p"
		else
			printf "   %-16s ⏳ 进行中\n" "$p"
		fi
	else
		printf "   %-16s — 还没开始\n" "$p"
	fi
done

# ── 磁盘/内存 ──
echo
echo "── 环境 ────────────────────────────────────────────────"
df -h /home | tail -1 | awk '{printf "   磁盘 /home: 已用 %s / 共 %s（剩 %s）\n", $3, $2, $4}'
free -m | awk 'NR==2{printf "   内存: 已用 %sM / 共 %sM\n", $3, $2} NR==3{printf "   Swap: 已用 %sM / 共 %sM\n", $3, $2}'
uptime | sed 's/^/   负载: /'
echo "════════════════════════════════════════════════════════"
