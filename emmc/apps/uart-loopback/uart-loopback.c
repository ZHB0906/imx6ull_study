/*
 * uart-loopback —— 打开/关闭 i.MX6ULL UART 的"内部回环"，用于无硬件自测
 *
 * 背景：
 *   i.MX 的 UART 有 UTS 寄存器，UTS_LOOP(1<<12) = "Loop tx and rx"，
 *   内核 drivers/tty/serial/imx.c 里：
 *       imx_get_mctrl(): if (readl(...uts_reg) & UTS_LOOP) tmp |= TIOCM_LOOP;
 *       imx_set_mctrl(): if (mctrl & TIOCM_LOOP) temp |= UTS_LOOP;
 *   所以只要用 TIOCMBIS 把 TIOCM_LOOP 置上，TX 就会在芯片内部绕回 RX ——
 *   不需要把 TX/RX 用杜邦线短接，也不需要第二台设备。
 *
 * 用途：SerialTool 的串口收发与波形性能测试，全程可远程完成。
 *
 * 用法：
 *   uart-loopback /dev/ttymxc2 on      # 打开回环
 *   uart-loopback /dev/ttymxc2 off     # 关闭回环
 *   uart-loopback /dev/ttymxc2 status  # 查询（TIOCMGET 读回的 TIOCM_LOOP 位）
 *
 * 交叉编译：
 *   arm-linux-gnueabihf-gcc -O2 -o uart-loopback uart-loopback.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <termios.h>
#include <errno.h>

#ifndef TIOCM_LOOP
#define TIOCM_LOOP 0x8000
#endif

/*
 * selftest：单进程完成"设 raw → 开回环 → 写 → 带超时读"，
 * 避免 shell 里并发开 fd / stty 互相干扰（stty 会走 TIOCMSET，
 * 而 imx_set_mctrl 是读改写，会把 UTS_LOOP 清掉）。
 */
static int selftest(const char *dev, int baud)
{
	struct termios tio;
	char buf[256];
	int fd, n, bits, cur, ret = 1;
	fd_set rfds;
	struct timeval tv;
	const char *msg = "HELLO-LOOPBACK-0123456789-END";

	fd = open(dev, O_RDWR | O_NOCTTY);
	if (fd < 0) {
		fprintf(stderr, "打不开 %s: %s\n", dev, strerror(errno));
		return 1;
	}

	/* 1) 先设 termios（必须早于开回环，否则 mctrl 的读改写会清掉 LOOP） */
	if (tcgetattr(fd, &tio) < 0) { perror("tcgetattr"); goto out; }
	cfmakeraw(&tio);
	cfsetispeed(&tio, baud);
	cfsetospeed(&tio, baud);
	tio.c_cflag |= (CLOCAL | CREAD);
	tio.c_cc[VMIN] = 0;
	tio.c_cc[VTIME] = 5;      /* 0.5s 读超时 */
	if (tcsetattr(fd, TCSANOW, &tio) < 0) { perror("tcsetattr"); goto out; }
	printf("  termios: raw, 115200 baud (cfsetispeed 用的是 B115200=%d)\n", baud);

	/* 2) 开回环 */
	bits = TIOCM_LOOP;
	if (ioctl(fd, TIOCMBIS, &bits) < 0) { perror("TIOCMBIS"); goto out; }
	if (ioctl(fd, TIOCMGET, &cur) < 0) { perror("TIOCMGET"); goto out; }
	printf("  回环位: %s\n", (cur & TIOCM_LOOP) ? "ON" : "OFF");

	/* 3) 清空输入缓冲，写 */
	tcflush(fd, TCIFLUSH);
	n = write(fd, msg, strlen(msg));
	printf("  已写 %d 字节: \"%s\"\n", n, msg);
	if (n < 0) { perror("write"); goto out; }

	/* 4) 带超时读 */
	FD_ZERO(&rfds);
	FD_SET(fd, &rfds);
	tv.tv_sec = 2; tv.tv_usec = 0;
	if (select(fd + 1, &rfds, NULL, NULL, &tv) <= 0) {
		printf("  ❌ 2 秒内没有收到任何数据 —— 内部回环没生效\n");
		goto out;
	}
	n = read(fd, buf, sizeof(buf) - 1);
	if (n < 0) { perror("read"); goto out; }
	buf[n] = 0;
	printf("  ✅ 收到 %d 字节: \"%s\"\n", n, buf);
	if (n == (int)strlen(msg) && memcmp(buf, msg, n) == 0)
		printf("  ✅ 内容与写入完全一致 —— 内部回环可用\n");
	else
		printf("  ⚠️ 内容/长度不一致（可能被截断或串扰）\n");
	ret = 0;
out:
	close(fd);
	return ret;
}

int main(int argc, char **argv)
{
	int fd, bits, cur;
	const char *dev, *cmd;

	if (argc < 3) {
		fprintf(stderr, "用法: %s <串口设备> <on|off|status|selftest>\n", argv[0]);
		fprintf(stderr, "例如: %s /dev/ttymxc2 selftest\n", argv[0]);
		return 2;
	}
	dev = argv[1];
	cmd = argv[2];

	if (strcmp(cmd, "selftest") == 0)
		return selftest(dev, B115200);

	fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "打不开 %s: %s\n", dev, strerror(errno));
		return 1;
	}

	if (strcmp(cmd, "status") == 0) {
		if (ioctl(fd, TIOCMGET, &cur) < 0) {
			fprintf(stderr, "TIOCMGET 失败: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
		printf("TIOCM_LOOP = %s\n", (cur & TIOCM_LOOP) ? "ON (已回环)" : "OFF (未回环)");
		close(fd);
		return 0;
	}

	if (strcmp(cmd, "on") == 0) {
		bits = TIOCM_LOOP;
		if (ioctl(fd, TIOCMBIS, &bits) < 0) {
			fprintf(stderr, "TIOCMBIS(TIOCM_LOOP) 失败: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
	} else if (strcmp(cmd, "off") == 0) {
		bits = TIOCM_LOOP;
		if (ioctl(fd, TIOCMBIC, &bits) < 0) {
			fprintf(stderr, "TIOCMBIC(TIOCM_LOOP) 失败: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
	} else {
		fprintf(stderr, "未知命令 '%s'（要 on / off / status）\n", cmd);
		close(fd);
		return 2;
	}

	/* 回读确认 */
	if (ioctl(fd, TIOCMGET, &cur) == 0)
		printf("%s: TIOCM_LOOP = %s\n", dev, (cur & TIOCM_LOOP) ? "ON (已回环)" : "OFF (未回环)");

	close(fd);
	return 0;
}
