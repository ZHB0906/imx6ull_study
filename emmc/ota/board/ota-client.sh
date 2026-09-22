#!/bin/sh
# ============================================================================
# ota-client.sh —— 板子侧 OTA 客户端（整机 A/B 升级）
#
# 用法：
#   ota-client.sh check     只检查远端有没有新版本（不下载、不写槽 ✓ 安全）
#   ota-client.sh update    执行升级：下载 → 校验 → 写非活动槽 → 切 active → 重启
#   ota-client.sh status    看当前槽位与状态
#
# 设计要点（★ 都是踩坑/实测换来的）：
#   · **多 URL 依次尝试** ✓：局域网优先（快 ✓），公网兜底（板子在 NAT 后 ✗ 只能主动拉 ✓）
#   · **断点续传** ✓：公网实测 0.25MB/s 且 WiFi 会掉线 ✗ → `wget -c` ✓（已实测正确 ✓）
#   · **两级校验** ✓：清单里的 sha256（完整性）+ 清单签名（真实性 ✓ 板子无 TLS ✗ 只能靠签名）
#   · **验签 fail-closed** ✓✓：没有可用的验签工具时**拒绝升级** ✗（绝不"跳过校验"继续 ✓）
#   · **写非活动槽** ✓：永远不动正在运行的槽 ✓✓（写坏了也只是那个槽不可用 ✓）
#   · **临时文件放 /slots** ✓：p2 有 6.5GB ✓（别放 /tmp ✗ 那是内存盘 ✗）
#
set -u

CONF=${OTA_CONF:-/etc/ota.conf}
SLOTS=${OTA_SLOTS:-/slots}
STAGE="$SLOTS/ota-staging"
LOG="$SLOTS/ota-client.log"

log()  { echo "[ota] $*"; echo "[$(date 2>/dev/null)] $*" >> "$LOG" 2>/dev/null; }
die()  { log "✗ $*"; exit 1; }

# ---------------------------------------------------------------- 配置
[ -f "$CONF" ] || die "缺少配置文件 $CONF（可从 emmc/ota/board/ota.conf 复制）"
. "$CONF"
[ -n "${URLS:-}" ] || die "$CONF 里没有 URLS"
[ -d "$SLOTS" ] || die "$SLOTS 不存在（不是在 OTA 环境下？）"

# ---------------------------------------------------------------- 状态
active_slot() { cat "$SLOTS/active" 2>/dev/null || echo a; }
inactive_slot() { [ "$(active_slot)" = "a" ] && echo b || echo a; }
slot_image() { # $1=a|b → 输出镜像路径（a 槽 = p2 本体，没有镜像文件 ✓）
	case "$1" in
		a) echo "" ;;
		b) echo "$SLOTS/rootfs-b.ext4" ;;
	esac
}

# ---------------------------------------------------------------- 工具检查
have() { command -v "$1" >/dev/null 2>&1; }
have wget || die "没有 wget"
have sha256sum || die "没有 sha256sum"

# ---------------------------------------------------------------- 验签（fail-closed ✓）
# 优先用 openssl ✓；否则用自带的精简 ed25519 验签器 ✓；都没有 → 拒绝 ✗
verify_sig() { # $1=被签名的文件  $2=签名文件
	if have openssl; then
		openssl dgst -sha256 -verify "${OTA_PUBKEY:-/etc/ota-pub.pem}" \
			-signature "$2" "$1" >/dev/null 2>&1 && return 0 || return 1
	elif [ -x /usr/bin/ed25519-verify ]; then
		/usr/bin/ed25519-verify "${OTA_PUBKEY:-/etc/ota-pub.hex}" "$2" "$1" >/dev/null 2>&1 && return 0 || return 1
	else
		# ★★ 仅实验室的显式放行（默认关闭 ✓）：正规做法是给板子放验签工具 ✓
		#    生产环境绝不可开 ✗✗ —— 打开它等于放弃"真实性"这一层保护 ✓
		if [ "${OTA_ALLOW_UNSIGNED:-0}" = "1" ]; then
			log "⚠️⚠️⚠️ 警告：OTA_ALLOW_UNSIGNED=1 —— **跳过验签**（仅限实验室！生产绝不可开 ✗）"
			log "⚠️⚠️⚠️ 本次升级**无法防篡改**，仅用于联调链路 ✓"
			return 0
		fi
		log "⚠️ 没有可用的验签工具（openssl / ed25519-verify 都没有）"
		return 2      # ★ 特殊返回码：调用方必须**拒绝升级** ✗（fail-closed）
	fi
}

