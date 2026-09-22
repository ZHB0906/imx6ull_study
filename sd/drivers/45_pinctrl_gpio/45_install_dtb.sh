#!/bin/sh
# ============================================================
#  第 45 章　把新 dtb 写进 SD 卡的 FAT 分区 p1（🐧 在开发板 Linux 上运行）
#
#  为什么需要这个脚本：
#    U-Boot 的网络发不出去包（根因见第45章文档"八"：dram_init_banksize 缺失
#    → 整个内存被映射成 Strongly-ordered → net_set_ip_header 的非对齐写
#    触发 data abort），所以 TFTP/NFS 在 U-Boot 里都不可用。
#    能用的只有【板子 Linux】的网络：走 NFS 取文件，再写进 p1，
#    复位后 U-Boot 的 mmcboot 照旧 fatload 读 p1 —— 迭代照样很快。
#
#  用法（板子 Linux，SD 卡启动模式）：
#    ip link set eth0 up
#    ip addr add 192.168.10.2/24 dev eth0
#    mount -t nfs -o nolock,vers=3 192.168.10.1:/nfs/rootfs /mnt/nfs
#    sh /mnt/nfs/root/45_install_dtb.sh
# ============================================================

NFS_MNT=/mnt/nfs
MMC_MNT=/mnt/mmc
DTB=imx6ull-14x14-emmc-7-1024x600-c.dtb
SRC=$NFS_MNT/root/$DTB
DST=$MMC_MNT/$DTB
EXPECT=40916          # 第45章版（第44章版是 40574）

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; }
step() { echo; echo "=== $1 ==="; }

step "① 检查 NFS 上的源文件"
if [ ! -f "$SRC" ]; then
	bad "NFS 上没有 $DTB"
	echo "     → 虚拟机上先跑： cd ~/linux-projects && ./build_dtb.sh"
	echo "     → 再把 dtb 拷进 NFS： cp .../dts/$DTB /nfs/rootfs/root/"
	exit 1
fi
SZ=$(wc -c < $SRC)
echo "  源文件: $SRC  ($SZ 字节)"
if [ "$SZ" != "$EXPECT" ]; then
	bad "大小 $SZ ≠ 期望 $EXPECT —— 你写的不是第45章那一版，停手"
	exit 1
fi
ok "是第45章版（$EXPECT 字节）"

step "② 挂载 SD 卡 FAT 分区 p1"
mkdir -p $MMC_MNT
if mount | grep -q " $MMC_MNT "; then
	ok "$MMC_MNT 已挂载"
else
	mount -t vfat /dev/mmcblk0p1 $MMC_MNT || {
		bad "挂 vfat 失败：板子内核里可能没有 vfat（本内核 CONFIG_VFAT_FS=y，应该有的）"
		exit 1
	}
	ok "挂载成功"
fi
if [ -f "$DST" ]; then
	echo "  p1 上旧文件: $(wc -c < $DST) 字节  ← 写之前先记一下，方便反悔"
else
	echo "  p1 上原来没有这个文件（U-Boot 用的 ${DTB} 还是从别处来的，注意核对）"
fi

step "③ 覆盖写入 + 立即校验"
cp $SRC $DST || { bad "cp 失败（p1 空间不够？）"; exit 1; }
sync
A=$(wc -c < $SRC)
B=$(wc -c < $DST)
if [ "$A" = "$B" ]; then
	ok "写入后大小一致：$B 字节"
else
	bad "写入后大小不一致（$A → $B）"
	exit 1
fi

step "④ 卸载"
umount $MMC_MNT && ok "已卸载 $MMC_MNT（缓冲已 sync，可以安全复位）"

step "⑤ 安装开机自动配网钩子（含 sync，见踩坑 #10）"
if [ -f $NFS_MNT/root/45_install_hook.sh ]; then
	sh $NFS_MNT/root/45_install_hook.sh
else
	echo "  ！NFS 上没有 45_install_hook.sh，跳过钩子安装（不影响 dtb）"
fi

# 【踩坑 #10】ext4 延迟分配：往板子 rootfs 写的东西要 sync 过才会真正落到 SD 卡。
# 少了这一步，复位后会看到 /etc/nfs-net.sh 存在但 0 字节、rcS 里追加的行凭空消失。
sync

echo
echo "============================================================"
echo " 完成。复位板子，U-Boot 的 mmcboot 会 fatload 这份新 dtb。"
echo " 复位后只要一条命令（网络会自动配好、NFS 会自动挂好）："
echo "     sh /mnt/nfs/root/45_go.sh"
echo "============================================================"
