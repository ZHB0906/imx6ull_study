#!/bin/sh
# ============================================================================
# build-image-on-board.sh —— 在板子上以 root 把当前运行槽的 rootfs 打成 ext4 镜像
#
# 为什么要在板子上做（而不是虚拟机上）：
#   tar 以非 root 用户拉取/写回时**会丢掉属主**（全变成 uid=1000）✗
#   → dropbear 会以 "Bad permissions / non-root owner" 拒绝 host key ✗
#   → 我们就丢掉 SSH 这条验证通道 ✗
#   在板子上以 root 做，属主/权限位 100% 保真 ✓
#
# 用法（在板子上跑）：
#   sh build-image-on-board.sh /slots/build-rootfs-b.ext4 [镜像大小MB]
#
# 注意：
#   * 镜像文件必须放在**会被 tar 排除**的位置（/slots ✓），否则自我递归 ✗
#   * /mnt 也在排除列表里 → 挂载点 /mnt/imgbuild 不会递归进去 ✓
# ============================================================================
set -e
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

IMG="${1:-/slots/build-rootfs-b.ext4}"
SZ_MB="${2:-300}"
# ★ 版本号：写进**镜像内部**的 /etc/atk-version ✓（第 3 个参数 ✓ 可省略 ✓）
#   为什么必须写进镜像、而不是依赖 /slots/ota-version ✗：
#     /slots/ota-version 两个槽共用 ✗ → 回滚后屏幕会报"a 槽是新版本"的假信息 ✗
#   为什么**不能**写进运行中的根 ✗：
#     一旦写进去，本槽自己也就变成"新版本"了 ✗ → 客户端会认为"已是最新"而不再升级 ✗
#     → 所以只在第 ⑥ 步挂载镜像时写 ✓ 运行中的根一个字节都不动 ✓✓
VER="${3:-}"
MNT=/mnt/imgbuild

echo "=== ① 准备镜像文件 ==="
echo "  镜像: $IMG  ($SZ_MB MB)"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count="$SZ_MB" status=none
mkfs.ext4 -q -F -L atkrootfs "$IMG"
echo "  mkfs.ext4 ✓"

echo "=== ② 挂载 ==="
mkdir -p "$MNT"
mount -o loop "$IMG" "$MNT"
echo "  已挂载到 $MNT ✓"

echo "=== ③ 拷贝 rootfs（排除运行时目录 / NFS 时代残留 / 镜像自身）==="
#   ./slots   → ★ 既有状态区，也是本镜像文件所在处（排除防自我递归 ✓）
#   ./mnt     → 含挂载点 $MNT 本身（排除防递归 ✓）
#   ./nfs ./.nfs-ready ./boot-info.txt → NFS 开发模式时代的残留 ✓ 不该进镜像 ✓
cd /
tar cf - \
	--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./tmp \
	--exclude=./run --exclude=./mnt --exclude=./media --exclude=./slots \
	--exclude=./lost+found --exclude=./var/log --exclude=./var/lock \
	--exclude=./var/run --exclude=./var/tmp --exclude=./var/cache \
	--exclude=./nfs --exclude=./.nfs-ready --exclude=./boot-info.txt \
	. | ( cd "$MNT" && tar xf - )
echo "  拷贝完成 ✓"

echo "=== ④ 补齐空目录（★ /slots 是 b 槽的挂载点，必须存在）==="
for d in slots proc sys dev tmp run mnt media var/log var/lock var/run var/tmp; do
	mkdir -p "$MNT/$d"
done
echo "  ✓"

echo "=== ⑤ 卸载 ==="
sync
umount "$MNT"
echo "  ✓"

echo "=== ⑥ 结果 ==="
echo "  镜像大小 : $(du -m "$IMG" | cut -f1) MB"
echo "  实际占用 : $(du -sm "$MNT" 2>/dev/null | cut -f1 || echo -) "
echo "  关键文件自检（在镜像里）:"
mkdir -p "$MNT"
mount -o loop,rw "$IMG" "$MNT"
if [ -n "$VER" ]; then
	echo "$VER" > "$MNT/etc/atk-version"
	sync
	echo "  已写入镜像内版本号: /etc/atk-version = $VER ✓"
fi
for f in etc/ota.conf usr/bin/ota-client.sh etc/init.d/S99otaconfirm sbin/init \
         etc/ota-pub.pem opt/launcher/launcher slots; do
	if [ -e "$MNT/$f" ]; then
		printf "    ✓ %-30s %s\n" "$f" "$(ls -ld "$MNT/$f" | awk '{print $1, $3":"$4}')"
	else
		printf "    ✗ %-30s 缺失 ✗\n" "$f"
	fi
done
echo "  公钥大小: $(wc -c < "$MNT/etc/ota-pub.pem") 字节"
umount "$MNT"
echo
echo "=== ✓ 镜像构建完成: $IMG ==="
