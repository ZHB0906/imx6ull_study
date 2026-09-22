# 第 44 章　设备树下的 LED 驱动

> **目标**：把 LED 从"内核自带 gpio-leds 驱动管理"换成"自己写的驱动控制"
> **板子**：I.MX6U-ALPHA EMMC 版 + ATK-7016（7 寸 1024×600）
> **内核**：linux-imx 4.1.15（`4.1.15-ge48931b1-dirty`）
> **教材**：《I.MX6U 嵌入式 Linux 驱动开发指南 V2.0.1》第 44 章 p1150
> **参考例程**：`01_source_code/02_Linux_qudong/04_dtsled/`
> **工作目录**：`~/linux-projects/drivers/44_dtsled/`

---

# 一、这一章在干什么

**改之前**：设备树里 `led1` 的 `compatible = "gpio-leds"`，内核自带的 `leds-gpio` 驱动
自动接管，于是 `/sys/class/leds/my-led` 出现，可以通过 sysfs 控制。

**改之后**：我们给 LED 写一个**自己的字符设备驱动** `dtsled`，提供 `/dev/dtsled`，
用户态 `write` 一个字节就能控制亮灭。

**为什么要做**：这是"**设备树怎么和驱动挂钩**"的第一课 ——
`compatible` 字符串怎么匹配 → `probe`/`init` 怎么被调用 → 怎么从设备树取资源。
第 45 章（pinctrl/gpio 子系统）、第 55 章（platform 驱动）都建立在这个基础上。

---

# 二、和例程的两处重要差异（先看这里！）

## 差异 1：例程直接操作寄存器，我们改用 gpiolib

`04_dtsled/dtsled.c` 的做法是 `of_iomap` 映射 **5 个寄存器**，然后手工配置：

```c
IMX6U_CCM_CCGR1    = of_iomap(nd, 0);   /* 时钟 */
SW_MUX_GPIO1_IO03  = of_iomap(nd, 1);   /* 引脚复用 */
SW_PAD_GPIO1_IO03  = of_iomap(nd, 2);   /* 引脚电气属性 */
GPIO1_DR           = of_iomap(nd, 3);   /* 数据寄存器 */
GPIO1_GDIR         = of_iomap(nd, 4);   /* 方向寄存器 */
```

**问题**：这套写法要求设备树的 `reg` 属性按固定顺序列出这 5 个寄存器地址，
而且会**和内核的 pinctrl/gpio 子系统打架**（内核已经管着这些引脚了，你再手工改一遍，
状态就乱了）。

**我们的做法**：用 gpiolib，只申请 GPIO + 控制电平；引脚复用交给设备树的 pinctrl：

```c
dtsled.led_gpio = of_get_named_gpio(dtsled.nd, "led-gpio", 0);
gpio_request(dtsled.led_gpio, "led");
gpio_direction_output(dtsled.led_gpio, 1);
gpio_set_value(dtsled.led_gpio, 0);   /* 点亮 */
```

**这是第 45 章的正统写法，也是实际项目里的做法。** 例程那种写法只在教学演示时出现。

## 差异 2：Makefile 少了两样东西

例程的 Makefile：

```makefile
KERNELDIR := /home/zuozhongkai/linux/IMX6ULL/linux/temp/linux-imx-...  # 作者的电脑！
kernel_modules:
	$(MAKE) -C $(KERNELDIR) M=$(CURRENT_PATH) modules                  # 没写 ARCH/CROSS_COMPILE
```

**两个坑**：

| 坑 | 报错 |
|---|---|
| 路径是作者的 | `No such file or directory` |
| 没写 `ARCH`/`CROSS_COMPILE` | `cc1: error: code model kernel does not support PIC mode` |

我们工作目录里的 Makefile 已经修好了（还加了 `HOSTCC="gcc -fcommon"`，
避开宿主 gcc 11 打挂老 `scripts/dtc` 的坑）。

---

# 三、设备树改动（已改好）

文件：`~/linux-projects/linux/IMX6ULL/linux-imx/arch/arm/boot/dts/imx6ull-14x14-evk.dts`

## ① 关掉原来的 gpio-leds 节点（第 128 行）

```dts
	leds {
		compatible = "gpio-leds";
		status = "disabled";	/* 第44章实验：让自定义 dtsled 驱动独占这个LED */
		...
	};
```