# ---------------------------------------------------------------- 取清单
# 依次尝试各 URL，第一个成功的就用它（并记下 base，后面下载镜像还用同一个源 ✓）
fetch_manifest() {
	for base in $URLS; do
		base=${base%/}
		log "尝试源: $base"
		rm -f "$STAGE/manifest" "$STAGE/manifest.sig"
		mkdir -p "$STAGE"
		if wget -q -T 15 -O "$STAGE/manifest" "$base/update.manifest" 2>/dev/null && [ -s "$STAGE/manifest" ]; then
			log "✅ 从 $base 取到清单 ✓"
			wget -q -T 15 -O "$STAGE/manifest.sig" "$base/update.manifest.sig" 2>/dev/null
			FOUND_BASE="$base"
			return 0
		fi
		log "  失败，换下一个源"
	done
	return 1
}

mget() { # $1=字段名（读清单里的 key=value ✓ 板子上没有 JSON 解析器 ✗ 所以用行式格式 ✓）
	grep "^$1=" "$STAGE/manifest" 2>/dev/null | head -1 | cut -d= -f2-
}

# ---------------------------------------------------------------- check
do_check() {
	mkdir -p "$STAGE"
	log "════ OTA 检查 $(date 2>/dev/null) ════"
	log "当前: 活动槽=$(active_slot)  非活动槽=$(inactive_slot)"
	[ -f "$SLOTS/ota-version" ] && log "当前版本: $(cat "$SLOTS/ota-version")" || log "当前版本: (未记录)"
	fetch_manifest || die "所有源都取不到清单 ✗"
	log "清单内容:"; sed 's/^/    /' "$STAGE/manifest"

	RVER=$(mget version); RSIZE=$(mget size); RSUM=$(mget sha256); RFILE=$(mget file); RMIN=$(mget min_version)
	[ -n "$RVER" ] || die "清单缺 version"
	[ -n "$RSIZE" ] || die "清单缺 size"
	[ -n "$RSUM" ] || die "清单缺 sha256"
	[ -n "$RFILE" ] || die "清单缺 file"

	# 验签 ✓（fail-closed ✓）
	verify_sig "$STAGE/manifest" "$STAGE/manifest.sig"
	case $? in
		0) log "✅ 清单签名校验通过 ✓" ;;
		2) die "没有验签工具 → 拒绝升级 ✗（fail-closed ✓ 安全优先）" ;;
		*) die "清单签名校验**失败** ✗（清单可能被篡改，拒绝 ✗）" ;;
	esac

	# 版本比较（★ 防降级 ✓）
	CVER=$(cat "$SLOTS/ota-version" 2>/dev/null || echo "")
	if [ "$RVER" = "$CVER" ]; then
		log "已是最新版本（$CVER）✓"
	elif [ -z "$CVER" ]; then
		log "本地没有版本记录 → 可以升级到 $RVER ✓"
	else
		# 版本串按字典序比较（约定用 YYYYMMDD-N 格式 ✓ 单调递增 ✓）
		if [ "$RVER" \> "$CVER" ]; then
			log "发现新版本: $CVER → $RVER ✓"
		else
			die "远端版本 $RVER **不大于**本地 $CVER → 拒绝降级 ✗"
		fi
	fi
	[ -n "$RMIN" ] && log "（清单要求最低版本 $RMIN）"
	log "待升级文件: $RFILE  大小 $RSIZE  源 $FOUND_BASE"
	log "════ 检查完成 ✓（用 'ota-client.sh update' 执行升级）════"
}

