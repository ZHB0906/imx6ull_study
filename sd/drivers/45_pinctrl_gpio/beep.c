/*
 * 第 45 章　pinctrl 和 gpio 子系统实验 —— 蜂鸣器驱动
 * 板子：正点原子 I.MX6U-ALPHA EMMC 版 + ATK-7016 (7寸 1024x600)
 * 内核：linux-imx 4.1.15
 * BEEP：SNVS_TAMPER1 → GPIO5_IO01（全局 GPIO 号 129 = GPIO5 基址 128 + 1）
 *
 * ======================= 第 45 章踩到的大坑 =======================
 *
 * 【坑】pinctrl-0 不会自己生效！它只在"有驱动绑定到这个设备节点"时才被应用。
 *
 *   内核里应用 pinctrl 的地方只有一处：
 *       drivers/base/dd.c: really_probe()
 *           → pinctrl_bind_pins(dev)          (drivers/base/pinctrl.c)
 *               → devm_pinctrl_get()
 *               → pinctrl_lookup_state(..., "default")
 *               → pinctrl_select_state(...)   ← 到这一步才真正写 IOMUX 寄存器
 *
 *   really_probe() 是"驱动和设备匹配成功后"调用的。所以：
 *
 *     纯字符驱动 + of_find_node_by_path("/mybeep")   ← 谁都不会去 probe 这个节点
 *         ⇒ pinctrl_mybeep 永远不生效 ⇒ SNVS_TAMPER1 仍是非 GPIO 复用、
 *           pad 驱动能力也是复位默认值 ⇒ 往 GPIO 数据寄存器写 0/1 等于写空气,
 *           蜂鸣器一声不吭。而且 gpio_request/gpio_set_value 全都返回成功,
 *           不报任何错 —— 这是最坑的地方。
 *
 *   第 44 章的 alphaled 能亮，纯粹是运气：GPIO1_IO03 的复位默认就是 GPIO 功能、
 *   驱动能力也够，所以"没应用 pinctrl"照样点亮。换一根 pad 就露馅了。
 *
 * 【正解】把驱动写成 platform driver，用 of_match_table 匹配 "atkalpha-beep"：
 *   ① driver core 在 probe 前自动 select "default" pinctrl 状态（pinctrl-0 生效）
 *   ② 驱动里再显式 devm_pinctrl_get + pinctrl_select_state 一次，
 *      既能打日志把"内核替我配好了引脚"这件事看见，也不怕将来有人删掉 pinctrl-0
 *   ③ 之后 gpio_request / gpio_direction_output / gpio_set_value 才有意义
 *
 * ======================= 其它两个知识点 =======================
 *
 * ① pinctrl 组归自己管
 *    第 44 章 alphaled 写的是 pinctrl-0 = <&pinctrl_gpio_leds>，蹭的是板级
 *    gpio-leds 用的组。这一章自己定义 pinctrl_myled / pinctrl_mybeep。
 *    ★ SNVS_TAMPERx 焊盘（GPIO5_x）的组必须放 &iomuxc_snvs，不能放 &iomuxc：
 *      内核里 imx6ul-iomuxc 和 imx6ul-iomuxc-snvs 是两个独立的 pinctrl 设备。
 *
 * ② 极性从设备树读，不硬编码
 *    第 44 章 dtsled.c 里是 gpio_set_value(gpio, 0) + 注释"低电平点亮"。
 *    注释记错了、或哪天 dts 改成 ACTIVE_HIGH，行为就悄悄反了，编译器和内核都不报错。
 *    这里用 of_get_named_gpio_flags() 把 GPIO_ACTIVE_LOW 读出来，
 *    "逻辑值（1=响）"和"物理电平"分开处理。
 *
 * 【注意】不要用 devm_gpiod_get()/gpiod_set_value()，这套 gpiod 描述符 API
 * 在 4.1.15 里【不存在】。本内核只能用 of_get_named_gpio_flags + gpio_* 这套。
 */

#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/delay.h>
#include <linux/ide.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/errno.h>
#include <linux/gpio.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/of_gpio.h>
#include <linux/platform_device.h>
#include <linux/pinctrl/consumer.h>
#include <asm/uaccess.h>
#include <asm/io.h>

