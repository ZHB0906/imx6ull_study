# 第 45 章　pinctrl 和 gpio 子系统实验 —— 蜂鸣器驱动 Makefile
#
# 与第 44 章 Makefile 相比，实质差别只有两处：
#     obj-m        : dtsled.o → beep.o
#     CFLAGS_xxx.o : dtsled.o → beep.o（名字必须和 obj-m 对齐，否则不生效）
# 四个坑的修复原封不动保留，长注释见 drivers/44_dtsled/Makefile。
#
# 【坑 4 复述】★ 编模块必须显式 -fno-pic -fno-PIE
#   Ubuntu 的 arm-linux-gnueabihf-gcc 默认 PIE，内核 4.1.15 的 arch/arm/Makefile
#   没给模块加 -fno-pic，于是 .ko 里出现 R_ARM_GOT_BREL 重定位 + 未定义符号
#   _GLOBAL_OFFSET_TABLE_，insmod 报：
#       beep: Unknown symbol _GLOBAL_OFFSET_TABLE_ (err 0)

KERNELDIR := /home/zhb/linux-projects/linux/IMX6ULL/linux-imx
CURRENT_PATH := $(shell pwd)

ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-

obj-m := beep.o

# 【坑 4 的修复】禁止位置无关代码
ccflags-y += -fno-pic -fno-PIE
CFLAGS_beep.o += -fno-pic -fno-PIE

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
