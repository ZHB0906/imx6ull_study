#!/bin/bash
#
# emmc-solidify.sh —— 把 emmc/ 的 rootfs 固化到 eMMC，使板子脱离虚拟机也能启动
#
#   bash emmc/scripts/emmc-solidify.sh backup    # ① 备份老 rootfs(p2) + p1 里的内核/dtb
#   bash emmc/scripts/emmc-solidify.sh check-backup # 只验证备份并补标记（不碰分区，可放心单跑）
#   bash emmc/scripts/emmc-solidify.sh image     # ② 在板子上用 mke2fs -d 把 NFS 根写成 ext4 到 p2
#   bash emmc/scripts/emmc-solidify.sh kernel    # ③ 把我们的 zImage/dtb 覆盖进 p1 + 写 eMMC 启动 env
#   bash emmc/scripts/emmc-solidify.sh verify    # ④ 关掉虚拟机 TFTP，验证离线启动
#
# ── 为什么不用 Buildroot 自己出镜像（也不修 fakeroot）──────────────
#   Buildroot 2019.02 的 host-fakeroot 1.20.2 在 glibc 2.35 上不可用
#   （补一行能编过但功能静默失效，见 09-18 记录第七节）。
#   而我们**不需要**它：板子本身是 root，NFS 根已经 chown 成 root:root，
#   所以直接在板子上 `mke2fs -t ext4 -d /nfs/rootfs/new /dev/mmcblk1p2`
#   生成的镜像**属主天然正确**，不需要 sudo、不需要 fakeroot。
#
# ── 为什么 p1 里的文件要"覆盖同名"而不是新建名字 ──────────────────
#   U-Boot 2016.03 的 FAT 用 strcmp（大小写敏感）比较文件名，Linux 新建的
#   小写 8.3 名（如 boot.scr）U-Boot 读不到；而工厂那两个文件名带长名条目，
#   U-Boot 读得到。所以**覆盖它们的内容、保留文件名**（cp 覆盖不会重建目录项）。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
KES=$NEW/linux/IMX6ULL/linux-imx
OUT=$NEW/out
BOARD=192.168.10.2
BOARD6=fe80::8a2d:b6ff:fe8d:356d%ens37
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"
DTB=imx6ull-14x14-emmc-7-1024x600-c.dtb
STAMP=$OUT/.emmc-backup-done

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# 老系统的 /dev 是静态节点且设备号写错了（mmcblk1=179:8 其实是 boot0！）
# 所以任何对 eMMC 的操作前都要把节点修正过来。
FIX_NODES='
for d in mmcblk1 mmcblk1p1 mmcblk1p2; do
  want=$(cat /sys/class/block/$d/dev); want_hex=$(printf "%x:%x" ${want%:*} ${want#*:})
  [ "$(stat -c "%t:%T" /dev/$d 2>/dev/null)" = "$want_hex" ] || {
    rm -f /dev/$d; mknod /dev/$d b ${want%:*} ${want#*:}; echo "  修正 /dev/$d → $want"; }
done'

board_reach() {
	ping -c1 -W2 $BOARD >/dev/null 2>&1 && { echo "ssh:$BOARD"; return 0; }
	# ★ 不用 `ssh | grep -q`：本脚本开了 pipefail，ssh 的非零退出码会污染管道状态，
	#   一次瞬时抖动就会被误判成"板子不可达"。先取回输出再判断。
	local out
	out=$(timeout 25 $SSH root@$BOARD6 'echo ok' 2>/dev/null) || true
	case "$out" in *ok*) echo "ssh6:$BOARD6"; return 0 ;; esac
	return 1
}
BRUN() { # 在板子上跑一段脚本（自动挑 IPv4/IPv6 通道）
	local ch host
	ch=$(board_reach) || die "板子不可达（IPv4 和 IPv6 都不通）"
	host=${ch#*:}          # ssh6 那条自带 %ens37
	timeout 300 $SSH root@$host "$@"
}

# ── 安全闸：必须确认"老 rootfs 已备份"才允许覆写 p2 ──────────────────
# 上一轮的备份是用另一套流程手工做的（文件名与 backup 子命令不同），
# 所以这里不只看标记文件，也接受"已验证的已有备份"，避免重复做 412MB 的备份。
ensure_backup() {
	[ -f "$STAMP" ] && return 0
	local f=$OUT/emmc-backup/old-rootfs-p2.tar.gz
	[ -s "$f" ] || die "既没有标记也没有备份 —— 先跑 emmc-solidify.sh backup（这是安全闸，别跳）"
	say "已有备份但缺标记 —— 先验证，再补标记（不重复做 412MB 备份）"
	echo "  ① 校验 gzip 完整性（412MB，需要一会儿）…"
	timeout 900 gzip -t "$f" || die "备份文件损坏！请重新跑 backup"
	echo "     gzip 完整 ✓"
	echo "  ② 统计条目数…"
	local n
	n=$(timeout 900 tar tzf "$f" 2>/dev/null | wc -l)
	echo "     $n 项（2026-09-19 那次记录是 18973 项）"
	[ "$n" -gt 15000 ] || die "备份内容看起来不完整（只有 $n 项），请重跑 backup"
	echo "  ③ 其它回滚资产…"
	for x in old-p1-fat.tar.gz uboot-env-raw-0xC0000.bin; do
		[ -s "$OUT/emmc-backup/$x" ] || die "缺少回滚资产 $x"
		echo "     $x ✓"
	done
	touch "$STAMP"
	echo "  ✅ 验证通过，已补标记 $STAMP"
}

# ─────────────────────────────────────────────────────────────
case "${1:-}" in

backup)
	say "① 备份老 rootfs(p2) 与 p1 里的内核/dtb（可回滚）"
	mkdir -p $OUT/emmc-backup

	say "备份 p1（FAT，128MB → 压缩传回）"
	BRUN "$FIX_NODES
mkdir -p /mnt/p1; mount /dev/mmcblk1p1 /mnt/p1 || exit 1
tar czf - -C /mnt/p1 . | wc -c
umount /mnt/p1" >/dev/null 2>&1 || true
	# 单个文件更实用：把工厂内核/dtb 取回来
	for f in zImage "$DTB"; do
		BRUN "$FIX_NODES
mkdir -p /mnt/p1; mount /dev/mmcblk1p1 /mnt/p1 2>/dev/null
cat '/mnt/p1/$f'; umount /mnt/p1" > $OUT/emmc-backup/p1-$f 2>/dev/null
		[ -s "$OUT/emmc-backup/p1-$f" ] && echo "  ✅ p1/$f → $(stat -c %s $OUT/emmc-backup/p1-$f) 字节" || echo "  ⚠️ p1/$f 取回失败"
	done

	say "备份 p2（老 rootfs，文件级 tar.gz；分区约 7.3GB）"
	if BRUN "$FIX_NODES
mkdir -p /mnt/p2; mount /dev/mmcblk1p2 /mnt/p2 2>/dev/null
tar czf - -C /mnt/p2 . 2>/dev/null
umount /mnt/p2" > $OUT/emmc-backup/old-rootfs-p2.tar.gz; then
		echo "  ✅ 备份大小：$(du -h $OUT/emmc-backup/old-rootfs-p2.tar.gz | cut -f1)"
	else
		die "p2 备份失败"
	fi
	ls -l $OUT/emmc-backup/
	touch $STAMP
	echo "  ✅ 备份完成，标记 $STAMP"
	;;

image)
	say "② 在板子上把 NFS 根写成 ext4 到 eMMC p2"
	ensure_backup
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
command -v mke2fs >/dev/null || { echo "板子上没有 mke2fs（BR2_PACKAGE_E2FSPROGS 没编进去？）"; exit 1; }
echo "  mke2fs 版本：$(mke2fs -V 2>&1 | head -1)"
echo "  确保 NFS 导出已挂载（mke2fs -d 要从这里读源目录）"
mkdir -p /nfs/rootfs
mountpoint -q /nfs/rootfs || mount -t nfs -o nolock,vers=3 192.168.10.1:/nfs/rootfs /nfs/rootfs || { echo "  ❌ NFS 挂载失败（虚拟机 nfsd 在跑吗？导出配置对吗？）"; exit 1; }
mount | grep nfs | sed "s/^/    /"
echo "  确认 NFS 根属主（必须是 root，否则镜像里属主会错）"
ls -ld /nfs/rootfs/emmc/root /nfs/rootfs/emmc/bin /nfs/rootfs/emmc/etc | sed "s/^/    /"
echo "  确认 NFS 根就是 /nfs/rootfs/new"
ls /nfs/rootfs/emmc/bin/busybox >/dev/null && echo "    ✅ busybox 在"
echo "  源目录体积：$(du -sh /nfs/rootfs/new | cut -f1)"
echo "  开始写 p2（这步会覆盖老 rootfs）"
mke2fs -t ext4 -F -L newrootfs -d /nfs/rootfs/new /dev/mmcblk1p2 2>&1 | tail -8
echo "  写完，校验一下"
e2fsck -fn /dev/mmcblk1p2 2>&1 | tail -4'
	;;

kernel)
	say "③ 把我们的 zImage/dtb 覆盖进 p1，并写 eMMC 启动 env"
	ensure_backup
	echo "  上传我们的 zImage/dtb 到板子"
	cat $KES/arch/arm/boot/zImage | BRUN 'cat > /tmp/new-zImage; ls -l /tmp/new-zImage'
	cat $KES/arch/arm/boot/dts/$DTB | BRUN 'cat > /tmp/new.dtb; ls -l /tmp/new.dtb'

	BRUN "$FIX_NODES
mkdir -p /mnt/p1; mount /dev/mmcblk1p1 /mnt/p1 || exit 1
echo '  --- 覆盖前 ---'; ls -l /mnt/p1/zImage /mnt/p1/$DTB
cp -f /tmp/new-zImage /mnt/p1/zImage
cp -f /tmp/new.dtb    /mnt/p1/$DTB
sync
echo '  --- 覆盖后 ---'; ls -l /mnt/p1/zImage /mnt/p1/$DTB
md5sum /mnt/p1/zImage /tmp/new-zImage
umount /mnt/p1 && echo '  已卸载'"

	say "写 U-Boot 环境：默认走 eMMC，TFTP 标记存在时才走 NFS 开发模式"
	BRUN "$FIX_NODES
printf '# device\toffset\tsize\n/dev/mmcblk1\t0xC0000\t0x2000\n' > /etc/fw_env.config
fw_setenv emmcboot 'setenv bootargs console=ttymxc0,115200 root=/dev/mmcblk1p2 rootwait rw ip=192.168.10.2:192.168.10.1:192.168.10.1:255.255.255.0::eth0:off panic=10; fatload mmc 1:1 80800000 zImage; fatload mmc 1:1 83000000 $DTB; bootz 80800000 - 83000000'
fw_setenv bootcmd 'if tftpboot 8FF00000 nfsboot-on; then if tftpboot 80800000 new-zImage; then if tftpboot 83000000 new-$DTB; then setenv bootargs \${bootargs_nfs}; bootz 80800000 - 83000000; fi; fi; fi; run emmcboot'
echo '--- 回读 ---'
fw_printenv emmcboot
fw_printenv bootcmd"
	;;

check-backup)
	# 只做"安全闸"检查（验证/补标记），不碰任何分区 —— 可以放心单独跑
	ensure_backup
	;;

