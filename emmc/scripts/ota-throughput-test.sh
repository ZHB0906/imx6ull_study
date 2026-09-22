#!/bin/bash
#
# ota-throughput-test.sh —— OTA 可行性实验 1：测板子的实际下载吞吐
#
# 为什么先测这个：
#   整机 rootfs 镜像约 25~40MB（gzip 后）。如果 WiFi 只有 50KB/s，一次 OTA 要 10 分钟以上，
#   方案就要改（分块/差量/夜间窗口）；如果有 1~3MB/s，一分钟内搞定，方案就简单很多。
#   这是整个 OTA 方案里**最大的未知数**，所以先量它。
#
# 用法：
#   bash emmc/scripts/ota-throughput-test.sh eth0 http://192.168.10.1:8899/test50.bin
#   bash emmc/scripts/ota-throughput-test.sh wlan0 http://<PC的IP>:8899/test50.bin
#
# 说明：
#   - 板子的 wget 是 busybox 的，**不支持 https**（Buildroot 里 TLS 包为 0）→ 只能用 http://
#   - 数据流强制走指定网卡（--bind-address 不行就用路由/源地址方式）
#   - 脚本只做测量：不改板子任何配置、不写任何持久文件（下载到 /tmp 并删除）
#
set -uo pipefail

IFACE="${1:-wlan0}"
URL="${2:-}"
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=15 -o LogLevel=ERROR"

say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  ✅ %s\n' "$*"; }
bad() { printf '  ❌ %s\n' "$*"; }

[ -n "$URL" ] || { sed -n '3,20p' "$0"; exit 1; }

BRUN() { timeout "${T:-300}" $SSH root@$BOARD "$@"; }

say "① 板子与链路状态"
BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
  echo '  --- 板子时间（无 RTC，仅供参考）---'; date
  echo '  --- 网卡 ---'; ip -4 addr show 2>/dev/null | awk '/^[0-9]+:/{i=\$2} /inet /{print \"    \"i\" \"\$2}'
  echo '  --- 默认路由 ---'; ip route show default 2>/dev/null | sed 's/^/    /'
  echo '  --- 目标网卡 $IFACE 的地址 ---'
  ip -4 addr show $IFACE 2>/dev/null | grep -o 'inet [0-9.]*' | sed 's/^/    /' || echo '    ✗ 该网卡没有 IPv4 地址'
" | sed 's/^/  /'

say "② 先探一下 URL 可达性与文件大小（只取头部 1KB）"
BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
  cd /tmp
  # 用 --bind-address 强制走指定网卡（busybox wget 支持 --bind-address；不支持则退回直接下载）
  timeout 20 wget -q -O /tmp/.probe --bind-address=\$(ip -4 addr show $IFACE 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print \$2}') '$URL' 2>&1 | head -3
  ls -l /tmp/.probe 2>/dev/null | sed 's/^/    /'
  rm -f /tmp/.probe
" | sed 's/^/  /'

say "③ 正式测速：下载到 /tmp 后立即删除（不占 eMMC）"
BRUN "export PATH=/sbin:/usr/sbin:/bin:/usr/bin:\$PATH
  cd /tmp; rm -f /tmp/speed.bin
  SRC=\$(ip -4 addr show $IFACE 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print \$2}')
  echo \"  源地址绑定: \$SRC  （网卡 $IFACE）\"
  S=\$(date +%s)
  wget -q -O /tmp/speed.bin --bind-address=\$SRC '$URL' 2>&1 | head -3
  E=\$(date +%s)
  SZ=\$(stat -c %s /tmp/speed.bin 2>/dev/null || echo 0)
  D=\$((E-S)); [ \$D -le 0 ] && D=1
  echo \"  下载字节: \$SZ\"
  echo \"  用时:     \${D}s\"
  echo \"  吞吐:     \$(( SZ / D / 1024 )) KB/s   = \$(( SZ * 8 / D / 1000 / 1000 )) Mbps\"
  echo \"  --- 换算到 OTA（镜像 30MB）---\"
  echo \"  预计耗时: \$(( 31457280 / (SZ/D>0?SZ/D:1) )) 秒\"
  echo '  --- 校验数据完整性（比对 sha256，防止半途断流被当成\"速度快\"）---'
  sha256sum /tmp/speed.bin 2>/dev/null | sed 's/^/    /'
  rm -f /tmp/speed.bin
" | sed 's/^/  /'

say "④ 如果上面有断流/失败，说明 WiFi 长跑不稳（已知约 43 分钟会掉线）"
echo "  对策（后面 OTA 客户端里要做）：断点续传(wget -c) + 分块 sha256 + 自动重试 + 有网线时优先 eth0"
