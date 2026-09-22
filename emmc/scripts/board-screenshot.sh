#!/bin/bash
#
# board-screenshot.sh —— 远程抓板子屏幕（/dev/fb0）存成 PNG
#
#   bash emmc/scripts/board-screenshot.sh [输出路径]
#   默认输出: emmc/out/screenshot-<时间戳>.png
#
# 原理：
#   板子 fb0 = 1024x600, 16bpp, stride 2048（正好 1024*2，无填充）
#   → ssh 直接把 /dev/fb0 前 600 行读出来（dd bs=2048 count=600 = 1,228,800 字节）
#   → 虚拟机侧用 PIL 按 RGB565 解释并转 PNG
# 注意：这是"物理像素快照"，UI 是否刷新、颜色是否正确、画面有没有花屏，
#       都能直接看出来；但不能代替触摸交互（板子内核没编 uinput，无法远程注入触摸）。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BOARD=192.168.10.2
W=1024
H=600
OUT="${1:-$NEW/out/screenshot-$(date +%H%M%S).png}"

SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

mkdir -p "$(dirname "$OUT")"

echo "=== 抓取板子屏幕 -> $OUT ==="
timeout 60 $SSH root@$BOARD "dd if=/dev/fb0 bs=$((W*2)) count=$H 2>/dev/null" > "$OUT.rgb565" || {
	echo "❌ 抓取失败（板子不可达？）"; rm -f "$OUT.rgb565"; exit 1
}

sz=$(wc -c < "$OUT.rgb565")
need=$((W*H*2))
echo "  收到字节: $sz (需要 $need)"
if [ "$sz" -ne "$need" ]; then
	echo "❌ 字节数不对，可能 fb 参数变了（检查 /sys/class/graphics/fb0/{virtual_size,bits_per_pixel,stride}）"
	exit 1
fi

python3 - "$OUT.rgb565" "$OUT" "$W" "$H" <<'PY'
import sys
from PIL import Image
raw, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
data = open(raw, 'rb').read()
# fb 是 RGB565 小端 → PIL 的 "BGR;16" 原始模式正好对应
img = Image.frombytes("RGB", (w, h), data, "raw", "BGR;16")
img.save(out)
# 顺便统计是否全黑/单色（判断是不是没画东西）
colors = img.getcolors(maxcolors=1 << 20) or []
colors.sort(reverse=True)
top = colors[:5]
print("  颜色数: %d，占比最高的几种: %s" % (
    len(colors), ", ".join("%s(%.1f%%)" % (c[1], 100.0*c[0]/(w*h)) for c in top)))
PY
rm -f "$OUT.rgb565"
ls -lh "$OUT" | awk '{print "  ✅ 已保存: "$9" ("$5")"}'
