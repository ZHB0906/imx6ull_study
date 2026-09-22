#!/bin/bash
#
# install-bootscr.sh —— 把 boot.scr 装进板子 eMMC 的 FAT 分区(p1)
#
#     bash emmc/scripts/install-bootscr.sh            # 装上（下次重启走新流程）
#     bash emmc/scripts/install-bootscr.sh --remove   # 摘掉（立刻回到 eMMC 启动）
#
# 原理：ATK 的 bootcmd 会先 fatload mmc 1:1 boot.scr 并 source，
#       所以只要这个文件在，就按它启动；删掉就恢复原样。
#       **不改 U-Boot 环境、不动引导程序、不写 env 分区。**
#
# 前提：板子能 SSH（用户 22 或 telnet 23），且 /nfs/rootfs/new/.nfs-ready 已就绪
#       —— 否则 boot.scr 会自己回退到 mmcboot（见 scripts/boot.cmd）。
#
set -euo pipefail

NEW=/home/zhb/linux-projects/emmc
SCR=$NEW/scripts/boot.scr
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=6 -o LogLevel=ERROR"

[ -f "$SCR" ] || { echo "❌ 找不到 $SCR"; exit 1; }

echo "== 板子可达性 =="
ping -c1 -W2 "$BOARD" >/dev/null || { echo "❌ ping 不通 $BOARD"; exit 1; }
echo "  ✅ 通"

echo "== 推 boot.scr 到板子 =="
cat "$SCR" | timeout 30 $SSH root@$BOARD 'cat > /tmp/boot.scr && ls -l /tmp/boot.scr'

if [ "${1:-}" = "--remove" ]; then
	echo "== 摘掉 p1 里的 boot.scr（恢复 eMMC 启动）=="
	timeout 30 $SSH root@$BOARD '
		export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
		mkdir -p /mnt/p1
		mount /dev/mmcblk1p1 /mnt/p1 2>/dev/null || { echo "挂载失败"; exit 1; }
		ls -l /mnt/p1/boot.scr 2>/dev/null && mv /mnt/p1/boot.scr /mnt/p1/boot.scr.off
		sync; umount /mnt/p1
		echo "已摘除"'
	exit 0
fi

echo "== 挂 p1 并放入 boot.scr =="
timeout 60 $SSH root@$BOARD '
	export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
	mkdir -p /mnt/p1

	# ★ 踩过的坑：老系统 /dev 里的分区节点是【静态】的，而且设备号写错了
	#   实测 /dev/mmcblk1p1 是 179,9（正确应为 179,1；p2 是 179,10 而非 179,2），
	#   于是 mount 报 "not a valid block device"。
	#   做法：以内核 /sys/class/block/.../dev 为准，重建节点。
	for part in mmcblk1p1 mmcblk1p2; do
		[ -e /sys/class/block/$part/dev ] || continue
		want=$(cat /sys/class/block/$part/dev)          # 形如 179:1
		have=$(stat -c "%t:%T" /dev/$part 2>/dev/null)  # 十六进制
		want_hex=$(printf "%x:%x" ${want%:*} ${want#*:})
		if [ "$have" != "$want_hex" ]; then
			echo "  修正节点 /dev/$part：$have → $want_hex"
			rm -f /dev/$part
			mknod /dev/$part b ${want%:*} ${want#*:}
		fi
	done

	mount /dev/mmcblk1p1 /mnt/p1 || { echo "❌ 挂载 /dev/mmcblk1p1 失败"; exit 1; }
	echo "--- p1 原有内容（工厂内核/dtb，不动它们）---"; ls -l /mnt/p1 | head -12
	echo "--- 放入 boot.scr ---"
	cp /tmp/boot.scr /mnt/p1/boot.scr
	sync
	ls -l /mnt/p1/boot.scr
	echo "--- 校验 md5（两边应一致）---"
	md5sum /mnt/p1/boot.scr /tmp/boot.scr
	umount /mnt/p1 && echo "已卸载"'

echo
echo "✅ boot.scr 已就位。重启板子即走 TFTP + NFS 新流程："
echo "   reboot 后：TFTP 载 new-zImage → NFS 根 /nfs/rootfs/new"
echo "   回退命令：bash emmc/scripts/install-bootscr.sh --remove"
