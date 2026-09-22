#!/bin/bash
#
# check-artifacts.sh —— M3 产物检查（★ 只检查，不部署、不碰板子）
#
#     bash emmc/scripts/check-artifacts.sh
#
# 检查 Buildroot 有没有把我们要的东西都组装进 output/target/：
#   ① 基础系统（busybox + init 脚本）
#   ② 无线套件（wpa_supplicant 带不带 wext 后端 / iw / wireless_tools）
#   ③ 我们的 overlay（S45wifi / S50telnetd / set-wifi.sh / authorized_keys）
#   ④ WiFi 模块（8189fs.ko 在不在 / vermagic 对不对 / 有没有 PIC 残留）
#   ⑤ 镜像（本轮故意关掉，说明为什么）
#
# 注意：本轮不生成 rootfs.tar / ext4（fakeroot 在 glibc 2.35 上不可用，见 external.mk），
#       NFS 根直接用 output/target/ 这棵树。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
T=$NEW/buildroot/output/target
OV=$NEW/br2-external/board/atk/rootfs-overlay
KES=$NEW/linux/IMX6ULL/linux-imx
KREL=$(cat "$KES/include/config/kernel.release")
pass=0; fail=0

ok()  { printf '  ✅ %-46s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad() { printf '  ❌ %-46s %s\n' "$1" "$2"; fail=$((fail+1)); }
warn(){ printf '  ⚠️  %-46s %s\n' "$1" "$2"; }

exist() { # $1=路径(相对 target) $2=说明
	if [ -e "$T/$1" ]; then ok "$2" "$(ls -ld "$T/$1" | awk '{print $5" 字节"}')"; else bad "$2" "缺失：$1"; fi
}

echo "════════ M3 产物检查 @ $(date '+%H:%M:%S') ════════"
echo "  target : $T"
echo "  内核版本: $KREL"

if [ ! -d "$T" ]; then
	echo "  ❌ output/target/ 不存在 —— 构建还没到组装阶段？"
	exit 1
fi
echo "  target 体积: $(du -sh "$T" 2>/dev/null | cut -f1)"

echo
echo "── ① 基础系统 ──"
exist bin/busybox "busybox"
exist etc/inittab "inittab（串口 getty）"
exist sbin/init "init"
grep -q "ttymxc0" "$T/etc/inittab" 2>/dev/null && ok "getty 挂在 ttymxc0" "有" || bad "getty 挂在 ttymxc0" "inittab 里没有"

echo
echo "── ② 无线套件 ──"
exist usr/sbin/wpa_supplicant "wpa_supplicant"
exist usr/sbin/wpa_cli "wpa_cli"
exist usr/sbin/iw "iw"
# 注意：wireless_tools 实际装在 /sbin（不是 /usr/sbin）—— 检查路径要以实际为准
if [ -x "$T/sbin/iwconfig" ]; then
	ok "wireless_tools(iwconfig)" "$(stat -c '%s' "$T/sbin/iwconfig") 字节 /sbin/iwconfig"
elif [ -x "$T/usr/sbin/iwconfig" ]; then
	ok "wireless_tools(iwconfig)" "$(stat -c '%s' "$T/usr/sbin/iwconfig") 字节 /usr/sbin/iwconfig"
else
	bad "wireless_tools(iwconfig)" "缺失（/sbin 与 /usr/sbin 都没有）"
fi
# ★ 关键：wext 后端在不在（M5 靠它连 Red）
WCFG=$(ls -d $NEW/buildroot/output/build/wpa_supplicant-*/wpa_supplicant/.config 2>/dev/null | head -1)
if [ -n "$WCFG" ]; then
	grep -qE '^CONFIG_DRIVER_WEXT=y' "$WCFG" && ok "wpa_supplicant 带 wext 后端" "CONFIG_DRIVER_WEXT=y" || bad "wpa_supplicant 缺 wext 后端" "M5 会用不上 -Dwext"
	grep -qE '^CONFIG_DRIVER_NL80211=y' "$WCFG" && ok "wpa_supplicant 带 nl80211 后端" "CONFIG_DRIVER_NL80211=y" || warn "wpq_supplicant 无 nl80211" "备用后端不可用"
else
	warn "找不到 wpa_supplicant 的 .config" "无法确认后端"
fi

echo
echo "── ③ 我们的 overlay ──"
for f in etc/init.d/S45wifi etc/init.d/S50telnetd root/set-wifi.sh root/.ssh/authorized_keys etc/wpa_supplicant.conf; do
	exist "$f" "$(basename $f)"
done
# 权限
[ "$(stat -c %a "$T/root/.ssh" 2>/dev/null)" = "700" ] && ok "root/.ssh 权限 700" "700" || bad "root/.ssh 权限" "$(stat -c %a "$T/root/.ssh" 2>/dev/null)"
[ "$(stat -c %a "$T/root/.ssh/authorized_keys" 2>/dev/null)" = "600" ] && ok "authorized_keys 权限 600" "600" || bad "authorized_keys 权限" "$(stat -c %a "$T/root/.ssh/authorized_keys" 2>/dev/null)"
for s in S45wifi S50telnetd; do
	[ -x "$T/etc/init.d/$s" ] && ok "$s 可执行" "755" || bad "$s 不可执行" "$(stat -c %a "$T/etc/init.d/$s" 2>/dev/null)"
done
# overlay 内容是否就是我们写的（不是出厂残留）
if [ -f "$OV/etc/init.d/S45wifi" ] && cmp -s "$OV/etc/init.d/S45wifi" "$T/etc/init.d/S45wifi"; then
	ok "S45wifi 与 overlay 一致" "同一份"
else
	warn "S45wifi 与 overlay 不一致" "检查是否被覆盖"
fi
# 新 rootfs 里绝不能有 ConnMan（老的假默认路由问题不该复现）
[ -e "$T/usr/sbin/connmand" ] && bad "rootfs 里没有 ConnMan" "存在！" || ok "rootfs 里没有 ConnMan" "干净"

echo
echo "── ④ WiFi 模块 ──"
KO="$T/lib/modules/$KREL/8189fs.ko"
if [ -f "$KO" ]; then
	ok "8189fs.ko 在位" "$(stat -c %s "$KO") 字节"
	vm=$(strings "$KO" | sed -n 's/^vermagic=//p' | head -1)
	case "$vm" in
		"$KREL"*) ok "vermagic 与内核一致" "${vm%% *}" ;;
		*) bad "vermagic 不一致" "内核=$KREL 模块=${vm%% *}" ;;
	esac
	g=$(strings "$KO" | grep -c "_GLOBAL_OFFSET_TABLE_")
	[ "$g" = "0" ] && ok "无 PIC/GOT 残留" "0 条" || bad "有 PIC 残留" "$g 条（加载会报 Unknown symbol）"
	dep=$(strings "$KO" | sed -n 's/^depends=//p' | head -1)
	[ -z "$dep" ] && ok "模块无外部依赖" "depends 为空" || warn "模块有依赖" "$dep"
	[ -f "$T/lib/modules/$KREL/modules.dep" ] && ok "modules.dep 已生成" "depmod 跑过" || warn "没有 modules.dep" "S45wifi 会退回 insmod"
else
	bad "8189fs.ko 缺失" "$KO"
fi

echo
echo "── ⑤ 镜像（本轮故意关掉）──"
n=$(ls -A "$NEW/buildroot/output/images/" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
	warn "output/images/ 里有 $n 个文件" "$(ls -A $NEW/buildroot/output/images/ | tr '\n' ' ')"
else
	warn "没有 rootfs.tar / ext4 镜像（images 目录为空）" "本轮用 output/target/ 作 NFS 根：fakeroot 在 glibc 2.35 上不可用"
fi

echo
echo "════════════════════════════════════════════════"
echo "  通过 $pass 项，失败 $fail 项"
if [ "$fail" = 0 ]; then
	echo "  🎉 M3 产物齐全（未部署、未碰板子 —— 按你的要求到此为止）"
else
	echo "  ⚠️ 有 $fail 项不达标，见上"
fi
exit $([ "$fail" = 0 ] && echo 0 || echo 1)