#define BEEP_CNT     1            /* 设备号个数 */
#define BEEP_NAME    "beep"       /* 设备名，会生成 /dev/beep */
#define BEEPOFF      0            /* 静音 */
#define BEEPON       1            /* 响 */

/* beep 设备结构体 */
struct beep_dev {
	dev_t devid;              /* 设备号 */
	struct cdev cdev;         /* cdev */
	struct class *class;      /* 类 */
	struct device *device;    /* 设备 */
	int major;                /* 主设备号 */
	int minor;                /* 次设备号 */
	struct device_node *nd;   /* 设备节点 */
	int gpio;                 /* 蜂鸣器使用的 GPIO 编号（全局编号） */
	int active_low;           /* 由设备树 GPIO_ACTIVE_LOW 决定 */
};

static struct beep_dev beep;

/*
 * @description : 蜂鸣器 响/静音
 * @param - sta : BEEPON(1) 响，BEEPOFF(0) 静音
 *
 * 【易错点】分两步，别合成一步：
 *   "逻辑值" 是驱动对外承诺的语义（1=响）；
 *   "物理电平" 是引脚上真实的 0/1，由设备树极性决定。
 */
static void beep_switch(u8 sta)
{
	int val = (sta == BEEPON) ? 1 : 0;   /* 逻辑值 */

	if (beep.active_low)                 /* 逻辑值 → 物理电平 */
		val = !val;

	gpio_set_value(beep.gpio, val);
}

static int beep_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &beep;
	return 0;
}

static ssize_t beep_read(struct file *filp, char __user *buf,
			 size_t cnt, loff_t *offt)
{
	return 0;
}

static ssize_t beep_write(struct file *filp, const char __user *buf,
			  size_t cnt, loff_t *offt)
{
	int retvalue;
	unsigned char databuf[1];

	/* 【易错点】cnt 要限制，用户态传 0 会让 copy_from_user 什么都不做 */
	if (cnt < 1)
		return -EINVAL;

	retvalue = copy_from_user(databuf, buf, 1);
	if (retvalue < 0) {
		printk("kernel write failed!\r\n");
		return -EFAULT;
	}

	beep_switch(databuf[0]);
	return cnt;
}

static int beep_release(struct inode *inode, struct file *filp)
{
	/* 关掉设备时让蜂鸣器安静下来，否则 rmmod 之后它会一直响 */
	beep_switch(BEEPOFF);
	return 0;
}

static struct file_operations beep_fops = {
	.owner   = THIS_MODULE,
	.open    = beep_open,
	.read    = beep_read,
	.write   = beep_write,
	.release = beep_release,
};

/*
 * @description : platform 驱动的 probe —— 匹配到设备树 /mybeep 后由 driver core 调用
 *                ★ 注意此时 driver core 已经替我们 select 了 "default" pinctrl 状态
 *                  （pinctrl_bind_pins()），所以引脚复用/pad 驱动能力已经就位
 */
