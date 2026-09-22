/*
 * 第 44 章　LED 测试程序（用户态）
 * 用法：
 *   ./ledtest /dev/dtsled 1     点亮
 *   ./ledtest /dev/dtsled 0     熄灭
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>

#define LEDOFF 0
#define LEDON  1

int main(int argc, char *argv[])
{
	int fd, retvalue;
	char *filename;
	unsigned char databuf[1];

	if (argc != 3) {
		printf("Usage: %s <dev> <0|1>\r\n", argv[0]);
		printf("  e.g. %s /dev/dtsled 1\r\n", argv[0]);
		return -1;
	}

	filename = argv[1];

	fd = open(filename, O_RDWR);
	if (fd < 0) {
		printf("file %s open failed!\r\n", filename);
		return -1;
	}

	databuf[0] = atoi(argv[2]);

	retvalue = write(fd, databuf, sizeof(databuf));
	if (retvalue < 0) {
		printf("LED Control Failed!\r\n");
		close(fd);
		return -1;
	}

	close(fd);
	return 0;
}
