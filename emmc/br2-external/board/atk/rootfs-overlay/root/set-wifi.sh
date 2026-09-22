#!/bin/sh
#
# set-wifi.sh —— 在板子上现场配 WiFi，不用重新编 rootfs
#
#     /root/set-wifi.sh "SSID" "密码"
#     /root/set-wifi.sh --show          # 看当前配了哪些 network
#
# 原理：wpa_passphrase 生成 psk= 哈希，明文密码不落盘。
#
set -e
CONF=/etc/wpa_supplicant.conf

if [ "$1" = "--show" ] || [ $# -eq 0 ]; then
	echo "当前 $CONF:"
	cat "$CONF"
	exit 0
fi

SSID="$1"
PSK="$2"
[ -n "$SSID" ] && [ -n "$PSK" ] || {
	echo "用法: $0 \"SSID\" \"密码\""
	exit 1
}

# 保留头部（ctrl_interface 等），追加新 network
if grep -q "^network=" "$CONF" 2>/dev/null; then
	echo "⚠️ $CONF 里已有 network，先备份为 $CONF.bak"
	cp "$CONF" "$CONF.bak"
	sed -i '/^network=/,$d' "$CONF"
fi

wpa_passphrase "$SSID" "$PSK" >>"$CONF"
echo "✅ 已写入 $CONF："
cat "$CONF"

/etc/init.d/S45wifi restart
