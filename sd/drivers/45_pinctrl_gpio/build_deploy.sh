#!/bin/bash
# ============================================================
#  第 45 章　蜂鸣器驱动快速迭代脚本（🖥️ 在虚拟机上运行）
#
#  用法：
#     ./build_deploy.sh          # 编译 + 质检 + 部署到 NFS
#
#  它【不管设备树】。设备树用 ~/linux-projects/build_dtb.sh。
#  两者分工：
#     build_dtb.sh      → dtb 编译 + 质检 + 拷进 /tftpboot（U-Boot 取）
#     build_deploy.sh   → beep.ko + beepTest 编译 + 质检 + 拷进 NFS /root
#
#  做完之后，板子上一条命令：
#     sh /mnt/nfs/root/45_beep.sh
# ============================================================
set -e

DRV_DIR=/home/zhb/linux-projects/drivers/45_pinctrl_gpio
NFS_ROOT=/nfs/rootfs/root
TOOLCHAIN=/home/zhb/linux-projects/toolchain/gcc9/bin

export PATH=$TOOLCHAIN:$PATH

echo "========================================"
echo " 第 45 章　编译 + 部署（蜂鸣器）"
echo "========================================"

cd "$DRV_DIR"

echo
echo "=== ① 编译内核模块 ==="
make clean >/dev/null 2>&1 || true
make 2>&1 | tail -3

echo
echo "=== ② 编译用户态测试程序 ==="
arm-linux-gnueabihf-gcc beepApp.c -o beepTest
echo "   beepTest 编译完成"

echo
echo "=== ③ 模块质检（第 44 章踩过的 PIC 坑，这里必须自动拦住）==="
SZ=$(stat -c %s beep.ko)
echo "   大小: $SZ 字节   ← 以后指认版本就用它"
if strings beep.ko | grep -q '_GLOBAL_OFFSET_TABLE_'; then
	echo "   ❌ 还有 PIC 符号！检查 Makefile 里的 -fno-pic -fno-PIE"
	exit 1
fi
if arm-linux-gnueabihf-readelf -rW beep.ko | grep -qE 'GOT_BREL|BASE_PREL'; then
	echo "   ❌ 还有 PIC 重定位！"
	exit 1
fi
echo "   ✅ 无 PIC 符号/重定位（不会出现 Unknown symbol _GLOBAL_OFFSET_TABLE_）"
echo "   ✅ vermagic: $(strings beep.ko | grep -m1 -o 'vermagic=.*')"

echo
echo "=== ④ 部署到 NFS（板子直接可见，不需要 mount）==="
cp -v beep.ko beepTest 45_beep.sh "$NFS_ROOT/"
# 【踩坑 #9】必须显式 755，不能只写 chmod +x：
#   源文件权限若是 600/711，cp 会把 711 带过去，板子上可能执行不了
chmod 755 "$NFS_ROOT/beepTest" "$NFS_ROOT/45_beep.sh"
chmod 644 "$NFS_ROOT/beep.ko"

echo
echo "========================================"
echo " 完成。板子上执行："
echo "     sh /mnt/nfs/root/45_beep.sh"
echo
echo " ⚠️ 前提：设备树已经 ./build_dtb.sh 部署过，"
echo "    且板上 dtb 里有 /mybeep 节点，否则 insmod 会报 mybeep node not find!"
echo "========================================"
