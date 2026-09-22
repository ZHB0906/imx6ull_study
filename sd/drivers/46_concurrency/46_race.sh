#!/bin/sh
# ============================================================
#  第 46 章　五个变体横向对比（🐧 板子上运行）
#
#  用法：
#      sh /mnt/nfs/root/46_race.sh              # 默认 2 进程 × 200 次
#      sh /mnt/nfs/root/46_race.sh 4 300        # 4 进程 × 300 次
#
#  每个变体跑两轮：
#    ① 竞争复现：insmod windows_ms=2  → 临界区窗口拉长，没保护的版本必丢更新
#    ② 基准测量：insmod windows_ms=0  → 窗口关掉，纯看锁本身的开销（2×5000 次写）
#
#  结果同时存到 /tmp/46_race.log
# ============================================================

NFS_ROOT=/mnt/nfs/root
NP=${1:-2}
NT=${2:-200}
BENCH_N=5000
LOG=/tmp/46_race.log

NAMES="无保护 原子操作 自旋锁 信号量 互斥体"

bad()  { echo "  ❌ $1"; }
step() { echo; echo "=== $1 ==="; }

[ -d "$NFS_ROOT" ] || { echo "❌ 先挂 NFS"; exit 1; }

: > $LOG

rmmod beep_lock 2>/dev/null
rmmod beep 2>/dev/null

SUMMARY=""

for k in 0 1 2 3 4; do
	NAME=$(echo $NAMES | cut -d' ' -f$((k + 1)))
	step "KIND=$k（$NAME）"

	if [ ! -f "$NFS_ROOT/beep_lock$k.ko" ]; then
		bad "找不到 beep_lock$k.ko"; continue
	fi

	echo "  ── ① 竞争复现（windows_ms=2，$NP 进程 × $NT 次）──"
	insmod "$NFS_ROOT/beep_lock$k.ko" windows_ms=2 || { bad "insmod 失败"; continue; }
	sleep 1
	OUT=$("$NFS_ROOT/racetest" /dev/beep "$NP" "$NT" 2>&1)
	echo "$OUT" | tee -a $LOG
	RACE_GOT=$(echo "$OUT" | sed -n 's/.*实际增量=\([0-9]*\).*/\1/p')
	rmmod beep_lock; sleep 1

	echo "  ── ② 基准（windows_ms=0，$NP 进程 × $BENCH_N 次）──"
	insmod "$NFS_ROOT/beep_lock$k.ko" windows_ms=0 || { bad "insmod 失败"; continue; }
	sleep 1
	OUT2=$("$NFS_ROOT/racetest" /dev/beep "$NP" "$BENCH_N" 2>&1)
	echo "$OUT2" | tee -a $LOG
	BENCH_MS=$(echo "$OUT2" | sed -n 's/.*耗时=\([0-9]*\) ms.*/\1/p')
	rmmod beep_lock; sleep 1

	[ -z "$RACE_GOT" ] && RACE_GOT="?"
	[ -z "$BENCH_MS" ] && BENCH_MS="?"
	SUMMARY="$SUMMARY
  KIND=$k  $NAME  竞争复现:实际增量=$RACE_GOT(期望 $((NP * NT)))  基准:${BENCH_MS}ms($((NP * BENCH_N)) 次)"
done

step "汇总"
printf "%s\n" "$SUMMARY" | tee -a $LOG

cat <<'EOF'

=== 怎么读这张表 ===
  · 竞争复现：只有 KIND=0（无保护）应该小于期望值 —— 那才叫"丢了更新"；
    KIND=1..4 都应精确等于期望值。
  · 基准：窗口关掉后，差异只来自锁本身开销 ——
    原子操作最快（单条指令），自旋锁次之（不睡眠、忙等+关中断），
    信号量/互斥体最慢（要睡眠、要调度）。
  · KIND=2 临界区里放了 mdelay（本实验为了让竞争稳定复现才这么写）：
    真实驱动里自旋锁临界区必须极短、绝不能睡眠 —— 反面教材。
  · 想听"竞争"是什么样（蜂鸣器真的来回切换）：
        /mnt/nfs/root/racetest /dev/beep 2 100 -a
EOF
echo
echo "完整日志： $LOG"