# ---------------------------------------------------------------- update
do_update() {
	mkdir -p "$STAGE"
	log "════ OTA 升级开始 $(date 2>/dev/null) ════"
	do_check || die "检查阶段未通过，不升级 ✗"

	RVER=$(mget version); RSIZE=$(mget size); RSUM=$(mget sha256); RFILE=$(mget file)
	TARGET=$(inactive_slot)
	log "目标槽位: $TARGET（当前活动槽 $(active_slot) 完全不动 ✓）"

	# ---- 下载（断点续传 ✓ 公网实测 0.25MB/s + WiFi 会掉线 ✗ 必须能续 ✓）----
	DL="$STAGE/$RFILE.part"
	try=0
	while :; do
		try=$((try+1))
		log "下载尝试 #$try: $FOUND_BASE/$RFILE"
		wget -c -T 60 -O "$DL" "$FOUND_BASE/$RFILE" 2>/dev/null
		SZ=$(wc -c < "$DL" 2>/dev/null || echo 0)
		log "  已下载 $SZ / $RSIZE 字节"
		[ "$SZ" = "$RSIZE" ] && break
		if [ "$try" -ge 5 ]; then
			die "下载失败（已重试 $try 次，$SZ/$RSIZE 字节）✗ 可稍后再跑本命令**继续续传** ✓"
		fi
		log "  未完成，10 秒后续传…（断点续传 ✓ 不会从头再来 ✓）"
		sleep 10
	done

	# ---- 校验完整性 ✓ ----
	SUM=$(sha256sum "$DL" | cut -d' ' -f1)
	if [ "$SUM" != "$RSUM" ]; then
		rm -f "$DL"
		die "sha256 不匹配 ✗（下载损坏，已删除临时文件，请重试）"
	fi
	log "✅ sha256 校验通过 ✓"

	# ---- 写非活动槽 ----
	if [ "$TARGET" = "b" ]; then
		IMG="$SLOTS/rootfs-b.ext4"
		# 是 .gz 就边解压边写；否则直接写 ✓
		case "$RFILE" in
			*.gz)
				log "解压写入 $IMG（镜像文件 ✓）"
				gunzip -c "$DL" > "$IMG.new" || die "解压失败 ✗"
				mv -f "$IMG.new" "$IMG" ;;
			*)
				log "直接写入 $IMG"
				cp -f "$DL" "$IMG.new" && mv -f "$IMG.new" "$IMG" ;;
		esac
		[ -f "$IMG" ] || die "写入 $IMG 失败 ✗"
		log "✅ 已写入 b 槽镜像 ✓（大小 $(wc -c < "$IMG") 字节）"
		# 挂一下确认它是有效 ext4 且含 /sbin/init ✓
		if losetup /dev/loop0 "$IMG" 2>/dev/null; then
			mkdir -p /tmp/chk
			if mount -t ext4 -o ro /dev/loop0 /tmp/chk 2>/dev/null; then
				[ -x /tmp/chk/sbin/init ] && log "✅ 镜像校验通过（含可执行 /sbin/init ✓）" || die "镜像里没有 /sbin/init ✗"
				umount /tmp/chk
			else
				losetup -d /dev/loop0 2>/dev/null
				die "镜像**挂载失败** ✗（不是有效 ext4，拒绝切换 ✗）"
			fi
			losetup -d /dev/loop0 2>/dev/null
		else
			die "losetup 失败 ✗"
		fi
	else
		die "a 槽不支持直接写入 ✗（a 槽就是 p2 本体；请先把系统跑在 b 槽，或用镜像方式升级）"
	fi

	# ---- 记录版本 + 切槽 ----
	echo "$RVER" > "$SLOTS/ota-version.new"
	echo "1" > "$SLOTS/tries"            # 试用计数从 1 开始 ✓（rootfs 里确认成功后清零 ✓）
	mv -f "$SLOTS/ota-version.new" "$SLOTS/ota-version"
	echo "$TARGET" > "$SLOTS/active.new"
	mv -f "$SLOTS/active.new" "$SLOTS/active"
	sync
	log "✅ 已切到 $TARGET 槽（版本 $RVER）✓"
	log "════ 升级就绪：**重启后生效** ════"
	log "  重启后 initramfs 会从 $TARGET 槽启动 ✓"
	log "  若启动成功 → S99otaconfirm 写入 confirmed.txt、tries 清零 ✓"
	log "  若连续 3 次未确认 → initramfs **自动回退**到另一个槽 ✓✓"
	log "  立即重启: reboot"
}

case "${1:-}" in
	check)  do_check ;;
	update) do_update ;;
	status)
		echo "活动槽   : $(active_slot)"
		echo "非活动槽 : $(inactive_slot)"
		echo "版本     : $(cat "$SLOTS/ota-version" 2>/dev/null || echo '(未记录)')"
		echo "tries    : $(cat "$SLOTS/tries" 2>/dev/null || echo -)"
		echo "confirmed: $(cat "$SLOTS/confirmed.txt" 2>/dev/null | tr '\n' ' ')"
		echo "boot-info: $(cat "$SLOTS/boot-info.txt" 2>/dev/null | tr '\n' ' ')"
		echo "b 槽镜像 : $(ls -l "$SLOTS/rootfs-b.ext4" 2>/dev/null | awk '{print $5" 字节"}' || echo '无')"
		;;
	*) sed -n '3,12p' "$0"; exit 1 ;;
esac
