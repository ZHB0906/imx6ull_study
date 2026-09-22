#!/bin/sh
#
# br2-setup.sh —— 生成 emmc/ 工程的 Buildroot .config（可重复执行）
#
#     sh emmc/scripts/br2-setup.sh
#
# 做三件事：
#   ① 拿 imx6ulevk_defconfig 当基线（cortex-A7 + NEON/VFPv4，最接近 IMX6ULL）
#   ② merge 我们的增量 br2-external/atk_imx6ull.fragment
#   ③ olddefconfig 解析依赖，然后跑判据
#
# 判据（这几条不对就别开编）：
#   BR2_TOOLCHAIN_HEADERS_AT_LEAST="4.1"   ← 错成 4.20 会导致 glibc 在 4.1.15 上跑不起来
#   BR2_ROOTFS_POST_IMAGE_SCRIPT=""        ← 不为空会在出镜像时跑 SD 卡脚本直接失败
#   没有 BR2_LINUX_KERNEL / BR2_TARGET_UBOOT  ← 做法 B：Buildroot 只管 rootfs
#
set -e

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
FRAG=$NEW/br2-external/atk_imx6ull.fragment
export BR2_EXTERNAL=$NEW/br2-external

cd "$BR"

# Bootstrap：output/.br-external.mk 是 buildroot 自己在解析时生成的，
# 全新 output 目录下的第一次 make 会因为"生成时序"报
#   No rule to make target 'output/.br-external.mk'
# 所以先手工跑一次它内部用的那条生成命令。
mkdir -p output
if [ ! -f output/.br-external.mk ]; then
	echo "== bootstrap output/.br-external.mk =="
	support/scripts/br2-external -m -o output/.br-external.mk "$BR2_EXTERNAL"
fi

echo "== ① 基线 defconfig =="
make imx6ulevk_defconfig

echo "== ② merge 增量 =="
support/kconfig/merge_config.sh -m .config "$FRAG"

echo "== ③ olddefconfig =="
make olddefconfig

echo
echo "== 判据 =="
fail=0
chk() { # chk 描述 期望 实际
	if [ "$2" = "$3" ]; then
		printf '  ✅ %-38s %s\n' "$1" "$3"
	else
		printf '  ❌ %-38s 期望 %s，实际 %s\n' "$1" "$2" "$3"
		fail=1
	fi
}

chk "内核头 AT_LEAST" "4.1" \
	"$(sed -n 's/^BR2_TOOLCHAIN_HEADERS_AT_LEAST="\(.*\)"$/\1/p' .config)"
chk "内核头版本号" "4.1.15" \
	"$(sed -n 's/^BR2_DEFAULT_KERNEL_VERSION="\(.*\)"$/\1/p' .config)"
chk "post-image 脚本（须空）" "" \
	"$(sed -n 's/^BR2_ROOTFS_POST_IMAGE_SCRIPT="\(.*\)"$/\1/p' .config)"
chk "gcc 7.x" "y" \
	"$(sed -n 's/^BR2_GCC_VERSION_7_X=\(.*\)$/\1/p' .config)"
chk "C++ 支持" "y" \
	"$(sed -n 's/^BR2_TOOLCHAIN_BUILDROOT_CXX=\(.*\)$/\1/p' .config)"
chk "glibc" "y" \
	"$(sed -n 's/^BR2_TOOLCHAIN_BUILDROOT_GLIBC=\(.*\)$/\1/p' .config)"
chk "wpa_supplicant" "y" \
	"$(sed -n 's/^BR2_PACKAGE_WPA_SUPPLICANT=\(.*\)$/\1/p' .config)"
chk "tslib" "y" "$(sed -n 's/^BR2_PACKAGE_TSLIB=\(.*\)$/\1/p' .config)"
chk "dropbear" "y" "$(sed -n 's/^BR2_PACKAGE_DROPBEAR=\(.*\)$/\1/p' .config)"

if grep -qE '^BR2_LINUX_KERNEL=y|^BR2_TARGET_UBOOT=y' .config; then
	echo "  ❌ 内核 / U-Boot 没关掉（做法 B 要求都不勾）"
	fail=1
else
	echo "  ✅ 内核 / U-Boot 都没勾（做法 B）"
fi

if grep -qE '^BR2_ROOTFS_OVERLAY=.*rootfs-overlay|^BR2_ROOTFS_POST_BUILD_SCRIPT=.*post-build' .config; then
	echo "  ✅ overlay + post-build 已挂上"
else
	echo "  ❌ overlay / post-build 没挂上"
	fail=1
fi

[ "$fail" = 0 ] && echo && echo "配置 OK，可以开始编： sh emmc/scripts/br2-build.sh" || {
	echo
	echo "配置有问题，先别编。"
	exit 1
}
