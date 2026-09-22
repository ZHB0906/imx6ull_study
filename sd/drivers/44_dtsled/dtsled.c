/*
 * 第 44 章　设备树下的 LED 驱动
 * 板子：正点原子 I.MX6U-ALPHA EMMC 版 + ATK-7016 (7寸 1024x600)
 * 内核：linux-imx 4.1.15
 * LED ：GPIO1_IO03，设备树里是 GPIO_ACTIVE_LOW（低电平点亮）
 *
 * =================== 2026-09-14 修正：改成 platform driver ===================
 *
 * 【原来的问题】这一版最早是"纯字符驱动 + of_find_node_by_path("/alphaled")"，
 * 看起来能用，但 dts 里的 pinctrl-0 = <&pinctrl_myled> 其实是【死代码】：
 *
 *   内核里应用 pinctrl 的唯一入口是 really_probe()
 *       → pinctrl_bind_pins()  (drivers/base/pinctrl.c)
 *   而 really_probe() 只在"有驱动和设备匹配成功"时才调用。
 *   纯字符驱动不会去 probe /alphaled 这个节点 → pinctrl 永不生效。
 *
 *   那 LED 为什么能亮？—— 因为 U-Boot 恰好把 GPIO1_IO03 配好了
 *   （实测 IOMUXC 的 pad 控制寄存器 0x020E02F4 读回 0x10B0，那是 U-Boot 设的，
 *    不是我们 dts 里的 0x17059）。这属于【运气】，换一根默认状态不同的引脚
 *   （比如第 45 章的 SNVS_TAMPER1）立刻就露馅：蜂鸣器一声不吭、gpio_* 全返回成功。
 *
 * 【现在的做法】写成 platform driver，用 of_match_table 匹配 "atkalpha-led"：
 *   ① driver core 在 probe 前自动 select "default" pinctrl 状态 → pinctrl_myled 生效
 *   ② probe 里再显式 devm_pinctrl_get + pinctrl_lookup_state + pinctrl_select_state，
 *      既能把"内核替我配好了引脚"打出来，也能防住将来有人删掉 pinctrl-0
 *   ③ 极性也从设备树读（of_get_named_gpio_flags），不再靠注释记"低电平点亮"
 *
 * 【保留的正统写法】不直接 of_iomap + writel 操作 5 个寄存器（例程 04_dtsled 那样
 * 容易和 pinctrl/gpio 子系统打架），而是用 gpiolib：复用交给 pinctrl，驱动只管电平。
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

#define DTSLED_CNT      1              /* 设备号个数 */
#define DTSLED_NAME     "dtsled"       /* 设备名，会生成 /dev/dtsled */
#define LEDOFF          0              /* 关灯 */
#define LEDON           1              /* 开灯 */

/* dtsled 设备结构体 */
struct dtsled_dev {
	dev_t devid;                   /* 设备号 */
	struct cdev cdev;              /* cdev */
	struct class *class;           /* 类 */
	struct device *device;         /* 设备 */
	int major;                     /* 主设备号 */
	int minor;                     /* 次设备号 */
	struct device_node *nd;        /* 设备节点 */
	int led_gpio;                  /* LED 使用的 GPIO 编号（全局编号） */
	int active_low;                /* 由设备树 GPIO_ACTIVE_LOW 决定 */
};

static struct dtsled_dev dtsled;

/*
 * @description : LED 打开/关闭
 * @param - sta : LEDON(1) 点亮，LEDOFF(0) 熄灭
 *
 * 【易错点】逻辑值和物理电平分开：设备树写 ACTIVE_LOW，则"亮"= 引脚低电平。
 * 现在这个映射是从设备树读出来的（active_low），不再靠注释记。
 */
static void led_switch(u8 sta)
{
	int val = (sta == LEDON) ? 1 : 0;

	if (dtsled.active_low)
		val = !val;

	gpio_set_value(dtsled.led_gpio, val);
}

static int led_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &dtsled;
	return 0;
}

static ssize_t led_read(struct file *filp, char __user *buf,
			size_t cnt, loff_t *offt)
{
	return 0;
}

static ssize_t led_write(struct file *filp, const char __user *buf,
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

	led_switch(databuf[0]);
	return cnt;
}

static int led_release(struct inode *inode, struct file *filp)
{
	return 0;
}

static struct file_operations dtsled_fops = {
	.owner   = THIS_MODULE,
	.open    = led_open,
	.read    = led_read,
	.write   = led_write,
	.release = led_release,
};

/*
 * @description : platform 驱动的 probe —— 匹配设备树 /alphaled 后由 driver core 调用
 *                ★ 此时 driver core 已经替我们 select 了 "default" pinctrl 状态
 */
