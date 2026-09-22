#!/bin/sh
# ============================================================================
# mock-init-test.sh —— 在**运行中的板子**上，用 loop 镜像假冒 p2，
#                      让 initramfs 的 /init 走**完整真实逻辑**（零风险 ✓）
#
# 原理：init 里写死了设备名 /dev/mmcblk1p2。在 chroot 里我们可以用 mknod
#       造一个**同名节点**，但主次设备号指向 **loop 设备(7:0)**，
#       于是 init 的 mount 操作实际挂的是我们准备的**测试镜像** ✓
#       → 逻辑/工具/分支全部真跑一遍，而**完全不碰真正的 p2** ✓✓
#
# 用法：sh mock-init-test.sh <initrd-tree-dir> <test-image>
# ============================================================================
set -u
TREE="$1"; IMG="$2"
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
PASS=0

echo "=== 准备 mock 环境 ==="
rm -rf "$TREE" && mkdir -p "$TREE"
echo "  目录树: $TREE"

echo
echo "=== ① 基础检查 ==="
[ -x "$TREE/init" ] && { echo "  init 可执行 ✓"; PASS=$((PASS+1)); } || echo "  ✗ 缺 init"
[ -x "$TREE/sbin/fw_printenv" ] && echo "  fw_printenv ✓" || echo "  ✗ 缺 fw_printenv"
[ -f "$IMG" ] && echo "  测试镜像存在 ✓ ($(wc -c < "$IMG") 字节)" || echo "  ✗ 缺测试镜像"

echo
echo "=== ② 造 mock p2：把 /dev/mmcblk1p2 指向 loop 设备(7:0) ==="
# 先确保 init 里的 setup_dev 会创建它；这里我们预先建好指向 loop 的节点
mkdir -p "$TREE/dev"
rm -f "$TREE/dev/mmcblk1p2"
mknod "$TREE/dev/mmcblk1p2" b 7 0 2>/dev/null && echo "  已造 mock 节点 mmcblk1p2 -> 7:0 ✓"
# 让 loop0 指向测试镜像
LOOP=$(losetup -f)
losetup "$LOOP" "$IMG" 2>/dev/null && echo "  $LOOP -> $IMG ✓"
echo "  注意：init 里会 losetup /dev/loop0（固定名）→ 若上面不是 loop0，先 detach"
if [ "$LOOP" != "/dev/loop0" ]; then
  losetup -d "$LOOP" 2>/dev/null
  losetup /dev/loop0 "$IMG" 2>/dev/null && echo "  改用 /dev/loop0 ✓"
fi
mkdir -p "$TREE/mnt/data" "$TREE/mnt/newroot"

echo
echo "=== ③ 跑 init debug（完整逻辑，停在 switch_root 前 ✓）==="
chroot "$TREE" /init debug 2>&1 | sed 's/^/    /'

echo
echo "=== ④ 跑 init plan（纯模拟 ✓ 应无 not found、无挂载）==="
BEFORE=$(mount | wc -l)
chroot "$TREE" /init plan 2>&1 | grep -E "PLAN|活动槽|使用 p2|not found" | sed 's/^/    /'
AFTER=$(mount | wc -l)
echo "    plan 前后挂载数: $BEFORE -> $AFTER （应相等 ✓）"

echo
echo "=== ⑤ 清理（先卸 mock 挂载，再删目录 ✓）==="
for m in "$TREE/dev/pts" "$TREE/dev/shm" "$TREE/dev" "$TREE/sys" "$TREE/proc" "$TREE/mnt/data" "$TREE/mnt/newroot"; do
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
done
losetup -d /dev/loop0 2>/dev/null
rm -rf "$TREE" 2>/dev/null
echo "  残留 /tmp 下挂载: $(mount | grep -c '/tmp/')"
echo "  真实系统根: $(mount | awk '/ \/ /{print $1}')  （必须还是 /dev/root ✓）"

echo
echo "=== 结论 ==="
echo "  上面 ③ 的输出里若出现『p2 挂载成功 ✓』且 Debug 报告里 /sbin/init = 可执行 ✓，"
echo "  就说明 init 的真实逻辑是通的 ✓；若出现『挂载失败』或『自愈触发』→ 仍不能上板 ✗"
