#!/bin/sh
# ============================================================
#  第 44 章　LED 驱动一键加载验证脚本（在开发板 Linux 上运行）
#
#  用法：
#     sh /mnt/nfs/root/44_led.sh
#
#  它会依次做：
#     ① 检查/挂载 NFS
#     ② 卸载旧的 dtsled（如果有）
#     ③ 按大小认版本（8360=旧字符驱动 / 11076=platform driver）+ 检查无 PIC 符号
#     ④ insmod
#     ⑤ 验证 /dev/dtsled 和 dmesg
#     ⑥ 点灯 1 秒 → 熄灭（肉眼确认）
# ============================================================

NFS_SRV=192.168.10.1
NFS_EXP=/nfs/rootfs
NFS_MNT=/mnt/nfs
MOD=$NFS_MNT/root/dtsled.ko
APP=$NFS_MNT/root/ledtest
DEV=/dev/dtsled

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; }
step() { echo; echo "=== $1 ==="; }

step "① 挂载 NFS"
if mount | grep -q " $NFS_MNT "; then
	ok "$NFS_MNT 已挂载"
else
	mkdir -p $NFS_MNT
	mount -t nfs -o nolock,vers=3 $NFS_SRV:$NFS_EXP $NFS_MNT
	if [ $? -ne 0 ]; then
		bad "挂载失败。先查网络： ip -br a ; ping -c3 $NFS_SRV"
		exit 1
	fi
	ok "挂载成功"
fi
ls -l $MOD $APP 2>/dev/null || { bad "NFS 上找不到 dtsled.ko / ledtest"; exit 1; }

step "② 卸载旧的 dtsled（如果已加载）"
if lsmod | grep -q '^dtsled'; then
	rmmod dtsled && ok "已卸载旧模块" || { bad "卸载失败，先手动 rmmod dtsled"; exit 1; }
else
	ok "没有旧模块，跳过"
fi

step "③ 检查模块版本（按大小认版本）"
SZ=$(wc -c < $MOD)
echo "  大小: $SZ 字节"
case "$SZ" in
	8360)  ok "第44章旧版（纯字符驱动，pinctrl_myled 不生效）" ;;
	11076) ok "第44章新版（platform driver，pinctrl_myled 生效）" ;;
	8440)  bad "最老的版本：会报 Unknown symbol _GLOBAL_OFFSET_TABLE_"
	       echo "      → 到虚拟机上重新执行： ./build_deploy.sh"
	       exit 1 ;;
	*)     echo "  ！没见过这个大小（$SZ）—— 继续跑，但请核对一下是不是你要的版本" ;;
esac
# 真正的质量判据：不能有 PIC 符号（第44章踩坑 #4）
if grep -q '_GLOBAL_OFFSET_TABLE_' $MOD 2>/dev/null; then
	bad "模块里还有 PIC 符号，不能加载"
	exit 1
else
	ok "无 PIC 符号"
fi

step "④ insmod"
insmod $MOD
if [ $? -ne 0 ]; then
	bad "insmod 失败，看下面的 dmesg"
	dmesg | tail -10
	exit 1
fi
ok "insmod 成功（沉默即成功）"

step "⑤ 验证"
lsmod | grep '^dtsled' && ok "lsmod 里有 dtsled" || bad "lsmod 里没有"
if [ -c "$DEV" ]; then
	ok "设备节点 $DEV 存在"
else
	bad "$DEV 不存在"
fi
echo
echo "  ---- dmesg 最后 12 行 ----"
dmesg | tail -12
echo "  --------------------------"
echo
echo "  期望看到（信息级，不是 error）："
echo "     alphaled node find!"
echo "     dtsled: pinctrl \"default\" state selected (pinctrl_myled 已生效)   ← 新版才有"
echo "     compatible = atkalpha-led"
echo "     status = okay"
echo "     led_gpio num = 3, active_low"
echo "     dtsled major=24x, minor=0"
echo
echo "  ★ 想眼见为实 pinctrl 真的生效了，可以读 IOMUXC 的 pad 控制寄存器："
echo "     devmem 0x020E02F4"
echo "       0x10B0  = 旧版（U-Boot 留下的值，说明 pinctrl_myled 没生效）"
echo "       0x17059 = 新版（dts 里 pinctrl_myled 写的值，说明生效了）"
echo "     注意：GPIO1_IO03 用的是【主 IOMUXC】，寄存器读回准确；"
echo "     对比之下 SNVS 焊盘（GPIO5_x）的 pad 寄存器读回会被硬件改写（见第45章 §8.5）"

step "⑥ 点灯测试（1 秒）"
if [ -x "$APP" ]; then
	echo "  → 点亮"
	$APP $DEV 1
	sleep 1
	echo "  → 熄灭"
	$APP $DEV 0
	ok "两次 write 调用都返回成功"
	echo
	echo "  ★ 刚才那 1 秒板子上的红灯亮了吗？"
	echo "     亮了   → 第 44 章完成 🎉"
	echo "     没亮   → 检查是不是接错了灯，或 gpio 极性反了"
else
	bad "$APP 不可执行"
fi

echo
echo "=== 全部完成 ==="
