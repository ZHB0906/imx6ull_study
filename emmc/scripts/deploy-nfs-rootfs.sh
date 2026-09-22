#!/bin/bash
#
# deploy-nfs-rootfs.sh —— 把 Buildroot 产出的 rootfs 铺到 NFS 根目录（开发模式用）
#
#     bash emmc/scripts/deploy-nfs-rootfs.sh
#
# 为什么用 /nfs/rootfs/new：
#   /nfs/rootfs 已经是 drwxrwxrwx 且导出给 *(rw,sync,no_root_squash)，
#   在它下面建子目录不需要改 /etc/exports、**不需要 sudo**。
#
# ★ 两个踩过的坑（都写进这里了）：
#   ① 我们把 NFS 根 chown 成 root:root 之后，**虚拟机上的 zhb 删不掉/改不了**这些文件
#      → 所以"擦除"和"chown"都必须**从板子（root）**做。
#   ② 如果板子此刻**正跑着 NFS 根**，擦除就等于删掉它正在运行的系统 ✗
#      → 脚本先检查板子的 `/` 是不是 NFS，是就拒绝并提示先切回 eMMC。
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
SRC=$NEW/buildroot/output/target
DEST=/nfs/rootfs/new
KREL=$(cat "$NEW/linux/IMX6ULL/linux-imx/include/config/kernel.release")
BOARD=192.168.10.2
BOARD6=fe80::8a2d:b6ff:fe8d:356d%ens37
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say()  { printf '\n== %s ==\n' "$*"; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
pass=0; fail=0
ok()   { printf '  ✅ %-38s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  ❌ %-38s %s\n' "$1" "$2"; fail=$((fail+1)); }

board_reach() {
	# ★ 不用 `ssh | grep -q`：本脚本开了 pipefail，ssh 的非零退出码会污染管道状态，
	#   一次瞬时抖动就会被误判成"板子不可达" → 后面会**跳过 chown** →
	#   新 rootfs 属主变成 uid 1000，dropbear 密钥登录直接失效。
	#   所以先取回输出再判断，并且超时给宽一点。
	local out
	out=$(timeout 20 $SSH root@$BOARD 'echo ok' 2>/dev/null) || true
	case "$out" in *ok*) echo "ipv4"; return 0 ;; esac
	out=$(timeout 25 $SSH root@$BOARD6 'echo ok' 2>/dev/null) || true
	case "$out" in *ok*) echo "ipv6"; return 0 ;; esac
	return 1
}
BRUN() {
	local ch; ch=$(board_reach) || return 1
	if [ "$ch" = ipv6 ]; then timeout 300 $SSH root@$BOARD6 "$@"; else timeout 300 $SSH root@$BOARD "$@"; fi
}

say "检查产物"
[ -d "$SRC" ] || die "找不到 $SRC（Buildroot 还没编完？）"
echo "  target 体积: $(du -sh "$SRC" | cut -f1)"

