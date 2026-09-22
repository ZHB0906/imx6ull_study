#!/bin/bash
#
# board-go-live.sh —— 把板子切到 NFS dev 模式（带就绪闸和回滚），以及切回来
#
#   bash emmc/scripts/board-go-live.sh up        # 校验 NFS 根就绪 → 在 eMMC p1 建标记 → 重启 → 验证从 NFS 启动
#   bash emmc/scripts/board-go-live.sh down      # 回滚：关 kill switch → 重启 → 验证从 eMMC 启动
#   bash emmc/scripts/board-go-live.sh status    # 只看当前状态（不改任何东西）
#
# ★ 安全机制说明（这块板子的 U-Boot 没有 bootcount/altbootcmd，所以靠"kill switch"）：
#     板子 eMMC 的 p1(FAT) 里有文件 nfsboot  → U-Boot fatload 到它 → 走 TFTP+NFS 开发模式
#     没有这个文件                          → 直接走 eMMC 固化系统（已知良好）
#
#   ★★ 2026-09-20 重要改动：标记文件从"虚拟机 /tftpboot 上的 nfsboot-on"搬到了
#      "板子 eMMC p1 上的 nfsboot"。原因：
#        旧方案里 U-Boot 的 bootcmd 每次都先 `tftpboot nfsboot-on` 去查标记 ——
#        **没插网线时，U-Boot 的网络初始化/PHY 协商会卡很久** → 桌面迟迟不出现
#        （用户实测："必须插网线才能启动桌面"）。改成 fatload 本地读之后，
#        默认启动路径**完全不碰网络** ✓（U-Boot 环境里的 bootcmd 已同步改好）。
#      另一个好处：回滚不再需要网络 ✓（旧方案里如果 dev 模式起不来，只能靠串口救）。
#
#   文件名必须是 <=8 字符（FAT 8.3 限制）：所以叫 nfsboot，不叫 nfsboot-on。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
NFSEXPORT=/nfs/rootfs/new
# 标记文件在板子 eMMC p1 上（别再放 /tftpboot 了，见文件头说明）
MARKER_NAME=nfsboot          # <=8 字符，符合 FAT 8.3
BOARD_P1=/dev/mmcblk1p1
TFTPSRC=$NEW/buildroot/output/target
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; FAIL=1; }
warn() { printf '  ⚠️ %s\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
FAIL=0

BRUN() { timeout "${T:-120}" $SSH root@$BOARD "$@"; }

# 在板子上挂 p1 并创建/删除标记文件（本地操作，不需要网络）
marker_on() {
	BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
mkdir -p /mnt/p1 && mount $BOARD_P1 /mnt/p1 && touch /mnt/p1/$MARKER_NAME && sync && ls -l /mnt/p1/$MARKER_NAME && umount /mnt/p1"
}
marker_off() {
	BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
mkdir -p /mnt/p1 && mount $BOARD_P1 /mnt/p1 && rm -f /mnt/p1/$MARKER_NAME && sync && umount /mnt/p1 && echo 已删除 /mnt/p1/$MARKER_NAME"
}
marker_show() {
	BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
mkdir -p /mnt/p1 && mount -o ro $BOARD_P1 /mnt/p1 2>/dev/null && { ls -l /mnt/p1/$MARKER_NAME 2>/dev/null || echo '  (没有 $MARKER_NAME → 固化模式)'; } ; umount /mnt/p1 2>/dev/null; true"
}

wait_ssh() { # 等板子起来
	local i
	for i in $(seq 1 40); do
		if timeout 8 $SSH root@$BOARD 'echo ok' 2>/dev/null | grep -q ok; then
			echo "  SSH 就绪（约 $((i*5))s）"
			return 0
		fi
		sleep 5
	done
	return 1
}

show_board_state() {
	echo "  板子当前状态："
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
  echo "    根文件系统: $(mount | awk "/ \/ /{print \$1\" (\"\$5\")\"}")"
  echo "    cmdline:    $(cat /proc/cmdline | cut -c1-90)"
  show() { if ls $2 >/dev/null 2>&1; then echo "    $1: $(ls $2 | head -1)"; else echo "    $1: 缺失 ✗"; fi; }
  show "Qt5 库  " "/usr/lib/libQt5Widgets.so.5*"
  show "linuxfb " "/usr/lib/qt/plugins/platforms/libqlinuxfb.so"
  show "evdevtouch" "/usr/lib/qt/plugins/generic/libqevdevtouchplugin.so"
  show "程序    " "/opt/serialtool/SerialTool"' 2>&1 | sed 's/^/  /'
}

case "${1:-}" in

up)
	say "① NFS 根就绪闸（不齐全就不切，免得切过去是个坏系统）"
	[ -x "$TFTPSRC/usr/lib/libQt5Widgets.so.5.11.3" ] || \
		die "$TFTPSRC 里没有 Qt5 库 —— 是不是还没编完？先跑 qt-finish.sh"
	if [ ! -f "$NFSEXPORT/usr/lib/libQt5Widgets.so.5.11.3" ]; then
		warn "NFS 根里还没有 Qt5 库 → 先跑 deploy-nfs-rootfs.sh 铺一遍"
		bash "$NEW/scripts/deploy-nfs-rootfs.sh" || die "部署失败"
	fi
	[ -f "$NFSEXPORT/.nfs-ready" ] && ok "NFS 根有就绪标记" || warn "NFS 根没有就绪标记（deploy 没跑成功？）"
	ls -d "$NFSEXPORT/usr/lib/libQt5Widgets.so.5.11.3" >/dev/null 2>&1 && ok "NFS 根里有 Qt5 库" || die "NFS 根里没有 Qt5 库"

	say "② 打开 kill switch（在板子 eMMC p1 上创建 $MARKER_NAME）"
	marker_on | sed 's/^/  /' || die "创建标记失败"
	ok "已启用 dev 模式（下次重启走 TFTP+NFS）"

	say "③ 重启板子，进入 NFS dev 模式"
	BRUN 'sync; /sbin/reboot' >/dev/null 2>&1 || true
	echo "  已发重启，等待…"
	sleep 8
	wait_ssh || { echo; echo "❌ 等不到 SSH。回滚办法："; echo "   bash emmc/scripts/board-go-live.sh down   （会自动 SSH 进去删标记；若 SSH 也不通，只能断电重上电）"; exit 1; }

	say "④ 验证确实从 NFS 启动了"
	ROOTSRC=$(BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; mount | awk "/ \/ /{print \$1}"')
	echo "  根挂载源: $ROOTSRC"
	case "$ROOTSRC" in
		*nfs*|*:*) ok "确认是 NFS 根（dev 模式）" ;;
		*) bad "不是 NFS 根 —— 板子可能没走 dev 模式（检查 U-Boot 里 bootcmd 与 tftp 是否可达）" ;;
	esac
	show_board_state

	say "⑤ 回滚办法（记住这个）"
	echo "   bash emmc/scripts/board-go-live.sh down     # 关掉标记并重启（★ 不需要网络也能救回来）"
	;;

