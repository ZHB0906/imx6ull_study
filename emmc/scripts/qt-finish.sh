#!/bin/bash
#
# qt-finish.sh —— Qt 编完之后的收尾链（一条命令走到底，每步都有判据）
#
#   bash emmc/scripts/qt-finish.sh check      # 只查 Qt 产物是否齐全（不发任何编译）
#   bash emmc/scripts/qt-finish.sh qscintilla # 重生成配置(带 QSCINTILLA) + 编 QScintilla + 验证 .prf
#   bash emmc/scripts/qt-finish.sh serialtool # 交叉编译 SerialTool + 推到板子
#   bash emmc/scripts/qt-finish.sh all        # check + qscintilla + serialtool（不含部署/固化）
#
# 为什么单独写：Qt 编完之后有一串**顺序敏感**的步骤，而且有几个"静默失效"的点
# （QScintilla 的 .prf 装错位置、qmake 不带交叉 spec、.config 里符号被丢），
# 所以每一步都带硬判据，失败立刻停，不要带着坏状态往下走。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
B=$BR/output/build
HOST=$BR/output/host
SYSROOT=$HOST/arm-buildroot-linux-gnueabihf/sysroot
QT=$B/qt5base-5.11.3

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; FAIL=1; }
warn() { printf '  ⚠️ %s\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
FAIL=0

build_running() { pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────── check
do_check() {
	say "① Qt 产物检查"
	[ -d "$QT" ] || die "qt5base 目录都不在，Qt 没开始编？"

	local total
	total=$(find "$QT" -name "*.o" 2>/dev/null | wc -l)
	echo "  qt5base 已编译 .o：$total"

	echo
	echo "  --- 关键库（target 侧）---"
	for lib in Qt5Core Qt5Gui Qt5Widgets Qt5Network Qt5PrintSupport Qt5Xml Qt5SerialPort Qt5Charts Qt5Script; do
		if ls "$BR/output/target/usr/lib/lib$lib.so.5"* >/dev/null 2>&1; then
			ok "$lib 已装进 target"
		else
			warn "$lib 不在 target（qt5base 还没装完？或该模块未编）"
		fi
	done

	echo
	echo "  --- 关键插件（决定能不能跑起来）---"
	for p in "platforms/libqlinuxfb.so" "generic/libqevdevtouchplugin.so"; do
		if [ -f "$BR/output/target/usr/lib/qt/plugins/$p" ]; then
			ok "$p"
		else
			bad "$p 缺失 —— linuxfb/触摸会起不来"
		fi
	done

	echo
	echo "  --- 宿主工具（交叉编译要用）---"
	for t in qmake moc uic rcc; do
		if [ -x "$HOST/bin/$t" ]; then ok "$t"; else bad "$t 缺失"; fi
	done
	if [ -d "$HOST/mkspecs/devices/linux-buildroot-g++" ]; then
		ok "交叉 spec devices/linux-buildroot-g++"
	else
		bad "交叉 spec 目录缺失"
	fi

	echo
	echo "  --- configure 摘要里的关键结论 ---"
	if [ -f "$QT/config.summary" ]; then
		grep -iE "evdev|tslib|libinput|linuxfb|eglfs|opengl|fontconfig|freetype|harfbuzz" "$QT/config.summary" |
			head -20 | sed 's/^/    /'
	else
		warn "没有 config.summary（可能在别的位置）"
		grep -iE "evdev|linuxfb" "$QT/config.log" 2>/dev/null | head -8 | sed 's/^/    /'
	fi

	echo
	echo "  --- 别的 Qt 模块 ---"
	for p in qt5serialport qt5charts qt5script; do
		if ls -d "$B"/$p-* >/dev/null 2>&1 && [ -f "$B"/$p-*/.stamp_target_installed ]; then
			ok "$p 完成"
		else
			bad "$p 未完成"
		fi
	done

	echo
	[ "$FAIL" = 0 ] && echo "✅ 检查通过，可以往下走" || echo "❌ 有缺失，先别往下走"
	return "$FAIL"
}

# ─────────────────────────────────────────────────────────── qscintilla
do_qscintilla() {
	say "② 重生成配置（启用 QSCINTILLA=y）并编 QScintilla"
	build_running && die "构建还在跑！不能同时重生成配置（会打架）。等它结束再来。"
	[ -x "$HOST/bin/qmake" ] || die "宿主 qmake 还没有 —— Qt5 还没编完"

	echo "  --- 重生成配置 ---"
	sh "$NEW/scripts/br2-setup.sh" >/tmp/br2-setup.log 2>&1 || { tail -20 /tmp/br2-setup.log | sed 's/^/    /'; die "br2-setup.sh 失败"; }
	tail -14 /tmp/br2-setup.log | sed 's/^/    /'

	echo "  --- 硬判据：.config 里必须有 QSCINTILLA=y ---"
	grep -q '^BR2_PACKAGE_QSCINTILLA=y' "$BR/.config" \
		&& ok "BR2_PACKAGE_QSCINTILLA=y 在 .config 里" \
		|| die "QSCINTILLA 符号被丢掉了！（检查 br2-external/Config.in 是否被 source）"

	echo "  --- 编 QScintilla（顺带让 Buildroot 重跑 target-finalize）---"
	bash "$NEW/scripts/br2-build.sh" 2>&1 | tail -25 | sed 's/^/    /'

	echo "  --- QScintilla 产物 ---"
	[ -f "$SYSROOT/usr/lib/libqscintilla2_qt5.so" ] && ok "staging 里有 libqscintilla2_qt5.so" || bad "staging 里没有 QScintilla 库"
	[ -d "$SYSROOT/usr/include/qt5/Qsci" ] && ok "staging 里有 Qsci 头文件" || bad "staging 里没有 Qsci 头文件"

	echo "  --- ★ 硬判据：.prf 必须装在 qmake 真正搜索的两处 ---"
	for p in "$HOST/mkspecs/features/qscintilla2.prf" "$SYSROOT/usr/lib/qt/mkspecs/features/qscintilla2.prf"; do
		[ -f "$p" ] && ok "$p" || bad "$p 缺失（CONFIG += qscintilla2 会静默失效）"
	done

	echo "  --- ★ 实证：让 qmake 解析一个用 qscintilla2 的工程，看 Makefile 里有没有链接项 ---"
	local t=/tmp/qscitest
	rm -rf $t; mkdir -p $t
	printf 'QT += core\nCONFIG += qscintilla2\nTARGET=x\nTEMPLATE=app\nSOURCES+=m.cpp\n' > $t/x.pro
	printf 'int main(){return 0;}\n' > $t/m.cpp
	(cd $t && "$HOST/bin/qmake" -spec devices/linux-buildroot-g++ x.pro >/dev/null 2>&1)
	if grep -q -- "-lqscintilla2_qt5" $t/Makefile 2>/dev/null; then
		ok "qmake 确实识别了 qscintilla2（Makefile 里有 -lqscintilla2_qt5）"
	else
		bad "Makefile 里没有 -lqscintilla2_qt5 —— .prf 没生效"
	fi

	echo
	[ "$FAIL" = 0 ] && echo "✅ QScintilla 就绪" || echo "❌ QScintilla 有问题"
	return "$FAIL"
}

# ─────────────────────────────────────────────────────────── serialtool
do_serialtool() {
	say "③ 交叉编译 SerialTool 并推上板子"
	[ -x "$HOST/bin/qmake" ] || die "宿主 qmake 还没有"
	bash "$NEW/scripts/build-serialtool.sh" all 2>&1 | tail -30 | sed 's/^/  /'
}

case "${1:-all}" in
check)      do_check ;;
qscintilla) do_qscintilla ;;
serialtool) do_serialtool ;;
all)
	do_check || exit 1
	do_qscintilla || exit 1
	do_serialtool || exit 1
	echo
	echo "✅ 全部完成。下一步："
	echo "   bash emmc/scripts/deploy-nfs-rootfs.sh      # 铺到 NFS 根"
	echo "   mv /tftpboot/nfsboot-on.disabled /tftpboot/nfsboot-on && bash -c 'ssh ... reboot'   # 进 dev 模式"
	echo "   bash emmc/scripts/qt-minimal-test.sh        # 验证 linuxfb/字体/帧率"
	;;
*) sed -n '2,12p' "$0"; exit 1 ;;
esac
