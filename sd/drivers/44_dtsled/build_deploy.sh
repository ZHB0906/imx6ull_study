#!/bin/bash
# ============================================================
#  第 44 章　驱动开发快速迭代脚本（在虚拟机上运行）
#
#  用法：
#     ./build_deploy.sh              # 编译 + 部署到 NFS
#     ./build_deploy.sh --image      # 上面这些 + 重新生成 SD 卡镜像
#
#  做完之后，板子上只需一条命令：
#     sh /mnt/nfs/root/44_led.sh
# ============================================================
set -e

DRV_DIR=/home/zhb/linux-projects/drivers/44_dtsled
IMG_DIR=/home/zhb/linux-projects/linux/imx6ull-out
NFS_ROOT=/nfs/rootfs/root
SHARED=/mnt/hgfs/shared_folders/imx6ull/10_sdcard_image
TOOLCHAIN=/home/zhb/linux-projects/toolchain/gcc9/bin

export PATH=$TOOLCHAIN:$PATH

echo "========================================"
echo " 第 44 章　编译 + 部署"
echo "========================================"

cd "$DRV_DIR"

echo
echo "=== ① 编译内核模块 ==="
make clean >/dev/null 2>&1 || true
make 2>&1 | tail -3

echo
echo "=== ② 编译用户态测试程序 ==="
arm-linux-gnueabihf-gcc ledApp.c -o ledtest
echo "   ledtest 编译完成"

echo
echo "=== ③ 检查模块质量 ==="
SZ=$(stat -c %s dtsled.ko)
echo "   大小: $SZ 字节"
if strings dtsled.ko | grep -q '_GLOBAL_OFFSET_TABLE_'; then
	echo "   ❌ 还有 PIC 符号！检查 Makefile 里的 -fno-pic -fno-PIE"
	exit 1
fi
if arm-linux-gnueabihf-readelf -rW dtsled.ko | grep -qE 'GOT_BREL|BASE_PREL'; then
	echo "   ❌ 还有 PIC 重定位！"
	exit 1
fi
echo "   ✅ 无 PIC 符号/重定位"
echo "   ✅ vermagic: $(strings dtsled.ko | grep -m1 -o 'vermagic=.*')"

echo
echo "=== ④ 部署到 NFS ==="
cp -v dtsled.ko ledtest "$NFS_ROOT/"
chmod +x "$NFS_ROOT/ledtest"
echo "   板子上执行： sh /mnt/nfs/root/44_led.sh"

if [ "$1" = "--image" ]; then
	echo
	echo "=== ⑤ 重新生成 SD 卡镜像 ==="
	cd "$IMG_DIR"
	rm -rf __pycache__
	python3 -B build_ch44.py 2>&1 | grep -E '✅|❌|sha256' | tail -6
	python3 -B -c "
import gzip, shutil, hashlib, os
with open('sdcard-ch44.img','rb') as fi, gzip.GzipFile('sdcard-ch44.img.gz','wb',compresslevel=1,mtime=0) as fo:
    shutil.copyfileobj(fi, fo, 1024*1024)
print('   gz:', os.path.getsize('sdcard-ch44.img.gz'), '字节')
print('   img sha256:', hashlib.sha256(open('sdcard-ch44.img','rb').read()).hexdigest())
print('   gz  sha256:', hashlib.sha256(open('sdcard-ch44.img.gz','rb').read()).hexdigest())
"
	echo
	echo "=== ⑥ 同步到共享目录 ==="
	cp -f sdcard-ch44.img.gz sdcard-ch44.img "$SHARED/"
	mkdir -p "$SHARED/driver"
	cp -f "$DRV_DIR/dtsled.ko" "$DRV_DIR/ledtest" "$SHARED/driver/"
	cd "$SHARED"
	sha256sum sdcard-ch44.img sdcard-ch44.img.gz driver/dtsled.ko driver/ledtest > SHA256SUMS.txt
	cat SHA256SUMS.txt
fi

echo
echo "========================================"
echo " 完成"
echo "========================================"