static int beep_probe(struct platform_device *pdev)
{
	int ret = 0;
	const char *str;
	enum of_gpio_flags flags;
	struct pinctrl *pinctrl;
	struct pinctrl_state *state;

	beep.nd = pdev->dev.of_node;          /* 设备树节点：<&mybeep> */
	if (!beep.nd) {
		printk("mybeep node not find!\r\n");
		return -EINVAL;
	}
	printk("mybeep node find!\r\n");

	/*
	 * 0、显式再拿一次 pinctrl 并选 default 状态。
	 *
	 *    driver core 在 probe 之前已经通过 pinctrl_bind_pins() 做过一次，
	 *    这里重复做是为了：
	 *      · 把"pinctrl 真的生效了"这件事用 printk 打出来（上一版就是没做这步，
	 *        也看不到任何异常，蜂鸣器不响查了半天）
	 *      · 万一以后有人把 dts 里的 pinctrl-0 删了，这里会明确报失败
	 */
	pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(pinctrl)) {
		printk("beep: get pinctrl failed (%ld)\r\n", PTR_ERR(pinctrl));
		printk("  → dts 里 /mybeep 少了 pinctrl-names/pinctrl-0？\r\n");
		return PTR_ERR(pinctrl);
	}
	state = pinctrl_lookup_state(pinctrl, PINCTRL_STATE_DEFAULT);
	if (IS_ERR(state)) {
		printk("beep: no \"default\" pinctrl state\r\n");
		return PTR_ERR(state);
	}
	ret = pinctrl_select_state(pinctrl, state);
	if (ret) {
		printk("beep: select default pinctrl state failed\r\n");
		return ret;
	}
	printk("beep: pinctrl \"default\" state selected (引脚复用已按设备树配好)\r\n");

	/* 1、读 compatible / status，纯粹为了看到"设备树属性怎么读" */
	ret = of_property_read_string(beep.nd, "compatible", &str);
	if (ret < 0)
		printk("compatible read failed!\r\n");
	else
		printk("compatible = %s\r\n", str);

	ret = of_property_read_string(beep.nd, "status", &str);
	if (ret < 0)
		printk("status read failed!\r\n");
	else
		printk("status = %s\r\n", str);

	/* 2、取 GPIO 编号 + 极性（beep-gpio = <&gpio5 1 GPIO_ACTIVE_LOW>） */
	beep.gpio = of_get_named_gpio_flags(beep.nd, "beep-gpio", 0, &flags);
	if (beep.gpio < 0) {
		printk("get beep-gpio failed!\r\n");
		printk("  → 检查属性名是不是写成了 beep-gpios / beep_gpio\r\n");
		return -EINVAL;
	}
	beep.active_low = (flags & OF_GPIO_ACTIVE_LOW) ? 1 : 0;
	printk("beep_gpio num = %d, active_%s\r\n",
	       beep.gpio, beep.active_low ? "low" : "high");

	/* 3、申请 GPIO 并配成输出，默认静音（物理电平 = 逻辑 0 的等价电平） */
	ret = gpio_request(beep.gpio, "beep");
	if (ret < 0) {
		printk("gpio_request failed!\r\n");
		return ret;
	}
	ret = gpio_direction_output(beep.gpio, beep.active_low ? 1 : 0);
	if (ret < 0) {
		printk("gpio_direction_output failed!\r\n");
		gpio_free(beep.gpio);
		return ret;
	}

	/* 4、注册字符设备 */
	if (beep.major) {
		beep.devid = MKDEV(beep.major, 0);
		register_chrdev_region(beep.devid, BEEP_CNT, BEEP_NAME);
	} else {
		alloc_chrdev_region(&beep.devid, 0, BEEP_CNT, BEEP_NAME);
		beep.major = MAJOR(beep.devid);
		beep.minor = MINOR(beep.devid);
	}
	printk("beep major=%d, minor=%d\r\n", beep.major, beep.minor);

	beep.cdev.owner = THIS_MODULE;
	cdev_init(&beep.cdev, &beep_fops);
	cdev_add(&beep.cdev, beep.devid, BEEP_CNT);

	/* 5、创建类和设备节点 /dev/beep */
	beep.class = class_create(THIS_MODULE, BEEP_NAME);
	if (IS_ERR(beep.class)) {
		ret = PTR_ERR(beep.class);
		goto err_class;
	}

	beep.device = device_create(beep.class, NULL, beep.devid,
				    NULL, BEEP_NAME);
	if (IS_ERR(beep.device)) {
		ret = PTR_ERR(beep.device);
		goto err_device;
	}

	return 0;

err_device:
	class_destroy(beep.class);
err_class:
	cdev_del(&beep.cdev);
	unregister_chrdev_region(beep.devid, BEEP_CNT);
	gpio_free(beep.gpio);
	return ret;
}

static int beep_remove(struct platform_device *pdev)
{
	beep_switch(BEEPOFF);          /* 别让蜂鸣器带着响声卸载 */

	if (beep.device)
		device_destroy(beep.class, beep.devid);
	if (beep.class)
		class_destroy(beep.class);
	cdev_del(&beep.cdev);
	unregister_chrdev_region(beep.devid, BEEP_CNT);
	gpio_free(beep.gpio);

	beep.device = NULL;
	beep.class = NULL;

	printk("beep removed\r\n");
	return 0;
}

/* 匹配设备树里的 compatible —— 这一步是 pinctrl 能生效的前提 */
static const struct of_device_id beep_of_match[] = {
	{ .compatible = "atkalpha-beep" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, beep_of_match);

static struct platform_driver beep_driver = {
	.driver = {
		.name           = "atkalpha-beep",
		.of_match_table = beep_of_match,
	},
	.probe  = beep_probe,
	.remove = beep_remove,
};

module_platform_driver(beep_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("zhb");
