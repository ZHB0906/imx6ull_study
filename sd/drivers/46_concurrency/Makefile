# 第 46 章　并发与竞争 —— Makefile
#
# 一份源码、编译期开关选保护方式：
#     make KIND=0   无保护（示范竞争）
#     make KIND=1   原子操作
#     make KIND=2   自旋锁
#     make KIND=3   信号量
#     make KIND=4   互斥体
# 产物都叫 beep_lock.ko（模块名相同，所以同一时刻只能 insmod 一个）。
#
# 【坑复述】编模块必须显式 -fno-pic -fno-PIE（Ubuntu 的 arm-linux-gnueabihf-gcc
# 默认 PIE，老内核编模块会漏进 PIC → insmod 报 Unknown symbol _GLOBAL_OFFSET_TABLE_）

KERNELDIR := /home/zhb/linux-projects/linux/IMX6ULL/linux-imx
CURRENT_PATH := $(shell pwd)

ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-
KIND ?= 0

obj-m := beep_lock.o

ccflags-y += -fno-pic -fno-PIE -DKIND=$(KIND)
CFLAGS_beep_lock.o += -fno-pic -fno-PIE -DKIND=$(KIND)

build: kernel_modules

kernel_modules:
	$(MAKE) -C $(KERNELDIR) M=$(CURRENT_PATH) \
		ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		HOSTCC="gcc -fcommon" \
		modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(CURRENT_PATH) \
		ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		HOSTCC="gcc -fcommon" \
		clean