static int led_probe(struct platform_device *pdev)
{
	int ret = 0;
	const char *str;
	enum of_gpio_flags flags;
	struct pinctrl *pinctrl;
	struct pinctrl_state *state;

	/* 1、设备节点：由 driver core 传进来（不再 of_find_node_by_path） */
	dtsled.nd = pdev->dev.of_node;
	if (dtsled.nd == NULL) {
		printk("alphaled node not find!\r\n");
		return -EINVAL;
	}
	printk("alphaled node find!\r\n");

	/*
	 * 2、显式再拿一次 pinctrl 并选 default 状态（driver core 已经做过一遍，
	 *    这里重复是为了打日志把"pinctrl 真的生效了"这件事看见）
	 */
	pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(pinctrl)) {
		printk("dtsled: get pinctrl failed (%ld)\r\n", PTR_ERR(pinctrl));
		printk("  → dts 里 /alphaled 少了 pinctrl-names/pinctrl-0？\r\n");
		return PTR_ERR(pinctrl);
	}
	state = pinctrl_lookup_state(pinctrl, PINCTRL_STATE_DEFAULT);
	if (IS_ERR(state)) {
		printk("dtsled: no \"default\" pinctrl state\r\n");
		return PTR_ERR(state);
	}
	ret = pinctrl_select_state(pinctrl, state);
	if (ret) {
		printk("dtsled: select default pinctrl state failed\r\n");
		return ret;
	}
	printk("dtsled: pinctrl \"default\" state selected (pinctrl_myled 已生效)\r\n");

	/* 3、读 compatible / status，纯粹为了让你看到"设备树属性怎么读" */
	ret = of_property_read_string(dtsled.nd, "compatible", &str);
	if (ret < 0)
		printk("compatible read failed!\r\n");
	else
		printk("compatible = %s\r\n", str);

	ret = of_property_read_string(dtsled.nd, "status", &str);
	if (ret < 0)
		printk("status read failed!\r\n");
	else
		printk("status = %s\r\n", str);

	/* 4、从设备树取 GPIO 编号 + 极性（led-gpio = <&gpio1 3 GPIO_ACTIVE_LOW>） */
	dtsled.led_gpio = of_get_named_gpio_flags(dtsled.nd, "led-gpio", 0, &flags);
	if (dtsled.led_gpio < 0) {
		printk("get led-gpio failed!\r\n");
		return -EINVAL;
	}
	dtsled.active_low = (flags & OF_GPIO_ACTIVE_LOW) ? 1 : 0;
	printk("led_gpio num = %d, active_%s\r\n",
	       dtsled.led_gpio, dtsled.active_low ? "low" : "high");

	/* 5、申请 GPIO 并配成输出；默认熄灭（= 逻辑 0 对应的物理电平） */
	ret = gpio_request(dtsled.led_gpio, "led");
	if (ret < 0) {
		printk("gpio_request failed!\r\n");
		return ret;
	}
	ret = gpio_direction_output(dtsled.led_gpio, dtsled.active_low ? 1 : 0);
	if (ret < 0) {
		printk("gpio_direction_output failed!\r\n");
		gpio_free(dtsled.led_gpio);
		return ret;
	}

	/* 6、注册字符设备 */
	if (dtsled.major) {
		dtsled.devid = MKDEV(dtsled.major, 0);
		register_chrdev_region(dtsled.devid, DTSLED_CNT, DTSLED_NAME);
	} else {
		alloc_chrdev_region(&dtsled.devid, 0, DTSLED_CNT, DTSLED_NAME);
		dtsled.major = MAJOR(dtsled.devid);
		dtsled.minor = MINOR(dtsled.devid);
	}
	printk("dtsled major=%d, minor=%d\r\n", dtsled.major, dtsled.minor);

	dtsled.cdev.owner = THIS_MODULE;
	cdev_init(&dtsled.cdev, &dtsled_fops);
	cdev_add(&dtsled.cdev, dtsled.devid, DTSLED_CNT);

	/* 7、创建类和设备节点 /dev/dtsled */
	dtsled.class = class_create(THIS_MODULE, DTSLED_NAME);
	if (IS_ERR(dtsled.class)) {
		ret = PTR_ERR(dtsled.class);
		goto err_class;
	}

	dtsled.device = device_create(dtsled.class, NULL, dtsled.devid,
				      NULL, DTSLED_NAME);
	if (IS_ERR(dtsled.device)) {
		ret = PTR_ERR(dtsled.device);
		goto err_device;
	}

	return 0;

err_device:
	class_destroy(dtsled.class);
err_class:
	cdev_del(&dtsled.cdev);
	unregister_chrdev_region(dtsled.devid, DTSLED_CNT);
	gpio_free(dtsled.led_gpio);
	return ret;
}

static int led_remove(struct platform_device *pdev)
{
	if (dtsled.device)
		device_destroy(dtsled.class, dtsled.devid);
	if (dtsled.class)
		class_destroy(dtsled.class);
	cdev_del(&dtsled.cdev);
	unregister_chrdev_region(dtsled.devid, DTSLED_CNT);
	gpio_free(dtsled.led_gpio);

	dtsled.device = NULL;
	dtsled.class = NULL;

	printk("dtsled removed\r\n");
	return 0;
}

/* 匹配设备树里的 compatible —— 这一步是 pinctrl 能生效的前提 */
static const struct of_device_id dtsled_of_match[] = {
	{ .compatible = "atkalpha-led" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, dtsled_of_match);

static struct platform_driver dtsled_driver = {
	.driver = {
		.name           = "atkalpha-led",
		.of_match_table = dtsled_of_match,
	},
	.probe  = led_probe,
	.remove = led_remove,
};

module_platform_driver(dtsled_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("zhb");