> **为什么必须关**：LED 用的是 GPIO1_IO03，如果 `gpio-leds` 还占着，
> 我们的 `gpio_request` 会返回 `-EBUSY`，驱动加载失败。

## ② 根节点下新增 `/alphaled` 节点（第 21 行起）

```dts
	/* 第44章实验：设备树下的LED驱动测试节点 */
	alphaled {
		#address-cells = <1>;
		#size-cells = <1>;
		compatible = "atkalpha-led";
		status = "okay";
		pinctrl-names = "default";
		pinctrl-0 = <&pinctrl_gpio_leds>;
		led-gpio = <&gpio1 3 GPIO_ACTIVE_LOW>;
	};
```

**逐行解释**：

| 属性 | 作用 |
|---|---|
| `compatible = "atkalpha-led"` | 驱动的"身份证"，驱动靠它认领这个节点 |
| `status = "okay"` | 启用；改 `disabled` 就等于拔掉这个设备 |
| `pinctrl-0 = <&pinctrl_gpio_leds>` | **关键**：复用引脚给这个节点。`pinctrl_gpio_leds` 里已经写好 `MX6UL_PAD_GPIO1_IO03__GPIO1_IO03 0x17059` |
| `led-gpio = <&gpio1 3 GPIO_ACTIVE_LOW>` | 用哪个 GPIO。`&gpio1` + 第 3 脚 + 低电平有效 |

> **低电平有效**：`GPIO_ACTIVE_LOW` 表示"逻辑 1 = 物理低电平"。
> 所以代码里点亮要 `gpio_set_value(gpio, 0)` —— 这是最容易写反的地方。

## ③ 编译（已验证通过）

```bash
cd ~/linux-projects/linux/IMX6ULL/linux-imx
export PATH=$HOME/linux-projects/toolchain/gcc9/bin:$PATH

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- HOSTCC="gcc -fcommon" \
     imx6ull-14x14-emmc-7-1024x600-c.dtb -j4
```

**判据**：

```bash
fdtget arch/arm/boot/dts/imx6ull-14x14-emmc-7-1024x600-c.dtb /alphaled compatible
# → atkalpha-led

fdtget arch/arm/boot/dts/imx6ull-14x14-emmc-7-1024x600-c.dtb /leds status
# → disabled
```

---

# 四、驱动代码要点

文件：`~/linux-projects/drivers/44_dtsled/dtsled.c`

## 初始化流程（`led_init`）

```c
1. of_find_node_by_path("/alphaled")          /* 找节点 */
2. of_property_read_string(nd, "compatible")  /* 读属性（教学演示） */
3. of_get_named_gpio(nd, "led-gpio", 0)       /* 取 GPIO 编号 */
4. gpio_request() + gpio_direction_output()   /* 申请并配成输出 */
5. alloc_chrdev_region + cdev_init + cdev_add /* 注册字符设备 */
6. class_create + device_create               /* 生成 /dev/dtsled */
```

## 三个易错点（代码里都标了注释）

| # | 易错点 | 后果 |
|---|---|---|
| 1 | 低电平有效写成高电平 | LED 亮灭反了 |
| 2 | `cnt` 不检查就 `copy_from_user` | 用户态传 0 会静默失败 |
| 3 | 错误分支不释放资源 | 卸载模块报错、GPIO 泄漏 |

## 编译（已验证通过）

```bash
cd ~/linux-projects/drivers/44_dtsled
export PATH=$HOME/linux-projects/toolchain/gcc9/bin:$PATH
make
```

**判据**：生成 `dtsled.ko`，约 **8440 字节**，`vermagic` 必须是
`4.1.15-ge48931b1-dirty SMP preempt mod_unload modversions ARMv7 p2v8`
（和板子 `uname -r` 一致，否则 `insmod` 会拒绝加载）。

---

# 五、上板验证

## 前提：内核和 rootfs 都支持模块

| 检查项 | 状态 |
|---|---|
| 内核 `CONFIG_MODULES=y` / `MODULE_UNLOAD=y` / `MODVERSIONS=y` | ✅ 都开 |
| 板子 BusyBox 有 `insmod` / `lsmod` / `rmmod` / `dmesg` | ✅ 都有 |

