#!/bin/bash
#
# br2-build.sh —— 全量编译 Buildroot（内部工具链 + 我们勾的包 + rootfs 镜像）
#
#     sh emmc/scripts/br2-build.sh            # 前台（会 tee 到日志）
#     nohup sh emmc/scripts/br2-build.sh &    # 后台
#
# 2 核 / 可用内存约 1.3G，另有 3.8G swap：-j2 是上限，别开大。
# 大头是内部工具链（gcc + glibc + binutils），约 1~3 小时。
#
# 编完的产物：
#   output/images/rootfs.tar       ← 解到 /nfs/rootfs/new 走 NFS 根
#   output/images/rootfs.ext4      ← 256M，以后烧 eMMC/SD
#   output/target/                 ← 未打包的 rootfs 树（方便查文件在不在）
#
set -euo pipefail   # ★ pipefail 必须有：否则 `make | tee` 的退出码是 tee 的，
                    #   构建失败了后台任务却报 exit 0（这个坑踩过一次）

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
LOG=$NEW/out/build-buildroot.log
export BR2_EXTERNAL=$NEW/br2-external

# ★ 宿主没有 `python`（只有 python3），而 Buildroot 的依赖检查
#   （support/dependencies/dependencies.mk → dependencies.sh 里 `which python`）
#   是硬门槛，缺了直接 Error 1。这里放一个 self-owned shim：
#   emmc/toolchain/hostbin/python -> /usr/bin/python3
#   已验证：构建链上真正用 python 的脚本（check-uniq-files 等）都是 py3 兼容的，
#   而 `python -V` 输出的 3.x 在 dependencies.sh 的数值比较里也 >= 2.7。
export PATH=$NEW/toolchain/hostbin:$PATH

cd "$BR"
echo "开始：$(date)"
echo "日志：$LOG"
echo "python -> $(command -v python) ($(python -V 2>&1))"

make -j2 2>&1 | tee "$LOG"

echo "结束：$(date)"