verify)
	say "④ 验证离线启动（先把 TFTP 标记移走 = 板子不会走 NFS）"
	mv -f /tftpboot/nfsboot-on /tftpboot/nfsboot-on.disabled 2>/dev/null
	ls -l /tftpboot/nfsboot* 2>/dev/null
	echo "  现在重启板子（它会走 eMMC 启动）"
	BRUN 'sync; /sbin/reboot' 2>/dev/null || true
	# ★ 必须先等它"下去"：否则会立刻连到重启前那个还活着的系统，把"就绪"误判成 8 秒
	#   （踩过：脚本报"✅ 8s：SSH 就绪"，其实板子还没重启完，随后的判据全部连不上）
	echo "  等板子断开…"
	down=0
	for i in $(seq 1 40); do
		if ! timeout 3 bash -c "echo > /dev/tcp/$BOARD/22" 2>/dev/null; then down=1; echo "  已断开（探测 $i 次）"; break; fi
		sleep 3
	done
	[ "$down" = 1 ] || echo "  ⚠️ 一直没断开 —— 可能重启没生效？继续等它上线"
	echo "  等它重新起来（带 Qt 的系统约需 60~120 秒）…"
	for i in $(seq 1 40); do
		if timeout 3 bash -c "echo > /dev/tcp/$BOARD/22" 2>/dev/null; then
			# 端口通了还要确认 SSH 真能登录（dropbear 起得比端口开放晚）
			if timeout 25 $SSH root@$BOARD 'echo ok' 2>/dev/null | grep -q ok; then
				echo "  ✅ SSH 登录成功（第 $i 轮，约 $((i*8))s）"; break
			fi
		fi
		sleep 8
	done
	echo
	bash $NEW/scripts/verify-m4m5.sh
	echo
	echo "=== 额外判据：根文件系统必须来自 eMMC，而不是 NFS ==="
	timeout 20 $SSH root@$BOARD 'mount | grep " / " ; echo "---"; cat /proc/cmdline' 2>&1 | tail -4
	;;

*)
	sed -n '2,20p' "$0"
	exit 1
	;;
esac
