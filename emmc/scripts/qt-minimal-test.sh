#!/bin/bash
#
# qt-minimal-test.sh —— 最小 Qt 验证程序：交叉编译 + 推到板子 + 生成启动器
#
#   bash emmc/scripts/qt-minimal-test.sh
#
# 解决目标里的第②步：在动 SerialTool 之前，先确认
#   「Qt5 的 linuxfb + 触摸 + 字体 + 软件渲染帧率」在这块板子上到底行不行。
#
set -uo pipefail
NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
SRC=$NEW/apps/qttest
WORK=$NEW/apps/build-qttest
QMAKE=$BR/output/host/bin/qmake
# ★ 必须显式指定 Buildroot 生成的交叉 spec（与 package/qt5/qt5.mk 里的 QT5_QMAKE 一致）：
#   不带 -spec 时 qmake 会用宿主默认 spec（linux-g++ → x86-64!），
#   编出来的二进制在板子上根本跑不了，而且 `file` 才会暴露。
QSPEC="devices/linux-buildroot-g++"
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

say "① 交叉编译最小 Qt 程序"
[ -x "$QMAKE" ] || die "找不到 $QMAKE —— Qt5 还没编完？"
rm -rf "$WORK"; mkdir -p "$WORK"; cp -a "$SRC/." "$WORK/"
(cd "$WORK" && "$QMAKE" -spec "$QSPEC" qttest.pro 2>&1 | tail -3 && make -j2 2>&1 | tail -8)
BIN=$WORK/qttest
[ -x "$BIN" ] || die "编译没产出可执行文件"
file "$BIN" | cut -c1-100 | sed 's/^/  /'
# 硬判据：必须是 ARM，不能是 x86-64（防"忘了 -spec"这类错误悄悄过去）
file "$BIN" | grep -q "ARM" || die "编出来的不是 ARM 二进制 —— qmake 的 spec 没生效！"
echo "  ✅ 确认是 ARM 二进制"

say "② 推到板子 /opt/qttest/"
STAGE=$NEW/apps/qttest-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"; cp "$BIN" "$STAGE/qttest"
cat > "$STAGE/run.sh" <<'EOF'
#!/bin/sh
# 最小 Qt 验证：linuxfb + 触摸（输出直接打在这条 SSH/串口的 stdout 上）
cd "$(dirname "$0")" || exit 1
# 内核 printk 会直接写进 /dev/fb0，在 Qt 画面上叠字/花屏 —— 只留 emergency 级别
dmesg -n 1 2>/dev/null || true
# fbcon 与 Qt 共用 /dev/fb0，启动前解绑，避免桌面被开机 logo 覆盖
sh /usr/bin/fbcon-off >/dev/null 2>&1 || true
export QT_QPA_PLATFORM=linuxfb
export QT_QPA_GENERIC_PLUGINS=evdevtouch
# 显式指定触摸设备（已确认 goodix-ts 在 event1），别依赖自动探测：
# 板子上还有 event0(powerkey)/event2(gpio_keys) 两个非触摸设备。
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=/dev/input/event1
export QT_QPA_FONTDIR=/usr/share/fonts
unset DISPLAY
exec ./qttest "$@"
EOF
chmod 755 "$STAGE/run.sh"
( cd "$STAGE" && tar cf - . ) | gzip -c | \
  timeout 300 $SSH root@192.168.10.2 'mkdir -p /opt/qttest && cd /opt/qttest && gzip -d | tar xf - && chmod 755 run.sh qttest && ls -l && echo "--- 板子上的 Qt5 运行库 ---" && (ls /usr/lib/libQt5Widgets.so.5* /usr/lib/qt/plugins/platforms/libqlinuxfb.so 2>/dev/null || echo "  ⚠️ 板上还没 Qt5 库：先 bash emmc/scripts/deploy-nfs-rootfs.sh 把带 Qt 的新 rootfs 挂上（NFS dev 模式）")'

echo
echo "✅ 就绪。板子上这样跑（前台跑，才能看到每秒的 STAT 行）："
echo "   ssh 进板子 → /opt/qttest/run.sh"
echo "   判据：出现 'platform : linuxfb'、'screen : 1024x600'，"
echo "         屏幕上有渐变背景+移动方块，点屏幕打印 TOUCH 行，"
echo "         每秒一行 STAT fps=... avg_paint=...ms"
