/*
 * 第 46 章　并发竞争测试程序（用户态）
 *
 * 用法：
 *   ./racetest /dev/beep                 只读一行：<切换次数> <状态> <保护方式>
 *   ./racetest /dev/beep 2 200           2 个进程各切换 200 次（静音，默认）
 *   ./racetest /dev/beep 4 100 -a        4 个进程各 100 次，并且真的来回切换（会响）
 *
 * 判据：
 *   期望增量 = 进程数 × 每人次数；实际增量 = 驱动里的计数差。
 *   相等 → 没有丢更新；小于 → 有竞争（临界区被抢占/打断）。
 *
 * 为什么默认写 0：写 0 = 静音电平（dts 里 beep-gpio 是 ACTIVE_LOW），
 * 这样测试不会把蜂鸣器一直弄响；但 write() 依然走完整的临界区，
 * 竞争照样发生 —— 我们测的是那个计数，不是 GPIO。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/time.h>

static long long now_ms(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* 读驱动那一行，取出第一个数字（切换次数） */
static unsigned long read_count(const char *dev, char *line, int n)
{
	int fd, len;
	unsigned long v = 0;

	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		perror("open(dev) for read");
		return 0;
	}
	len = read(fd, line, n - 1);
	if (len < 0)
		len = 0;
	line[len] = 0;
	close(fd);
	sscanf(line, "%lu", &v);
	return v;
}

int main(int argc, char *argv[])
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/beep";
	int nproc = (argc > 2) ? atoi(argv[2]) : 0;
	int ntimes = (argc > 3) ? atoi(argv[3]) : 200;
	int audible = (argc > 4 && !strcmp(argv[4], "-a"));
	char line[128];
	unsigned long before, after, expect, got;
	long long t0, t1;
	int i;

	if (nproc <= 0) {                       /* 只读一行 */
		read_count(dev, line, sizeof(line));
		printf("%s", line);
		return 0;
	}

	before = read_count(dev, line, sizeof(line));
	printf("起始: %s", line);
	fflush(stdout);

	t0 = now_ms();
	for (i = 0; i < nproc; i++) {
		pid_t pid = fork();
		if (pid == 0) {
			int fd, k;
			unsigned char v = 0;

			fd = open(dev, O_RDWR);
			if (fd < 0) {
				perror("open(dev)");
				_exit(1);
			}
			for (k = 0; k < ntimes; k++) {
				if (audible)
					v = (unsigned char)(k & 1);
				else
					v = 0;
				if (write(fd, &v, 1) < 0) {
					perror("write");
					_exit(1);
				}
			}
			close(fd);
			_exit(0);
		}
	}
	for (i = 0; i < nproc; i++)
		wait(NULL);
	t1 = now_ms();

	after = read_count(dev, line, sizeof(line));
	printf("结束: %s", line);

	expect = (unsigned long)nproc * (unsigned long)ntimes;
	got = after - before;

	printf("\n进程数=%d  每人次数=%d  期望增量=%lu  实际增量=%lu  耗时=%lld ms\n",
	       nproc, ntimes, expect, got, t1 - t0);
	if (got == expect)
		printf("✅ 计数正确：没有丢更新（保护生效）\n");
	else if (got < expect)
		printf("❌ 丢了 %lu 次更新 → 临界区被抢占/打断（竞争发生了）\n",
		       expect - got);
	else
		printf("⚠️ 多了 %lu 次（比期望还多：检查是否别处也在计数）\n",
		       got - expect);

	return (got == expect) ? 0 : 1;
}
