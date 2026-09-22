#!/bin/sh
# ============================================================
#  第 45 章　"一条命令"入口（🐧 在开发板 Linux 上运行）
#
#  用法：
#      sh /mnt/nfs/root/45_go.sh
#
#  它会自己判断现在是哪一步：
#     · 设备树里还没有 /mybeep  → 说明新 dtb 还没上卡：
#         走 ① 把 40916 的 dtb 写进 SD 卡 p1
#         走 ② 装开机自动配网钩子
#         然后提示你【复位板子】，复位后再执行同一条命令
#     · 已经有 /mybeep          → 说明新 dtb 生效了：
#         走驱动测试 45_beep.sh（insmod → 响 1 秒 → LED 回归）
#
#  所以整个流程你只需要粘贴两次同一条命令（中间复位一次）。
# ============================================================

NFS_MNT=/mnt/nfs
NFS_SRV=192.168.10.1
NFS_EXP=/nfs/rootfs

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; }
step() { echo; echo "=== $1 ==="; }

# ---- 网络 + NFS（第一次跑时还没有钩子，得自己配）----------------
step "⓪ 网络与 NFS"
if ping -c1 -W1 $NFS_SRV >/dev/null 2>&1; then
	ok "能通 $NFS_SRV"
else
	for i in eth0 eth1; do
		[ -e /sys/class/net/$i ] || continue
		ip link set $i up 2>/dev/null
		ip addr add 192.168.10.2/24 dev $i 2>/dev/null
		if ping -c1 -W1 $NFS_SRV >/dev/null 2>&1; then
			ok "$i 已配 192.168.10.2"
			break
		fi
		ip addr del 192.168.10.2/24 dev $i 2>/dev/null
	done
fi
if ! ping -c1 -W1 $NFS_SRV >/dev/null 2>&1; then
	bad "连不上 $NFS_SRV —— 检查网线是否插在 ETH1/ETH2、虚拟机 tftpd/nfs 是否在跑"
	exit 1
fi
mkdir -p $NFS_MNT
if mount | grep -q " $NFS_MNT "; then
	ok "$NFS_MNT 已挂载"
else
	mount -t nfs -o nolock,vers=3 $NFS_SRV:$NFS_EXP $NFS_MNT || {
		bad "NFS 挂载失败"; exit 1; }
	ok "$NFS_MNT 挂载成功"
fi

# ---- 判断走到哪一步了 ------------------------------------------
if [ -e /proc/device-tree/mybeep ]; then
	step "设备树里有 /mybeep → 新 dtb 已生效，进入驱动测试"
	cat /proc/device-tree/mybeep/compatible 2>/dev/null; echo
	echo "  /sys/class/leds/ 内容（应该没有 my-led）："
	ls /sys/class/leds/ 2>/dev/null | sed 's/^/     /'
	echo
	exec sh $NFS_MNT/root/45_beep.sh
else
	step "设备树里没有 /mybeep → 新 dtb 还没上卡，先装它"
	sh $NFS_MNT/root/45_install_dtb.sh || exit 1
	echo
	echo "============================================================"
	echo " ★ 现在【复位板子】（串口终端里按一下复位键，或断电重上）"
	echo "   起来后自动配好网络、挂好 NFS，然后执行同一条命令："
	echo "        sh /mnt/nfs/root/45_go.sh"
	echo "============================================================"
fi
