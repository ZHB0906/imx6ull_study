/*
 * 第 45 章　蜂鸣器测试程序（用户态）
 *
 * 用法：
 *   ./beepTest /dev/beep 1           响（一直响，直到写 0 或 close/release）
 *   ./beepTest /dev/beep 0           静音
 *   ./beepTest /dev/beep 1 500       响 500 毫秒后自动停（省得你手忙脚乱敲第二条命令）
 *
 * 注意和 LED 一样，走的是 write() 不是 ioctl()：
 * 驱动里的 fops 只实现了 write，传 1 字节逻辑值（1=响，0=静音）。
 * 物理电平由设备树 GPIO_ACTIVE_LOW 决定，用户态不需要知道。
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

#define BEEPOFF 0
#define BEEPON  1

static int beep_write(int fd, unsigned char val)
{
	int ret;

	ret = write(fd, &val, 1);
	if (ret < 0) {
		printf("Beep Control Failed!\r\n");
		return -1;
	}
	return 0;
}

int main(int argc, char *argv[])
{
	int fd, ms = 0;
	char *filename;
	unsigned char databuf[1];

	if (argc != 3 && argc != 4) {
		printf("Usage: %s <dev> <0|1> [ms]\r\n", argv[0]);
		printf("  e.g. %s /dev/beep 1       响\r\n", argv[0]);
		printf("       %s /dev/beep 0       静音\r\n", argv[0]);
		printf("       %s /dev/beep 1 500   响 500ms 后自动停\r\n", argv[0]);
		return -1;
	}

	filename = argv[1];

	fd = open(filename, O_RDWR);
	if (fd < 0) {
		printf("file %s open failed!\r\n", filename);
		return -1;
	}

	databuf[0] = atoi(argv[2]);
	if (argc == 4)
		ms = atoi(argv[3]);

	if (beep_write(fd, databuf[0]) < 0) {
		close(fd);
		return -1;
	}

	if (ms > 0 && databuf[0] == BEEPON) {
		/* 定时响：睡 ms 毫秒再写 0。驱动里没有定时器，这是最朴素的"响一会儿" */
		usleep(ms * 1000);
		if (beep_write(fd, BEEPOFF) < 0) {
			close(fd);
			return -1;
		}
	}

	close(fd);
	return 0;
}
