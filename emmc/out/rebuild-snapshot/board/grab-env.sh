export PATH=/sbin:/usr/sbin:/bin:/usr/bin
echo "# U-Boot 环境变量完整快照（fw_printenv）"
echo "# 抓取时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo
fw_printenv 2>/dev/null | sort
