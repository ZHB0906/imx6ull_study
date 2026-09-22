#!/bin/bash
#
# build-status.sh —— 一眼看懂 Buildroot 编译进度
#
#     bash emmc/scripts/build-status.sh          # 看一次
#     bash emmc/scripts/build-status.sh -f       # 每 5 秒刷新（Ctrl-C 退出）
#
# 回答四个问题：还在编吗？编到哪一步了？出错没有？rootfs 好了没有？
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
B=$NEW/buildroot/output/build
LOG=$NEW/out/build-buildroot.log
TARGET=$NEW/buildroot/output/target

# 一个包的状态：done / doing / todo
pkg_state() { # $1 = 目录名通配
	local d
	d=$(ls -d "$B"/$1 2>/dev/null | head -1)
	[ -z "$d" ] && { echo todo; return; }
	[ -f "$d/.stamp_built" ] && echo done || echo doing
}
mark() { case "$1" in done) echo "✅";; doing) echo "🔄";; *) echo "⏳";; esac; }

# 包名 → 人话
explain() {
	case "$1" in
	host-gcc-initial*) echo "初始交叉编译器（只能编 C，最慢的一个）" ;;
	host-gcc-final*|gcc-final*) echo "最终交叉编译器（含 C++，也很慢）" ;;
	glibc*)            echo "C 运行库（板子上每个程序都依赖）" ;;
	linux-headers*)    echo "内核头文件（用户态程序编译要用）" ;;
	host-binutils*|binutils*) echo "汇编器 / 链接器" ;;
	busybox*)          echo "板子的基础命令集（sh/ls/mount/telnetd…）" ;;
	wpa_supplicant*)   echo "WiFi 连接工具（连 Red 用它）" ;;
	iw*)               echo "无线调试工具" ;;
	wireless_tools*)   echo "老式无线工具（iwconfig）" ;;
	tslib*)            echo "触摸屏库" ;;
	dropbear*)         echo "SSH 服务端" ;;
	libnl*)            echo "netlink 库（wpa_supplicant 依赖）" ;;
	host-gmp*|host-mpfr*|host-mpc*|host-isl*) echo "编 GCC 要用的数学库" ;;
	*)                 echo "" ;;
	esac
}

status_once() {
	echo "════════ Buildroot 编译状态 @ $(date '+%H:%M:%S') ════════"

	# 1) 还在编吗
	if pgrep -x make >/dev/null 2>&1; then
		local et; et=$(ps -o etimes= -p "$(pgrep -x make | head -1)" 2>/dev/null | tr -d ' ')
		printf '  编译进程 : ✅ 在跑（make -j2，已运行 %d 分 %d 秒）\n' $(( ${et:-0} / 60 )) $(( ${et:-0} % 60 ))
	else
		echo "  编译进程 : ⏹  已停（编完了，或出错停了 —— 看下面「错误」）"
	fi

	# 2) 当前阶段（日志里最后一条 >>> 标记）
	local cur; cur=$(grep -oE '^>>> [^ ]+ [^ ]+ [A-Za-z]+' "$LOG" 2>/dev/null | tail -1)
	if [ -n "$cur" ]; then
		local name; name=$(echo "$cur" | awk '{print $2}')
		local e; e=$(explain "$name")
		echo "  当前阶段 : ${cur#>>> }"
		[ -n "$e" ] && echo "             ↳ $e"
	fi

	# 3) 交叉工具链路线图（这条链走完才有板子的编译器）
	echo "  工具链进度："
	local s
	s=$(pkg_state 'host-binutils-*');        printf '    %s 1) binutils（汇编/链接）          %s\n' "$(mark $s)" "$s"
	s=$(pkg_state 'host-gcc-initial-*');     printf '    %s 2) gcc 初始编译器               %s\n' "$(mark $s)" "$s"
	s=$(pkg_state 'linux-headers-*');        printf '    %s 3) linux-headers 4.1.15         %s\n' "$(mark $s)" "$s"
	s=$(pkg_state 'glibc-*');                printf '    %s 4) glibc 2.29（C 运行库）        %s\n' "$(mark $s)" "$s"
	s=$(pkg_state 'host-gcc-final-*');       printf '    %s 5) gcc 最终编译器（含 C++）      %s\n' "$(mark $s)" "$s"

	# 4) 目标包进度
	local tdone=0 ttotal=0 d n
	for d in "$B"/*/; do
		[ -d "$d" ] || continue
		n=$(basename "$d")
		case "$n" in host-*|buildroot-config) continue;; esac
		ttotal=$((ttotal + 1))
		[ -f "$d/.stamp_built" ] && tdone=$((tdone + 1))
	done
	echo "  板子上的包 : $tdone 个已编完（共 $ttotal 个已开始；还有若干没开始）"

	# 5) 错误
	# ★ 不能只数 "Error [0-9]"：Qt 的 configure 会大量编译特性探测小程序，
	#   探测失败是**预期行为**（例如 config.tests/libudev 因缺 libudev.h 报 Error 1
	#   → 该特性关闭）。那些行在日志里带 "> " 前缀（子 make 的输出）。
	#   真正的失败信号只有下面两条（详见操作记录【45】）。
	local rfail tfail
	rfail=$(grep -c "pkg-generic.mk:[0-9]*: .*Error" "$LOG" 2>/dev/null); rfail=${rfail:-0}
	tfail=$(grep -c "_all\] Error" "$LOG" 2>/dev/null); tfail=${tfail:-0}
	local raw; raw=$(grep -cE "Error [0-9]" "$LOG" 2>/dev/null); raw=${raw:-0}
	if [ "$rfail" = "0" ] && [ "$tfail" = "0" ]; then
		echo "  错误     : ✅ 真失败 0 条（日志里另有 $raw 条 'Error N'，多为 configure 特性探测失败，属正常）"
	else
		echo "  错误     : ❌ 包构建失败 $rfail 条 / 顶层失败 $tfail 条 —— 日志最后几行："
		tail -5 "$LOG" | cut -c1-120 | sed 's/^/             /'
	fi

	# 6) 最终产物
	if [ -e "$TARGET/bin/busybox" ]; then
		echo "  最终产物 : ✅ output/target/ 组装完成（可以铺 NFS 了）"
	else
		echo "  最终产物 : ⏳ 未完成（还在编工具链/包）"
	fi

	# 7) 日志尾部：它在干什么
	echo "  日志尾部 :"
	tail -2 "$LOG" 2>/dev/null | cut -c1-108 | sed 's/^/             /'
	echo "════════════════════════════════════════════════"
}

if [ "${1:-}" = "-f" ]; then
	while true; do clear; status_once; echo "（每 5 秒刷新，Ctrl-C 退出）"; sleep 5; done
else
	status_once
fi
