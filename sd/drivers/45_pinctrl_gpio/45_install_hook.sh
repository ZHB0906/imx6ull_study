#!/bin/sh
# ============================================================
#  第 45 章　安装"开机钩子"（🐧 在开发板 Linux 上运行）
#
#  用法：
#      sh /mnt/nfs/root/45_install_hook.sh
#
#  钩子做三件事（每次开机自动执行）：
#      ① 配好 eth0 = 192.168.10.2
#      ② 挂上虚拟机的 NFS 到 /mnt/nfs（挂不上会在后台重试，虚拟机晚开也没事）
#      ③ 启动 telnetd —— 这样【虚拟机可以直接 telnet 192.168.10.2】进来调试，
#         第 46 章（并发与竞争）要反复"加载模块 → 双进程测试 → 改锁 → 再测"，
#         有这个就不用每次手敲串口了。
#
#  【踩坑 #10】ext4 是延迟分配：写文件后数据还在页缓存，要 sync 过才落 SD 卡。
#  少了这步会看到：/etc/nfs-net.sh 存在但 0 字节、追加到 rcS 的行凭空消失。
#
#  撤销（三件一起）：killall telnetd
#                    rm -f /etc/nfs-net.sh
#                    删掉 /etc/init.d/rcS 末尾那两行
# ============================================================

RC=/etc/init.d/rcS
HOOK=/etc/nfs-net.sh

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; }

echo "=== 安装开机钩子 ==="
cat > $HOOK <<'EOF'
#!/bin/sh
# 第45章迭代用开机钩子：eth0=192.168.10.2 + 挂 NFS + 起 telnetd
# 撤销：见 /mnt/nfs/root/45_install_hook.sh 顶部注释
SRV=192.168.10.1
IP=192.168.10.2

# ① 网络：FEC 链路大约 3 秒才 UP，所以最多等 8 秒
n=0
while [ $n -lt 8 ]; do
	n=$((n + 1))
	ip link set eth0 up 2>/dev/null
	ip addr add $IP/24 dev eth0 2>/dev/null
	ping -c1 -W1 $SRV >/dev/null 2>&1 && break
	sleep 1
done

# ② NFS：通了就挂；暂时不通就丢到后台重试（虚拟机还没开机也能自动挂上）
mount_nfs() {
	mkdir -p /mnt/nfs
	mount | grep -q " /mnt/nfs " || \
		mount -t nfs -o nolock,vers=3 $SRV:/nfs/rootfs /mnt/nfs 2>/dev/null
}
if ping -c1 -W1 $SRV >/dev/null 2>&1; then
	mount_nfs
else
	(
		i=0
		while [ $i -lt 30 ]; do
			i=$((i + 1))
			sleep 2
			if ping -c1 -W1 $SRV >/dev/null 2>&1; then
				mount_nfs
				break
			fi
		done
	) &
fi

# ③ telnetd：不依赖上面成功与否，直接起（只要网线通了就能连）
if [ -x /usr/sbin/telnetd ]; then
	pidof telnetd >/dev/null 2>&1 || telnetd -l /bin/sh
fi
EOF
chmod 755 $HOOK

SZ=$(wc -c < $HOOK)
if [ "$SZ" -lt 100 ]; then
	bad "$HOOK 只有 $SZ 字节，写入不完整（磁盘满？）"
	exit 1
fi
ok "$HOOK 已写入（$SZ 字节）"

if grep -q "nfs-net.sh" $RC 2>/dev/null; then
	ok "$RC 里已有钩子，不重复追加"
else
	printf '\n# 第45章迭代：开机自动配网 + 挂 NFS + telnetd（撤销见 /etc/nfs-net.sh）\n[ -x /etc/nfs-net.sh ] && /etc/nfs-net.sh\n' >> $RC
	ok "已追加钩子到 $RC"
fi

# ★★ 必须 sync，否则复位后上面全丢（踩坑 #10）
sync
sync
echo "  ⏳ 已 sync（ext4 延迟分配，等它写回 SD 卡）"

echo
echo "=== 立刻生效一次（不用等复位）==="
sh $HOOK >/dev/null 2>&1
sleep 1

if pidof telnetd >/dev/null 2>&1; then
	ok "telnetd 已在跑（端口 23）→ 虚拟机可以 telnet 192.168.10.2"
else
	bad "telnetd 没起来：ls -l /usr/sbin/telnetd 看看在不在"
fi
if mount | grep -q " /mnt/nfs "; then
	ok "/mnt/nfs 已挂上"
else
	bad "/mnt/nfs 还没挂上（网络或 NFS 服务的问题）"
fi
if ping -c1 -W1 192.168.10.1 >/dev/null 2>&1; then
	ok "能通虚拟机 192.168.10.1"
else
	bad "连不上 192.168.10.1"
fi

echo
echo "  核对 rcS 末尾（应能看到 nfs-net.sh 那两行）："
tail -3 $RC | sed 's/^/     /'
echo
echo "  以后每次复位都会自动：配网 + 挂 NFS + 起 telnetd"
echo "  不想要 telnetd：killall telnetd 并注释掉钩子里那两行"
