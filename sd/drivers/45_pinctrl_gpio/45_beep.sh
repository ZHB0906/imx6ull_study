#!/bin/sh
# ============================================================
#  第 45 章　蜂鸣器 + LED 回归 一键验证脚本（🐧 在开发板 Linux 上运行）
#
#  用法：
#     sh /mnt/nfs/root/45_beep.sh
#
#  依次做：
#     ① 挂载 NFS
#     ② 卸载旧 beep / dtsled
#     ③ 检查 beep.ko 是不是无 PIC 的版本
#     ④ insmod beep.ko，看 dmesg（★ 重点看 beep_gpio num = 129, active_low）
#     ⑤ 响 1 秒 → 停（听声音）
#     ⑥ LED 回归：dtsled 还能不能点亮（确认改了 pinctrl 引用没把第 44 章弄坏）
# ============================================================

NFS_SRV=192.168.10.1
NFS_EXP=/nfs/rootfs
NFS_MNT=/mnt/nfs
MOD=$NFS_MNT/root/beep.ko
APP=$NFS_MNT/root/beepTest
DEV=/dev/beep

LED_MOD=$NFS_MNT/root/dtsled.ko
LED_APP=$NFS_MNT/root/ledtest
LED_DEV=/dev/dtsled

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; }
step() { echo; echo "=== $1 ==="; }

step "⓪ 网络（SD 卡启动模式下要手动配；NFS 根模式可跳过）"
# 注意：U-Boot 的网络是坏的（dram_init_banksize 缺失 → 全内存 Strongly-ordered →
# net_set_ip_header 的非对齐写触发 data abort），所以这条链路上唯一能用的是
# 【板子 Linux】自己的 FEC 驱动。eth0 = 0x020b4000，正是 U-Boot 协商成功的那块。
if ping -c1 -W1 $NFS_SRV >/dev/null 2>&1; then
	ok "已经能通 $NFS_SRV"
else
	for i in eth0 eth1; do
		[ -e /sys/class/net/$i ] || continue
		ip link set $i up 2>/dev/null
		ip addr add 192.168.10.2/24 dev $i 2>/dev/null
		if ping -c1 -W1 $NFS_SRV >/dev/null 2>&1; then
			ok "$i 已配 192.168.10.2，能通 $NFS_SRV"
			break
		fi
		ip addr del 192.168.10.2/24 dev $i 2>/dev/null
	done
fi
ping -c1 -W1 $NFS_SRV >/dev/null 2>&1 || {
	bad "连不上 $NFS_SRV：确认网线插在 ETH1/ETH2 上、虚拟机 tftpd/nfs 在跑"; exit 1; }

step "① 挂载 NFS"
if mount | grep -q " $NFS_MNT "; then
	ok "$NFS_MNT 已挂载"
else
	mkdir -p $NFS_MNT
	mount -t nfs -o nolock,vers=3 $NFS_SRV:$NFS_EXP $NFS_MNT || {
		bad "挂载失败。先查网络： ip -br a ; ping -c3 $NFS_SRV"
		exit 1
	}
	ok "挂载成功"
fi
ls -l $MOD $APP 2>/dev/null || { bad "NFS 上找不到 beep.ko / beepTest（先跑 build_deploy.sh）"; exit 1; }

step "② 卸载旧模块"
for m in beep dtsled; do
	if lsmod | grep -q "^$m"; then
		rmmod $m && ok "已卸载 $m" || { bad "卸载 $m 失败"; exit 1; }
	else
		ok "没有 $m，跳过"
	fi
done

step "③ 检查 beep.ko 是不是无 PIC 版本"
SZ=$(wc -c < $MOD)
echo "  大小: $SZ 字节"
if grep -q '_GLOBAL_OFFSET_TABLE_' $MOD 2>/dev/null; then
	bad "模块里还有 PIC 符号 → 上板必然 Unknown symbol _GLOBAL_OFFSET_TABLE_"
	echo "     → 虚拟机上重跑 ./build_deploy.sh"
	exit 1
fi
ok "无 PIC 符号"

step "④ insmod beep.ko"
insmod $MOD || {
	bad "insmod 失败，看下面 dmesg"
	dmesg | tail -10
	exit 1
}
ok "insmod 成功"
if [ -c "$DEV" ]; then ok "设备节点 $DEV 存在"; else bad "$DEV 不存在"; fi
echo
echo "  ---- dmesg 最后 14 行 ----"
dmesg | tail -14
echo "  --------------------------"
echo
echo "  期望看到："
echo "     mybeep node find!"
echo "     compatible = atkalpha-beep"
echo "     status = okay"
echo "     beep_gpio num = 129, active_low   ← 129 = GPIO5基址128 + 1 = GPIO5_IO01"
echo "     beep major=24x, minor=0"
echo
echo "  ★ 如果看到 mybeep node not find! → 板子用的 dtb 里没有这个节点："
echo "     虚拟机上 ./build_dtb.sh 重新编译并拷进 /tftpboot，然后复位重启"

step "⑤ 响 1 秒（听）"
if [ -x "$APP" ]; then
	echo "  → 响（写 1）"
	$APP $DEV 1
	sleep 1
	echo "  → 停（写 0）"
	$APP $DEV 0
	ok "两次 write 都返回成功"
	echo
	echo "  ★ 刚才那 1 秒蜂鸣器响了吗？"
	echo "     响了   → 极性与设备树一致（GPIO_ACTIVE_LOW，响 = 引脚低电平）"
	echo "     没响   → 反过来测一次：先 \$APP $DEV 0 再 \$APP $DEV 1"
	echo "              若反了，把 dts 里 beep-gpio 改成 GPIO_ACTIVE_HIGH 后重新 build_dtb.sh"
	echo "     一直响 → 你的板子是高电平有效，且当前处于'响'态，赶紧写 0 停掉"
else
	bad "$APP 不可执行"
fi

step "⑥ LED 回归（第 44 章功能没被 pinctrl 改动弄坏）"
if [ -f "$LED_MOD" ] && [ -x "$LED_APP" ]; then
	insmod $LED_MOD && ok "dtsled 加载成功（pinctrl_myled 生效）" || bad "dtsled 加载失败，看 dmesg"

	$LED_APP $LED_DEV 1
	sleep 1
	$LED_APP $LED_DEV 0
	ok "LED 亮灭命令已执行"
	echo "  ★ 灯亮了吗？亮了说明换成 pinctrl_myled 后一切正常"
else
	echo "  跳过（NFS 上没有 dtsled.ko / ledtest）"
fi

echo
echo "=== 全部完成 ==="
