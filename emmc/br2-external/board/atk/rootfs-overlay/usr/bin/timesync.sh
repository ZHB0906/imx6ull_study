#!/bin/sh
#
# timesync.sh —— 给这块**没有 RTC 电池**的板子自动对时
#
# 背景（实测 ✓）：
#   · 板子没有可用的 RTC 走时 ✗（/dev/rtc0 = snvs-rtc-lp，断电就回到 1970 ✓）
#   · 没有 ntpd / ntpdate / sntp ✗（busybox 里也没编进去 ✗）
#   · 有 rdate ✗ 但公共 RFC868(37) 服务器基本都停了 ✗，而且板上**没有 timeout 命令** ✗
#   · ★ 有 wget ✓、date ✓（支持 -D 解析格式 ✓）、hwclock ✓、date -s ✓
#   → 所以走 **HTTP 响应头里的 Date:** ✓✓ 这条路：
#       任何 HTTP 服务器都会回一个 Date 头 ✓ 我们自己的 OTA 服务器也有 ✓
#       WiFi 通了以后从公网站点取也行 ✓（实测 mirrors.aliyun.com 可用 ✓）
#
# 用法：
#   timesync.sh              尝试对时（最多 3 轮 ✓ 每轮 10s 超时 ✓）
#   timesync.sh --quiet      同上，但只在成功/失败时记日志 ✓（给界面定时重试用 ✓）
#   timesync.sh status       打印当前时间是否可信 ✓
#
# 输出 token（供界面/脚本判断 ✓）：
#   TS_OK <epoch> <可读时间>      对时成功 ✓ 已写入 RTC ✓
#   TS_SKIP <原因>                时间已经可信，不用对 ✓
#   TS_FAIL <原因>                全部源都失败 ✗（不影响任何功能 ✓）
#
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
LOG=/slots/timesync.log
CONF=/etc/ota.conf
# ★ "确实对过时"的标记 ✓✓
#   为什么不能只看"时间大不大" ✗：实测被自己坑过 ——
#   我手动 date -s 设了个**假但看着合理**的时间（2026-01-02 ✗），
#   光靠 ">2020" 这种判断就以为已经对好了 ✗ → 从此再也不对时 ✗
#   → 必须有"我们真的从网络取到过时间"的凭据 ✓
MARK=/slots/time-synced

# 时间可信的下限：2020-01-01 ✓（板子出厂就是 1970 ✗）
MIN_EPOCH=1577836800

ts_log() {
	# 日志超过 8KB 轮转一次 ✓（状态区不能无限长 ✗）
	if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 8192 ]; then
		mv -f "$LOG" "$LOG.1" 2>/dev/null
	fi
	echo "[$(date 2>/dev/null)] $*" >>"$LOG" 2>/dev/null
	echo "[timesync] $*" >/dev/kmsg 2>/dev/null
}

now_epoch() { date +%s 2>/dev/null || echo 0; }

# 时间是否已经可信 ✓：① 有过成功对时的标记 ✓ ② 当前时间没跑回 1970 之前 ✓
time_ok() {
	[ -f "$MARK" ] || return 1
	[ "$(now_epoch)" -ge "$MIN_EPOCH" ] 2>/dev/null
}

# 从 URL 列表里挑候选（★ 复用 /etc/ota.conf 的 URLS ✓ 一台服务器就够 ✓）
candidates() {
	# 自己的 OTA 服务器（最稳 ✓ 局域网/网线都在 ✓）
	sed -n '/^URLS=/,/^"/p' "$CONF" 2>/dev/null | grep -oE 'https?://[^ "]+' | sed 's#/ota$##'
	# 公网兜底（WiFi 通了才有效 ✓ 实测可用 ✓）
	echo "http://mirrors.aliyun.com"
	echo "http://www.baidu.com"
	echo "http://connect.rom.miui.com/generate_204"
}

# 用 HTTP 的 Date 头对时 ✓ —— 成功打印 epoch ✓
try_http_date() {
	url="$1"
	# ★ 板上没有 timeout ✗ → 用 wget 自带的 -T ✓
	hdr=$(wget -S -O /dev/null -T 10 "$url" 2>&1 | grep -i '^ *Date:' | head -1)
	[ -n "$hdr" ] || return 1
	d=$(echo "$hdr" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
	[ -n "$d" ] || return 1
	e=$(date -D '%a, %d %b %Y %H:%M:%S GMT' -d "$d" +%s 2>/dev/null)
	[ -n "$e" ] || return 1
	# 合理性：必须在 2020 之后 ✓ 且别超过 2100（防垃圾数据 ✗）
	[ "$e" -ge "$MIN_EPOCH" ] 2>/dev/null || return 1
	[ "$e" -le 4102444800 ] 2>/dev/null || return 1
	echo "$e"
}

apply_epoch() {
	e="$1"
	# ★ 用"格式化好的字符串"去 set ✓ —— 比 date -s @epoch 更稳 ✓（实测这条能work ✓）
	s=$(date -u -d "@$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	[ -n "$s" ] || return 1
	date -u -s "$s" >/dev/null 2>&1 || return 1
	# 写入 SNVS RTC ✓ → 下次开机内核会自动恢复（dmesg 里有 "setting system clock to ..." ✓）
	hwclock -w >/dev/null 2>&1
	# 留下"确实对过时"的凭据 ✓（这样假的合理时间骗不过我们 ✓）
	echo "$e" >"$MARK" 2>/dev/null
	return 0
}

QUIET=0
[ "$1" = "--quiet" ] && QUIET=1

case "$1" in
status)
	if time_ok; then
		echo "TS_OK $(now_epoch) $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	else
		echo "TS_FAIL 时间不可信（$(date -u '+%Y-%m-%d %H:%M:%S UTC')，从未成功对时）"
	fi
	exit 0
	;;
esac

# 已经准了就不折腾 ✓（幂等 ✓ 界面每 5 分钟调一次也不会有副作用 ✓）
if time_ok; then
	[ "$QUIET" = "1" ] || echo "TS_SKIP 时间已可信（$(date -u '+%Y-%m-%d %H:%M:%S UTC')）"
	exit 0
fi

i=0
while [ "$i" -lt 3 ]; do
	i=$((i + 1))
	for u in $(candidates); do
		e=$(try_http_date "$u") || continue
		if apply_epoch "$e"; then
			ts_log "✅ 对时成功（源 $u）→ $(date -u '+%Y-%m-%d %H:%M:%S UTC') ✓ 已写入 RTC ✓"
			echo "TS_OK $e $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
			exit 0
		fi
		ts_log "取到时间但设置失败（源 $u）"
	done
	[ "$i" -lt 3 ] && sleep 5
done

ts_log "✗ 对时失败（试过 $(candidates | wc -l) 个源 ×3 轮）—— 不影响任何功能 ✓"
echo "TS_FAIL 所有时间源都取不到（WiFi/网络还没通？）"
exit 1