## 步骤

### ① 让板子用上新的 dtb

新 dtb 要进 SD 卡的 p1 分区。**这次要烧卡**（同上一次的流程）：

```bash
# 🖥️ 虚拟机：把新 dtb 打进镜像
cd ~/linux-projects/linux/imx6ull-out
cp sdcard-my-led.img sdcard-ch44.img
# 然后用和上次相同的 python 脚本，把 p1 里的 dtb 换成新编的这份
```

> 这块可以写个小脚本自动化。注意 ZIP 分区里的 dtb 大小可能变了，
> 这次新 dtb 因为加了 `alphaled` 节点，**大小会变**，所以簇链要重新算 —— 不能再用"原地覆盖"的偷懒办法。

### ② 把 dtsled.ko 和 ledtest 传到板子

三条路选一条：

| 路径 | 做法 |
|---|---|
| **U 盘** | 拷到共享目录 → Windows → U 盘 → 插板子 → `mount /dev/sda1 /mnt` |
| **NFS**（要搭网络） | 拷到 `/nfs/rootfs/` → 板子上直接就在根目录 |
| **重新烧卡** | 直接放进 rootfs 再烧 |

### ③ 加载并测试

```bash
# 🐧 板子上
insmod dtsled.ko
dmesg | tail -20
```

**应该看到**：

```
alphaled node find!
compatible = atkalpha-led
status = okay
led_gpio num = 3
dtsled major=24x, minor=0
```

```bash
ls -l /dev/dtsled          # 应存在
ls /sys/class/leds/        # my-led 应该没了（gpio-leds 被 disable 了）
```

**控制 LED**：

```bash
./ledtest /dev/dtsled 1    # 点亮
./ledtest /dev/dtsled 0    # 熄灭
```

**卸载**：

```bash
rmmod dtsled
```

---

# 六、排错表

| 现象 | 原因 | 解决 |
|---|---|---|
| `alphaled node not find!` | 板子用的还是旧 dtb | 确认烧卡成功、`fdtget` 验证过新 dtb |
| `gpio_request failed` | `gpio-leds` 没关掉，GPIO 被占 | 确认 `/leds` 的 `status = "disabled"` |
| `get led-gpio failed!` | 属性名写错 | 设备树里必须是 `led-gpio`，代码里也是 |
| `insmod: can't insert: Invalid module format` | 模块 `vermagic` 和内核不匹配 | 必须用**这块板子跑的那个内核源码树**编 |
| `insmod: unknown symbol` | 内核配置和编模块时不一致 | 用同一份 `.config` |
| LED 亮灭反了 | 低电平有效写反 | `gpio_set_value` 的 0/1 对调 |
| `code model kernel does not support PIC mode` | Makefile 少了 `ARCH`/`CROSS_COMPILE` | 见本文第二节差异 2 |

---

# 七、和后续章节的衔接

```
第 43 章 p1109  Linux 设备树        ← 概念基础（43.9 OF 函数在 p1141）
第 44 章 p1150  设备树下的 LED 驱动  ← ★ 你在这里
第 45 章 p1162  pinctrl 和 gpio 子系统 ← 搞懂 pinctrl-0 = <&pinctrl_gpio_leds> 那串数
第 46 章 p1194  蜂鸣器实验          ← beep 节点已经现成（gpio5_1）
第 55 章 p1361  设备树下的 platform 驱动 ← 把本章的写法升级成 platform_driver
```

> ⚠️ 主手册 `手动操作完整流程.md` 第 10.6 节的页码表里，第 45 章写成了 p1172、
> 第 46 章写成了 p1195，实际是 **p1162 / p1194**，以本章为准。

---

# 八、文件位置速查

| 内容 | 路径 |
|---|---|
| 驱动源码 | `~/linux-projects/drivers/44_dtsled/dtsled.c` |
| 测试程序 | `~/linux-projects/drivers/44_dtsled/ledApp.c` |
| Makefile | `~/linux-projects/drivers/44_dtsled/Makefile` |
| 编译产物 | 同目录 `dtsled.ko`、`ledtest` |
| 改过的设备树 | `~/linux-projects/linux/IMX6ULL/linux-imx/arch/arm/boot/dts/imx6ull-14x14-evk.dts` |
| 设备树备份（改第44章之前） | `/tmp/evk.dts.before-44` |
| 参考例程 | `共享目录/01_source_code/02_Linux_qudong/04_dtsled/` |