down)
	say "① 关闭 kill switch（在板子 eMMC p1 上删除 $MARKER_NAME）"
	marker_off | sed 's/^/  /' || warn "删除标记时出错（板子可能已经在 eMMC 模式）"
	ok "已禁用 dev 模式（下次重启走 eMMC）"

	say "② 重启板子"
	BRUN 'sync; /sbin/reboot' >/dev/null 2>&1 || true
	sleep 8
	wait_ssh || { warn "等不到 SSH（板子可能正在从 eMMC 启动，稍等再试）"; exit 1; }

	say "③ 验证从 eMMC 启动"
	ROOTSRC=$(BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; mount | awk "/ \/ /{print \$1}"')
	echo "  根挂载源: $ROOTSRC"
	case "$ROOTSRC" in
		*nfs*|*:*) bad "还是 NFS 根 —— 标记没关掉？" ;;
		*) ok "确认从 eMMC 启动（已知良好系统）" ;;
	esac
	show_board_state
	;;

status)
	say "kill switch 状态（板子 eMMC p1 上的 $MARKER_NAME）"
	marker_show | sed 's/^/  /'
	echo "  → 文件在 = dev 模式（重启走 TFTP+NFS）；不在 = 固化模式（重启走 eMMC）"
	echo "  U-Boot 的 bootcmd:"
	BRUN 'fw_printenv bootcmd 2>/dev/null | cut -c1-110' 2>/dev/null | sed 's/^/    /'
	ls -l "$NFSEXPORT/.nfs-ready" 2>/dev/null | sed 's/^/  /'
	say "板子状态"
	show_board_state
	;;

*)
	sed -n '2,14p' "$0"; exit 1 ;;
esac
