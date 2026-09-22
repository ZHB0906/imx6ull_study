#!/bin/sh


# Start all init scripts in /etc/init.d
# executing them in numerical order.
#
# ★ 临时插桩版（只为查清 S99otaconfirm 为什么没被调用 ✗，查完要还原 ✓）：
#   每轮循环都把脚本名写到内核日志 + /slots/rcs-trace.log ✓
#   内核日志是首选 ✓：rcS 早期 /slots 可能还没挂 ✓，/dev/kmsg 一定在 ✓
for i in /etc/init.d/S??* ;do

     echo "[rcS-trace] 准备执行: $i $1" > /dev/kmsg 2>/dev/null
     echo "$i $1 (exists=$([ -f "$i" ] && echo y || echo n))" >> /slots/rcs-trace.log 2>/dev/null

     # Ignore dangling symlinks (if any).
     [ ! -f "$i" ] && continue

     case "$i" in
	*.sh)
	    # Source shell script for speed.
	    (
		trap - INT QUIT TSTP
		set start
		. $i
	    )
	    ;;
	*)
	    # No sh extension, so fork subprocess.
	    $i start
	    ;;
    esac
     echo "[rcS-trace] 执行完毕: $i 返回码=$?" > /dev/kmsg 2>/dev/null
done
echo "[rcS-trace] rcS 循环全部结束 ✓" > /dev/kmsg 2>/dev/null
