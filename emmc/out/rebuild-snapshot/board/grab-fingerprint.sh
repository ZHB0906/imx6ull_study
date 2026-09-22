export PATH=/sbin:/usr/sbin:/bin:/usr/bin
echo "# 当前板子关键产物指纹（重建后拿来逐项对比）"
echo "# 抓取时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "# 槽位=$(cat /slots/active) 版本=$(cat /slots/ota-version) 根=$(mount | awk '/ \/ /{print $1}')"
echo "# 内核=$(uname -r) 构建时间=$(uname -v)"
echo
echo "## p1 启动产物"
mkdir -p /mnt/p1 && mount /dev/mmcblk1p1 /mnt/p1 2>/dev/null && {
 for f in zImage initrd imx6ull-14x14-emmc-7-1024x600-c.dtb otaboot; do
 [ -f "/mnt/p1/$f" ] && printf "%-46s %s\n" "$f" "$(md5sum "/mnt/p1/$f" | cut -d' ' -f1)"
 done
 umount /mnt/p1
}
echo
echo "## rootfs 关键产物"
for f in opt/launcher/launcher opt/serialtool/SerialTool usr/bin/ota-client.sh usr/bin/ota-upgrade.sh usr/bin/timesync.sh etc/init.d/S99otaconfirm etc/init.d/S97timesync etc/init.d/S39eth0 opt/launcher/session.sh etc/ota.conf etc/ota-pub.pem; do
 [ -f "/$f" ] && printf "%-46s %s\n" "$f" "$(md5sum "/$f" | cut -d' ' -f1)"
done