say "检查板子状态"
CH=""
if CH=$(board_reach); then
	echo "  板子可达（$CH）"
	ROOTSRC=$(BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; mount | awk "/ \/ /{print \$1\" \"\$5}"')
	echo "  板子当前根: $ROOTSRC"
	case "$ROOTSRC" in
		*nfs*|*:/nfs/*)
			die "板子正跑 NFS 根 —— 先切回 eMMC 再部署：
     mv /tftpboot/nfsboot-on{,.disabled}
     然后重启板子（它会走 eMMC）" ;;
	esac
else
	echo "  ⚠️ 板子不可达 —— 擦除/chown 只能靠本地权限碰运气"
fi

say "① 擦除旧内容（优先从板子做，因为文件是 root 拥有）"
WIPED=no
if [ -n "$CH" ]; then
	if BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
mkdir -p /mnt/nfsroot
mount -t nfs -o nolock,vers=3 192.168.10.1:/nfs/rootfs /mnt/nfsroot 2>/dev/null || { echo MOUNTFAIL; exit 1; }
cp -f /mnt/nfsroot/new/etc/wpa_supplicant.conf /tmp/wpa-old.conf 2>/dev/null
rm -rf /mnt/nfsroot/new/* /mnt/nfsroot/new/.nfs-ready 2>/dev/null
echo "  擦除后剩余: $(ls -A /mnt/nfsroot/new | wc -l) 个条目"
umount /mnt/nfsroot' 2>&1 | tail -3; then
		WIPED=yes
	fi
fi
if [ "$WIPED" != yes ]; then
	echo "  （板子不可达或挂载失败）改成本地擦除…"
	rm -f "$DEST/.nfs-ready"
	find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
	left=$(ls -A "$DEST" 2>/dev/null | wc -l)
	[ "$left" = 0 ] || die "本地擦除没成功（还剩 $left 项，多半是 root 拥有的文件）—— 请让板子在线再跑一次"
	echo "  本地擦除完成"
fi

say "② 拷贝新 rootfs（以 zhb 身份，属主先变成 1000，稍后由板子改回 root）"
cp -a "$SRC"/. "$DEST"/
sync
echo "  拷完体积: $(du -sh "$DEST" | cut -f1)"

say "③ 从板子 chown 回 root:root + 恢复 wpa 配置 + 修权限"
if [ -n "$CH" ]; then
	BRUN 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH
mkdir -p /mnt/nfsroot
mount -t nfs -o nolock,vers=3 192.168.10.1:/nfs/rootfs /mnt/nfsroot || exit 1
T=/mnt/nfsroot/new
for d in bin sbin lib lib32 usr etc root var opt home media mnt srv; do [ -d "$T/$d" ] && chown -R 0:0 "$T/$d" 2>/dev/null; done
[ -f /tmp/wpa-old.conf ] && { cp -f /tmp/wpa-old.conf "$T/etc/wpa_supplicant.conf"; chmod 600 "$T/etc/wpa_supplicant.conf"; }
chmod 700 "$T/root/.ssh" 2>/dev/null; chmod 600 "$T/root/.ssh/authorized_keys" 2>/dev/null
chmod 755 "$T/etc/init.d/S45wifi" "$T/etc/init.d/S50telnetd" "$T/root/set-wifi.sh" 2>/dev/null
echo "  chown 完成"
umount /mnt/nfsroot' 2>&1 | tail -2
else
	echo "  ⚠️ 板子不在线 → 跳过 chown（新 rootfs 属主会是 uid 1000，dropbear 密钥登录会被拒；telnet 密码登录仍可用）"
fi

say "④ 判据"
for f in bin/busybox etc/init.d/S45wifi usr/sbin/wpa_supplicant usr/sbin/dropbear \
         "lib/modules/$KREL/8189fs.ko" root/set-wifi.sh etc/wpa_supplicant.conf; do
	[ -e "$DEST/$f" ] && ok "$(basename $f)" "$f" || bad "$(basename $f)" "缺失：$f"
done
if ls "$DEST"/usr/lib/libQt5Core.so.5* >/dev/null 2>&1; then
	ok "Qt5 运行库" "$(basename "$(ls $DEST/usr/lib/libQt5Core.so.5* | head -1)")"
else
	echo "  ⚠️ 没看到 libQt5Core（本次还没把 Qt5 编进去？）"
fi

echo
echo "════════════════════════════════════"
if [ "$fail" = 0 ]; then
	touch "$DEST/.nfs-ready"
	echo "  通过 $pass 项，失败 0 项 ✅（已置就绪标记）"
	echo "  切 dev 模式： mv /tftpboot/nfsboot-on.disabled /tftpboot/nfsboot-on && 重启板子"
else
	echo "  通过 $pass 项，失败 $fail 项 ❌（未置就绪标记）"
	exit 1
fi
