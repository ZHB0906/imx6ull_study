#!/bin/bash
# ============================================================================
# publish.sh —— OTA 服务端：把一个 rootfs 镜像打包成"可发布"的 OTA 目录
#
# 用法：
#   bash emmc/ota/server/publish.sh <镜像文件或rootfs目录> <版本号> [输出目录]
# 例：
#   bash emmc/ota/server/publish.sh /slots/rootfs-test.img 20260922-1
#   bash emmc/ota/server/publish.sh /nfs/rootfs/new 20260922-2 /srv/ota
#
# 产物（放进 OTA 根目录，客户端会按固定名字去找 ✓）：
#   rootfs-<版本>.ext4.gz      镜像（gzip ✓ 22MB 量级 ✓）
#   update.manifest            清单（行式 key=value ✓ 板子上没有 JSON 解析器 ✗）
#   update.manifest.sig        清单签名（真实性 ✓）
#   update.manifest.txt        清单明文副本（人看的 ✓）
# ============================================================================
set -euo pipefail
SRC="${1:?用法: publish.sh <镜像或目录> <版本号> [输出目录]}"
VER="${2:?缺版本号（建议 YYYYMMDD-N ✓ 保证单调递增 ✓）}"
OUT="${3:-/home/zhb/otatest/ota}"
KEY="${OTA_KEY:-/home/zhb/otatest/ota-signing.key}"
MINVER="${OTA_MIN_VERSION:-}"

mkdir -p "$OUT"
FILE="rootfs-$VER.ext4.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== ① 准备镜像 ==="
if [ -d "$SRC" ]; then
	echo "  从目录生成 ext4 镜像: $SRC"
	SZ_MB=$(( $(du -sm "$SRC" | cut -f1) + 40 ))
	IMG="$TMP/rootfs.ext4"
	dd if=/dev/zero of="$IMG" bs=1M count="$SZ_MB" status=none
	mkfs.ext4 -q -F -L atkrootfs "$IMG"
	mkdir -p "$TMP/mnt"
	sudo -n mount -o loop "$IMG" "$TMP/mnt" 2>/dev/null || mount -o loop "$IMG" "$TMP/mnt"
	( cd "$SRC" && tar cf - . ) | ( cd "$TMP/mnt" && tar xf - )
	umount "$TMP/mnt"
else
	IMG="$SRC"
	echo "  用现成镜像: $IMG ($(du -h "$IMG" | cut -f1))"
fi

echo "=== ② 压缩（这一份就是要传给板子的 ✓）==="
gzip -9 -c "$IMG" > "$OUT/$FILE"
SIZE=$(stat -c %s "$OUT/$FILE")
SUM=$(sha256sum "$OUT/$FILE" | cut -d' ' -f1)
echo "  $FILE  $SIZE 字节（$(echo "scale=1; $SIZE/1048576" | bc) MB）"
echo "  sha256 = $SUM"

echo "=== ③ 生成清单 ==="
{
	echo "version=$VER"
	echo "file=$FILE"
	echo "size=$SIZE"
	echo "sha256=$SUM"
	[ -n "$MINVER" ] && echo "min_version=$MINVER"
} > "$TMP/update.manifest"
# ★ 清单本体必须出现在发布目录 ✗（第一版漏了它 → 板子 404 ✓ 实测踩过 ✓）
cp "$TMP/update.manifest" "$OUT/update.manifest"
cp "$TMP/update.manifest" "$OUT/update.manifest.txt"

echo "=== ④ 签名（清单的真实性 ✓ 板子没 TLS ✗ 全靠它 ✓）==="
if [ ! -f "$KEY" ]; then
	echo "  首次运行：生成签名密钥 $KEY"
	openssl genpkey -algorithm ED25519 -out "$KEY"
	openssl pkey -in "$KEY" -pubout -out "${KEY%.key}.pub.pem"
	echo "  ★ 公钥已生成：${KEY%.key}.pub.pem → 要放到板子 /etc/ota-pub.pem ✓"
fi
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$TMP/update.manifest" -out "$OUT/update.manifest.sig"
echo "  签名: $(wc -c < "$OUT/update.manifest.sig") 字节"

echo
echo "=== ⑤ 发布完成 ==="
ls -lh "$OUT" | sed 's/^/  /'
echo
echo "  板上用法："
echo "    1) 把公钥放到板子:  cat ${KEY%.key}.pub.pem | ssh root@192.168.10.2 'cat > /etc/ota-pub.pem'"
echo "    2) 起 HTTP 服务:    cd $(dirname $OUT) && python3 -m http.server 8899"
echo "    3) 板子上检查:      ota-client.sh check"
