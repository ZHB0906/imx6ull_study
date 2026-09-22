#!/bin/bash
#
# post-build-chain.sh —— 构建完成后自动接着干（脱离会话运行，可安全断网/关对话）
#
#   setsid nohup bash emmc/scripts/post-build-chain.sh >/dev/null 2>&1 < /dev/null &
#
# 做什么（都是有硬判据、失败即停的步骤）：
#   1) 等主构建（br2-build.sh）结束
#   2) 确认没有真失败信号 → 跑 qt-finish.sh all
#        = 查 Qt 产物 → 重生成配置(带 QSCINTILLA) → 编 QScintilla → 编 SerialTool → 推上板
#   3) 部署 rootfs 到 NFS（板子不可达就跳过，不算失败）
#
# 故意**不做**的事（留给人/交互，避免无人值守时把板子搞成不确定状态）：
#   ✗ 切 kill switch / 重启板子        （改了它板子才会切到 NFS dev 模式）
#   ✗ 上板跑测试                       （触摸验收需要人点屏幕）
#   ✗ 固化回 eMMC                      （会覆写分区，必须有人盯着）
#
# 日志：emmc/out/post-build-chain.log
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
LOG=$NEW/out/post-build-chain.log
BUILDLOG=$NEW/out/build-buildroot.log

exec >>"$LOG" 2>&1
echo
echo "════════════════════════════════════════════════════════════"
echo " post-build-chain 启动于 $(date +'%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"

# ── 1) 等主构建结束 ────────────────────────────────────────────
echo "[1] 等待主构建结束…"
for i in $(seq 1 720); do            # 最多等 6 小时
	if ! pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
		echo "[1] 主构建进程已结束（$(date +'%H:%M:%S')）"
		break
	fi
	[ $(( i % 20 )) = 0 ] && echo "    仍在编译… $(date +'%H:%M:%S')  qtbase .o=$(find $NEW/buildroot/output/build/qt5base-5.11.3 -name '*.o' 2>/dev/null | wc -l)"
	sleep 30
done
if pgrep -f "scripts/br2-build.sh" >/dev/null 2>&1; then
	echo "[1] ❌ 等待超时（6 小时），放弃自动链"
	exit 2
fi

# ── 2) 确认构建真的成功 ────────────────────────────────────────
echo
echo "[2] 检查构建结果"
rfail=$(grep -c "pkg-generic.mk:[0-9]*: .*Error" "$BUILDLOG" 2>/dev/null); rfail=${rfail:-0}
tfail=$(grep -c "_all\] Error" "$BUILDLOG" 2>/dev/null); tfail=${tfail:-0}
echo "    真失败信号：包 $rfail / 顶层 $tfail"
if [ "$rfail" != 0 ] || [ "$tfail" != 0 ]; then
	echo "    ❌ 构建失败，不自动往下走。日志尾部："
	tail -20 "$BUILDLOG" | sed 's/^/      /'
	echo
	echo "SUMMARY: 构建失败，需要人工介入"
	exit 3
fi
if [ ! -e "$NEW/buildroot/output/host/bin/qmake" ]; then
	echo "    ❌ 宿主 qmake 不存在 —— 构建看起来没到安装阶段，不往下走"
	echo "SUMMARY: 构建不完整（缺 qmake）"
	exit 3
fi
echo "    ✅ 构建成功"

# ── 3a) 查 Qt 产物 ─────────────────────────────────────────────
echo
echo "[3a] qt-finish.sh check（查 Qt 产物齐全性）开始 $(date +'%H:%M:%S')"
bash "$NEW/scripts/qt-finish.sh" check
rc=$?
echo "[3a] check 退出码=$rc（$(date +'%H:%M:%S')）"
if [ "$rc" != 0 ]; then
	echo
	echo "SUMMARY: Qt 产物检查失败（退出码 $rc），需要人工介入"
	exit 4
fi

# ── 3b) 编 QScintilla（不需要板子）──────────────────────────────
echo
echo "[3b] qt-finish.sh qscintilla 开始 $(date +'%H:%M:%S')"
bash "$NEW/scripts/qt-finish.sh" qscintilla
rc=$?
echo "[3b] qscintilla 退出码=$rc（$(date +'%H:%M:%S')）"
if [ "$rc" != 0 ]; then
	echo
	echo "SUMMARY: QScintilla 失败（退出码 $rc），需要人工介入"
	exit 4
fi

# ── 3c) 编 SerialTool（★ 只编译，不依赖板子）────────────────────
echo
echo "[3c] 交叉编译 SerialTool（只编译）开始 $(date +'%H:%M:%S')"
bash "$NEW/scripts/build-serialtool.sh" build
rc=$?
echo "[3c] build 退出码=$rc（$(date +'%H:%M:%S')）"
if [ "$rc" != 0 ]; then
	echo
	echo "SUMMARY: SerialTool 编译失败（退出码 $rc），需要人工介入"
	exit 4
fi

# ── 3d) 推上板（板子不通就跳过 —— 不算失败）────────────────────
echo
echo "[3d] 推 SerialTool 到板子"
if ping -c1 -W2 192.168.10.2 >/dev/null 2>&1; then
	bash "$NEW/scripts/build-serialtool.sh" push
	echo "[3d] push 退出码=$?（板子可达）"
else
	echo "    ⚠️ 板子 ping 不通（已断开/断电/网卡关了）→ 跳过推送，**不算失败**"
	echo "    （板子回来后手动补：bash emmc/scripts/build-serialtool.sh push）"
fi

# ── 4) 部署 rootfs 到 NFS（板子不通就跳过）────────────────────
echo
echo "[4] 部署 rootfs 到 NFS"
if ping -c1 -W2 192.168.10.2 >/dev/null 2>&1; then
	bash "$NEW/scripts/deploy-nfs-rootfs.sh"
	echo "[4] deploy 退出码=$?"
else
	echo "    ⚠️ 板子 ping 不通（可能断网/断电/网卡关了）→ 跳过部署"
	echo "    （回来后手动跑：bash emmc/scripts/deploy-nfs-rootfs.sh）"
fi

# ── 5) 总结 ────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════"
echo "SUMMARY: 自动链完成于 $(date +'%Y-%m-%d %H:%M:%S')"
echo "  ✅ Qt 产物齐全"
echo "  ✅ QScintilla 编完"
echo "  ✅ SerialTool 交叉编译完成（二进制在 emmc/apps/serialtool-stage/SerialTool）"
if ping -c1 -W2 192.168.10.2 >/dev/null 2>&1; then
	echo "  ✅ SerialTool 已推到板子 /opt/serialtool/"
	echo "  ✅ NFS rootfs 已铺"
else
	echo "  ⏭ 板子当时不可达 → 推送/部署已跳过（**不是失败**，板子回来补跑即可）"
	echo "     补跑： bash emmc/scripts/build-serialtool.sh push"
	echo "            bash emmc/scripts/deploy-nfs-rootfs.sh"
fi
echo "  下一步（都需要板子在线 + 人工/交互）："
echo "     bash emmc/scripts/board-go-live.sh up      # 切 NFS dev 模式（带就绪闸）"
echo "     bash emmc/scripts/qt-minimal-test.sh       # 验证 linuxfb/字体/帧率"
echo "     bash emmc/scripts/serialtool-test.sh serial # 串口通路（需触摸时我会请你点屏幕）"
echo "════════════════════════════════════════════════════════════"
