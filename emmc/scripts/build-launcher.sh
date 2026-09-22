#!/bin/bash
#
# build-launcher.sh —— 交叉编译"桌面"（atk-launcher）并部署
#
#   bash emmc/scripts/build-launcher.sh build   # 只交叉编译
#   bash emmc/scripts/build-launcher.sh push    # 推到板子 /opt/launcher/ 并装 init 脚本
#   bash emmc/scripts/build-launcher.sh start   # 在板子上启动桌面会话
#   bash emmc/scripts/build-launcher.sh all     # build + push + start
#
# 同时会把二进制**复制进 rootfs overlay**（br2-external/.../rootfs-overlay/opt/launcher/），
# 这样以后重新 build rootfs / 固化到 eMMC 时它会自动包含进去 ✓
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
SRC=$NEW/apps/launcher
WORK=$NEW/apps/build-launcher
HOST=$BR/output/host
QMAKE=$HOST/bin/qmake
# ★ 必须显式带交叉 spec（不带的 qmake 会用宿主 x86-64 spec 编出 PC 程序）
QSPEC="devices/linux-buildroot-g++"
OVERLAY=$NEW/br2-external/board/atk/rootfs-overlay
STAGE=$NEW/apps/launcher-stage
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

do_build() {
	say "① 交叉编译桌面程序"
	[ -x "$QMAKE" ] || die "找不到 $QMAKE —— Qt5 还没编完？"
	rm -rf "$WORK"; mkdir -p "$WORK"; cp -a "$SRC/." "$WORK/"
	(cd "$WORK" && "$QMAKE" -spec "$QSPEC" launcher.pro 2>&1 | tail -3 && make -j2 2>&1 | tail -12)
	local bin=$WORK/launcher
	[ -x "$bin" ] || die "没有产出可执行文件"
	file "$bin" | cut -c1-110 | sed 's/^/  /'
	# 硬判据：必须是 ARM，不能是 x86-64
	file "$bin" | grep -q "ARM" || die "编出来的不是 ARM 二进制 —— qmake 的 spec 没生效！"
	ls -lh "$bin" | awk '{print "  大小: "$5}'

	say "② 放进 staging 与 rootfs overlay（供以后固化用）"
	rm -rf "$STAGE"; mkdir -p "$STAGE"
	cp "$bin" "$STAGE/launcher"
	cp "$OVERLAY/opt/launcher/session.sh" "$STAGE/session.sh"
	cp "$OVERLAY/etc/init.d/S12launcher" "$STAGE/S12launcher"
	# 二进制进 overlay（session.sh / S12launcher 本来就在 overlay 里，无需复制）
	mkdir -p "$OVERLAY/opt/launcher"
	cp "$bin" "$OVERLAY/opt/launcher/launcher"
	echo "  已放入 overlay: $OVERLAY/opt/launcher/launcher"
	ls -l "$STAGE" | sed 's/^/  /'
}

do_push() {
	say "③ 推到板子 /opt/launcher/ 并安装"
	[ -d "$STAGE" ] || die "先 build"
	# ★ 每次推送前都从 overlay 重新取脚本：否则可能推上去一份过期的 stage 副本
	#   （踩过：stage 是旧的，把板子上正确的 session.sh 覆盖回旧版本 ✗）
	cp -f "$OVERLAY/opt/launcher/session.sh" "$STAGE/session.sh"
	cp -f "$OVERLAY/etc/init.d/S12launcher"  "$STAGE/S12launcher"
	( cd "$STAGE" && tar cf - . ) | gzip -c | \
		timeout 300 $SSH root@$BOARD 'mkdir -p /opt/launcher && cd /opt/launcher && gzip -d | tar xf - && chmod 755 launcher session.sh && cp -f S12launcher /etc/init.d/S12launcher && chmod 755 /etc/init.d/S12launcher && echo "  已部署:" && ls -l /opt/launcher'

	say "④ 停掉可能正在跑的应用/桌面（避免两个进程抢触摸）"
	timeout 60 $SSH root@$BOARD 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
for p in $(pidof SerialTool 2>/dev/null) $(pidof launcher 2>/dev/null) $(pidof qttest 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
# 匹配所有以 session.sh 结尾的进程（./session.sh 与 /opt/launcher/session.sh 都要覆盖）
for p in $(ps -eo pid,args | awk "\$NF ~ /session\\.sh\$/ {print \$1}"); do kill -9 "$p" 2>/dev/null; done
sleep 1
rm -f /tmp/LCK..ttymxc2
echo "  清理完成（SerialTool/launcher/qttest 均已退出）"'
}

do_start() {
	say "⑤ 在板子上启动桌面会话"
	timeout 90 $SSH root@$BOARD 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
cd /opt/launcher
if command -v setsid >/dev/null 2>&1; then
  setsid ./session.sh > /tmp/launcher.log 2>&1 < /dev/null &
else
  ./session.sh > /tmp/launcher.log 2>&1 < /dev/null &
fi
sleep 6
echo "  launcher 进程: $(pidof launcher 2>/dev/null || echo 未启动)"
echo "  session 进程: $(ps -eo pid,args | awk "\$NF==\"/opt/launcher/session.sh\" {print \$1}" | tr "\n" " ")"
echo "  --- 日志 ---"
head -12 /tmp/launcher.log | sed "s/^/    /"'
}

case "${1:-all}" in
build) do_build ;;
push)  do_push ;;
start) do_start ;;
all)   do_build && do_push && do_start ;;
*)     sed -n '2,12p' "$0"; exit 1 ;;
esac
