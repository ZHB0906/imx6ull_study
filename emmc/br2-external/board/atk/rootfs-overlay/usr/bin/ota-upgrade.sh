#!/bin/sh
#
# ota-upgrade.sh —— 给"桌面一键升级按钮"用的**机器可读**包装
#
# 为什么不直接在 Qt 里解析 ota-client.sh 的中文输出 ✗：
#   文案随时会改 ✓ → 界面逻辑就会莫名其妙失效 ✗（而且中文在 Qt 里还要处理编码 ✓）
#   → 这里把结果收敛成**固定 token** ✓，界面只认 token ✓
#
# 用法与输出（★ 每行一个 token，界面只认第一行 ✓）：
#   ota-upgrade.sh check
#       OTA_NOTE <文字>                    ★ 可选，出现在结论之前（如"未验签"警告 ✓）
#       OTA_UP_TO_DATE <版本>              已是最新 ✓
#       OTA_AVAILABLE <当前> <新版本>       有新版本 ✓ 可以升级
#       OTA_BLOCKED_SLOT <当前槽>          在 b 槽：客户端拒绝写 a 槽 ✗（要先回 a 槽 ✓）
#       OTA_ERROR <原因>                   取不到清单 / 验签失败 / 拒绝降级 …
#   ota-upgrade.sh do
#       OTA_NOTE <文字>
#       OTA_PROGRESS <文字>                进度（可能多行 ✓ 界面可显示最后一行 ✓）
#       OTA_DONE <版本>                    升级已写入非活动槽 ✓ 重启后生效 ✓
#       OTA_ERROR <原因>
#   ota-upgrade.sh status
#       OTA_STATUS <运行槽> <active> <本地版本> <tries>
#   ota-upgrade.sh reboot                  重启（进入新槽 ✓）
#
# ★ 安全说明（必须如实告知使用者 ✗）：
#   本脚本内部用 OTA_ALLOW_UNSIGNED=1 **跳过验签** ✓ —— 因为板子上还没有验签工具 ✗。
#   等 /usr/bin/ed25519-verify 或 openssl 就位后，把下面这一行删掉即可恢复 fail-closed ✓。
#
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
SLOTS=/slots
CLIENT=/usr/bin/ota-client.sh
LAB_ALLOW_UNSIGNED=1     # ★ 变成 0 就恢复严格验签（有验签工具后请置 0 ✓）

say() { echo "$*"; }

running_slot() {
	case "$(mount | awk '/ \/ /{print $1}')" in
	*/loop*) echo b ;;
	*) echo a ;;
	esac
}

have_verifier() {
	command -v openssl >/dev/null 2>&1 || [ -x /usr/bin/ed25519-verify ]
}

# 统一的"跑客户端"入口 ✓ —— 把"要不要跳过验签"这件事收在一处 ✗ 免得两处不一致 ✓
run_client() {
	# $1 = check | update
	if [ "$LAB_ALLOW_UNSIGNED" = "1" ] && ! have_verifier; then
		OTA_ALLOW_UNSIGNED=1 "$CLIENT" "$1" 2>&1
	else
		"$CLIENT" "$1" 2>&1
	fi
}

# ★ 跳过了验签就必须**明确告诉用户** ✗（不能悄悄降级安全性 ✗）
note_if_unsigned() {
	if [ "$LAB_ALLOW_UNSIGNED" = "1" ] && ! have_verifier; then
		say "OTA_NOTE ⚠ 实验室模式：板上没有验签工具，本次未做签名校验"
	fi
}

do_check() {
	[ -x "$CLIENT" ] || { say "OTA_ERROR 客户端不存在（$CLIENT）"; exit 1; }

	SLOT=$(running_slot)
	# ★ 在 b 槽时客户端会直接拒绝（a 槽就是 p2 本体，没法整块替换 ✗）
	#   → 在这里就给出明确结论 ✓ 不要让它跑到一半才报错 ✗
	if [ "$SLOT" = "b" ]; then
		say "OTA_BLOCKED_SLOT b"
		exit 3
	fi

	note_if_unsigned
	OUT=$(mktemp 2>/dev/null || echo /tmp/ota-check.$$)
	run_client check >"$OUT" 2>&1
	RC=$?
	if [ "$RC" != "0" ]; then
		say "OTA_ERROR $(tail -1 "$OUT" 2>/dev/null)"
		rm -f "$OUT"
		exit 1
	fi
	rm -f "$OUT"

	CUR=$(cat "$SLOTS/ota-version" 2>/dev/null)
	# ★ 版本号从**客户端暂存的清单**里读 ✓ 不去解析中文输出 ✓
	NEW=$(sed -n 's/^version=//p' "$SLOTS/ota-staging/manifest" 2>/dev/null | head -1)
	NEW=$(echo "$NEW" | tr -d ' \r')

	if [ -z "$NEW" ]; then
		say "OTA_ERROR 没有取到远端版本号"
		exit 1
	fi
	if [ "$NEW" = "$CUR" ]; then
		say "OTA_UP_TO_DATE ${CUR:-未知}"
	else
		say "OTA_AVAILABLE ${CUR:-无} $NEW"
	fi
}

do_do() {
	SLOT=$(running_slot)
	[ "$SLOT" = "b" ] && { say "OTA_BLOCKED_SLOT b"; exit 3; }

	note_if_unsigned
	say "OTA_PROGRESS 正在下载并写入非活动槽（约 1-2 分钟，请勿断电）"

	OUT=$(run_client update)
	RC=$?
	if [ "$RC" != "0" ]; then
		say "OTA_ERROR $(echo "$OUT" | tail -1)"
		exit 1
	fi
	say "OTA_PROGRESS 写入完成，已切换到新槽"
	say "OTA_DONE $(cat "$SLOTS/ota-version" 2>/dev/null)"
}

case "${1:-}" in
check) do_check ;;
do) do_do ;;
status)
	say "OTA_STATUS $(running_slot) $(cat "$SLOTS/active" 2>/dev/null) $(cat "$SLOTS/ota-version" 2>/dev/null) $(cat "$SLOTS/tries" 2>/dev/null)"
	;;
reboot)
	sync
	say "OTA_PROGRESS 重启中…"
	(sleep 1; reboot) >/dev/null 2>&1 &
	;;
*)
	sed -n '2,30p' "$0"
	exit 1
	;;
esac
exit 0
