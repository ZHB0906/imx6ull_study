#!/bin/bash
# ============================================================
#  第 46 章　编译 5 个锁变体 + 测试程序，部署到 NFS（🖥️ 虚拟机）
#
#  用法：
#      ./build_all.sh              # 编 KIND=0..4 + racetest，全部拷进 /nfs/rootfs/root
#      ./build_all.sh --no-deploy  # 只编译，不拷贝
# ============================================================
set -e

DRV_DIR=/home/zhb/linux-projects/drivers/46_concurrency
NFS_ROOT=/nfs/rootfs/root
TOOLCHAIN=/home/zhb/linux-projects/toolchain/gcc9/bin
DEPLOY=1
[ "$1" = "--no-deploy" ] && DEPLOY=0

export PATH=$TOOLCHAIN:$PATH
cd "$DRV_DIR"

echo "========================================"
echo " 第 46 章　编译 5 个变体"
echo "========================================"

for k in 0 1 2 3 4; do
	echo
	echo "=== KIND=$k ==="
	make clean >/dev/null 2>&1 || true
	make KIND=$k 2>&1 | grep -E "error|warning: implicit|beep_lock.ko" | head -5 || true
	if [ ! -f beep_lock.ko ]; then
		echo "   ❌ KIND=$k 编译失败"
		exit 1
	fi

	# 质检：PIC 符号必须没有（第44章的坑）
	if strings beep_lock.ko | grep -q '_GLOBAL_OFFSET_TABLE_'; then
		echo "   ❌ KIND=$k 还有 PIC 符号，检查 Makefile"
		exit 1
	fi
	SZ=$(stat -c %s beep_lock.ko)
	echo "   ✅ beep_lock.ko = $SZ 字节，无 PIC 符号"

	if [ "$DEPLOY" = 1 ]; then
		cp beep_lock.ko "$NFS_ROOT/beep_lock$k.ko"
		chmod 644 "$NFS_ROOT/beep_lock$k.ko"
	fi
done

echo
echo "=== 编译用户态测试程序 ==="
arm-linux-gnueabihf-gcc raceApp.c -o racetest
echo "   ✅ racetest 编译完成"

if [ "$DEPLOY" = 1 ]; then
	cp racetest 46_race.sh "$NFS_ROOT/"
	chmod 755 "$NFS_ROOT/racetest" "$NFS_ROOT/46_race.sh"
	echo
	echo "=== 已部署到 $NFS_ROOT ==="
	ls -l "$NFS_ROOT"/beep_lock*.ko "$NFS_ROOT"/racetest "$NFS_ROOT"/46_race.sh
fi

echo
echo "板子上跑： sh /mnt/nfs/root/46_race.sh"