---

# 九、2026-09-14 修正：改成 platform driver（pinctrl 才真正生效）

## 9.1 原来藏着的问题

最早这一版是"纯字符驱动 + `of_find_node_by_path("/alphaled")`"。它能点灯，但
**dts 里的 `pinctrl-0 = <&pinctrl_myled>` 从来没生效过** —— 属于死代码：

```
内核应用 pinctrl 的唯一入口：
    drivers/base/dd.c: really_probe()
        └─ pinctrl_bind_pins()      (drivers/base/pinctrl.c)
              └─ pinctrl_select_state(...)   ← 到这一步才真正写 IOMUX 寄存器

really_probe() 只在【驱动与设备匹配成功】时调用。
纯字符驱动不会去 probe /alphaled 这个节点 → pinctrl 永不生效。
```

那 LED 为什么亮？因为 **U-Boot 恰好提前把 GPIO1_IO03 的 pad 配好了**。实测（加载前）：

```
$ devmem 0x020E02F4        # IOMUXC 里 GPIO1_IO03 的 pad 控制寄存器
0x000010B0                 # ← U-Boot 的值，不是我们 dts 里的 0x17059
```

## 9.2 改法（改动都在 `dtsled.c`）

| # | 原来 | 现在 |
|---|---|---|
| 1 | `static int __init led_init(void)` + `module_init/exit` | `led_probe(struct platform_device *pdev)` / `led_remove` + `module_platform_driver` |
| 2 | `of_find_node_by_path("/alphaled")` | `pdev->dev.of_node`（由 driver core 传进来） |
| 3 | 没有 pinctrl 相关代码 | probe 里显式 `devm_pinctrl_get` → `pinctrl_lookup_state("default")` → `pinctrl_select_state`，并打日志 |
| 4 | 注释记着"低电平点亮" | `of_get_named_gpio_flags` 读 `GPIO_ACTIVE_LOW`，逻辑值与物理电平分开 |
| 5 | 无 `of_match_table` | 新增 `{.compatible = "atkalpha-led"}` —— **这一步是 pinctrl 能生效的前提** |

## 9.3 实测（2026-09-14，NFS 根启动）

```
# 加载前
devmem 0x020E02F4                     → 0x000010B0      （U-Boot 的值）

# rmmod dtsled; insmod /mnt/nfs/root/dtsled.ko
[  128.548170] alphaled node find!
[  128.551427] dtsled: pinctrl "default" state selected (pinctrl_myled 已生效)
[  128.565400] compatible = atkalpha-led
[  128.569360] status = okay
[  128.572109] led_gpio num = 3, active_low
[  128.576236] dtsled major=248, minor=0

# 加载后
devmem 0x020E02F4                     → 0x00017059      ★ 精确等于 dts 里 pinctrl_myled 的值

cat /sys/kernel/debug/pinctrl/*/pinmux-pins | grep GPIO1_IO03
  pin 26 (MX6UL_PAD_GPIO1_IO03): alphaled (GPIO UNCLAIMED) function imx6ul-evk group myledgrp
cat /sys/kernel/debug/pinctrl/*/pinconf-pins | grep GPIO1_IO03
  pin 26 (MX6UL_PAD_GPIO1_IO03):0x17059
cat /sys/kernel/debug/gpio | grep led
  gpio-3   (led                 ) out

# 极性核对（读 GPIO1_DR = 0x0209C000 的 bit3）
ledtest /dev/dtsled 1; devmem 0x0209C000   → 0xF0040204   bit3=0（低电平 = 点亮）✓
ledtest /dev/dtsled 0; devmem 0x0209C000   → 0xF004020C   bit3=1（高电平 = 熄灭）✓
```

模块大小也从 **8360 → 11076 字节**（`44_led.sh` 的版本识别已同步更新）。

## 9.4 结论

第 44 章"能亮"从**运气**变成了**名实相符**：
设备树里写的 `pinctrl_myled` 现在真的被内核应用，pad 复用与驱动能力都由设备树决定，
驱动只管申请 GPIO 和控制电平 —— 这正是第 45 章要讲的"子系统"分工。
