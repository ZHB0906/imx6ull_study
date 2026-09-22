#!/bin/sh
#
# post-build.sh —— Buildroot 打完 rootfs 后、打包前跑
#
# 干两件事：
#   ① 把手动编出来的 8189fs.ko 放进 /lib/modules/$(kernelrelease)/
#      （做法 B：内核不由 Buildroot 编，所以模块得自己拷）
#   ② 修 overlay 里几个必须严格权限的文件（.ssh 600/700、脚本 755）
#
set -e

TARGET_DIR="$1"
NEW=/home/zhb/linux-projects/emmc
KES=$NEW/linux/IMX6ULL/linux-imx

KREL=$(cat "$KES/include/config/kernel.release")
KO="$KES/drivers/net/wireless/realtek/rtl8189FS/8189fs.ko"

echo "[post-build] kernelrelease = $KREL"

# ---------- ① 模块 ----------
if [ -f "$KO" ]; then
	DEST="$TARGET_DIR/lib/modules/$KREL"
	mkdir -p "$DEST"
	cp -f "$KO" "$DEST/"
	cp -f "$KES/modules.builtin" "$DEST/" 2>/dev/null || true

	# modules.dep：宿主 depmod 对 ARM 模块同样有效；没有就算了（S45wifi 会退回 insmod）
	if command -v depmod >/dev/null 2>&1; then
		depmod -b "$TARGET_DIR" "$KREL" && echo "[post-build] depmod 完成" ||
			echo "[post-build] ⚠️ depmod 失败（不影响，S45wifi 用 insmod 兜底）"
	fi

	# 质检：vermagic / 别名 / PIC
	echo "[post-build] 模块质检："
	strings "$KO" | grep -E "^vermagic=" | sed 's/^/[post-build]   /'
	strings "$KO" | grep -c "_GLOBAL_OFFSET_TABLE_" |
		sed 's/^/[post-build]   GOT 重定位条数: /'
else
	echo "[post-build] ❌ 找不到 $KO —— 内核还没编？"
	exit 1
fi

# ---------- ② 权限 ----------
# init 脚本一律 755：★ 曾经因为 overlay 里的脚本是 644 而在开机构建时报
# "Permission denied"（Error 126）。用通配而不是逐个列名，以后再加脚本也不会漏。
for s in "$TARGET_DIR"/etc/init.d/S*; do
	[ -f "$s" ] && chmod 755 "$s"
done
chmod 755 "$TARGET_DIR/root/set-wifi.sh" 2>/dev/null || true
chmod 700 "$TARGET_DIR/root/.ssh" 2>/dev/null || true
chmod 600 "$TARGET_DIR/root/.ssh/authorized_keys" 2>/dev/null || true

echo "[post-build] 完成"
