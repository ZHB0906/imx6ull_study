# 第 44 章　设备树下的 LED 驱动 —— Makefile
#
# 【坑 1】例程自带的 Makefile 里 KERNELDIR 指向作者的电脑路径：
#     /home/zuozhongkai/linux/IMX6ULL/linux/temp/linux-imx-rel_imx_4.1.15_2.1.0_ga_alientek
#   照抄必然报 "No such file or directory"。这里已改成你自己内核源码树的真实路径。
#
# 【坑 2】例程的 Makefile 没写 ARCH 和 CROSS_COMPILE，直接 make 会报：
#     cc1: error: code model kernel does not support PIC mode
#   因为内核模块也必须交叉编译，不能用宿主 x86 gcc。
#
# 【坑 3】宿主 gcc 11 的 -fno-common 会把老 scripts/dtc 打挂，所以要 HOSTCC="gcc -fcommon"
#   （这条你编内核时已经踩过了，编模块同样需要）
#
# 【坑 4】★ 上板后 insmod 报：
#       dtsled: Unknown symbol _GLOBAL_OFFSET_TABLE_ (err 0)
#   原因：Ubuntu 的 arm-linux-gnueabihf-gcc 是【默认 PIE】编译的
#         （gcc -v 里能看到 --enable-default-pie）。
#         内核源码树的 arch/arm/Makefile 在 4.1.15 里【没有】显式加 -fno-pic，
#         编内核主体时靠的是隐式行为，但编【模块】时 PIC 就漏进来了，
#         于是 .ko 里出现 R_ARM_BASE_PREL / R_ARM_GOT_BREL 这两种 PIC 重定位，
#         还多出一个未定义符号 _GLOBAL_OFFSET_TABLE_，insmod 直接拒绝。
#   修法：给本模块显式加 -fno-pic -fno-PIE。下面 CFLAGS_dtsled.o 就是干这个的。

KERNELDIR := /home/zhb/linux-projects/linux/IMX6ULL/linux-imx
CURRENT_PATH := $(shell pwd)

ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-

obj-m := dtsled.o

# 【坑 4 的修复】禁止位置无关代码
ccflags-y += -fno-pic -fno-PIE
CFLAGS_dtsled.o += -fno-pic -fno-PIE

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
