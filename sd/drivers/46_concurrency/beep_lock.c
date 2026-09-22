/*
 * 第 46 章　Linux 并发与竞争 —— 用同一份源码、换锁来对照
 *
 * 板子：正点原子 I.MX6U-ALPHA EMMC 版 + ATK-7016 (7寸 1024x600)
 * 内核：linux-imx 4.1.15（SMP PREEMPT，但本板只有 1 个核 → 演示的是【抢占式】竞争）
 *
 * ---------------------------------------------------------------------------
 * 思路：本章要讲 4 种保护手段（原子操作 / 自旋锁 / 信号量 / 互斥体）。
 * 与其抄 4 份几乎一样的驱动，不如【一份源码 + 编译期开关】：
 *
 *      make KIND=0   → beep_lock0.ko   无保护（故意示范竞争）
 *      make KIND=1   → beep_lock1.ko   原子操作 atomic_inc/atomic_read
 *      make KIND=2   → beep_lock2.ko   自旋锁 spin_lock_irqsave
 *      make KIND=3   → beep_lock3.ko   信号量 down/up
 *      make KIND=4   → beep_lock4.ko   互斥体 mutex_lock/mutex_unlock
 *
 *  同时逐个 insmod 跑同一个测试程序，就能横向对比：
 *      · 计数对不对（有没有丢更新）
 *      · 耗时差多少（原子/自旋锁快，信号量/互斥体慢）
 *      · 各自的适用场合（能不能睡眠、能不能在中断里用）
 *
 * ---------------------------------------------------------------------------
 * 被保护的共享资源（两个）：
 *
 *      unsigned long sw_count;   ——「开关被切换」的累计次数（读-改-写）
 *      int           cur_state;  ——当前逻辑状态（1=响 0=静音）
 *
 * 竞争窗口怎么造出来（UP 单核 + CONFIG_PREEMPT=y）：
 *
 *      进程 A 在临界区里做 sw_count++ 时被时钟中断抢占，进程 B 也进来
 *      读到同一个旧值 → A、B 都写回 old+1 → 丢了一次更新。
 *      单核上窗口很短，所以在临界区里放一个 race_window() 把它拉长，
 *      让"没保护的版本"稳定复现（有保护的版本则完全正确）。
 *
 * 例程里的 race_window() 用忙等（mdelay）—— 注意这在自旋锁里是【反面教材】：
 * 自旋锁临界区要尽可能短、绝对不能让出 CPU。这里为了教学对比才这么写。
 *
 * 【注意】不要用 devm_gpiod_get()/gpiod_set_value()，4.1.15 里没有。
 * ---------------------------------------------------------------------------
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
#include <linux/atomic.h>
#include <linux/spinlock.h>
#include <linux/semaphore.h>
#include <linux/mutex.h>
#include <asm/uaccess.h>

#define BEEP_CNT     1
#define BEEP_NAME    "beep"
#define BEEPOFF      0
#define BEEPON       1

#ifndef KIND
#define KIND 0
#endif

#define KIND_NONE      0
#define KIND_ATOMIC    1
#define KIND_SPINLOCK  2
#define KIND_SEMAPHORE 3
#define KIND_MUTEX     4

#if (KIND < 0) || (KIND > 4)
#error "KIND 只能是 0..4"
#endif

struct beep_dev {
	dev_t devid;
	struct cdev cdev;
	struct class *class;
	struct device *device;
	int major;
	int minor;
	struct device_node *nd;
	int gpio;
	int active_low;
};

static struct beep_dev beep;

/* ===================== 第46章：共享资源 + 保护手段 ===================== */

static unsigned long sw_count;      /* 被并发修改的计数（读-改-写） */
static int cur_state;               /* 当前逻辑状态 */

#if (KIND == KIND_ATOMIC)
#include <linux/atomic.h>
static atomic_t sw_count_atomic = ATOMIC_INIT(0);
#endif

#if (KIND == KIND_SPINLOCK)
static DEFINE_SPINLOCK(beep_lock);
static unsigned long lock_flags;
#endif

#if (KIND == KIND_SEMAPHORE)
static struct semaphore beep_sem;
#endif

#if (KIND == KIND_MUTEX)
static DEFINE_MUTEX(beep_mutex);
#endif

/*
 * 竞争窗口：模块参数（毫秒）
 *   windows_ms=0  → 窗口关闭，用来做【基准测量】（看锁本身的开销）
 *   windows_ms=2  → 窗口打开，把"读-改-写"中间那段拉长，稳定复现竞争
 *   真实驱动里这一段可能是 copy_from_user、寄存器读写、长计算……
 */
static int windows_ms = 1;
module_param(windows_ms, int, 0644);
MODULE_PARM_DESC(windows_ms, "临界区里的模拟窗口(ms)，0=关（基准测试用）");

static void race_window(void)
{
	if (windows_ms > 0)
		mdelay(windows_ms);
}

static void beep_lock_take(void)
{
#if (KIND == KIND_SPINLOCK)
	spin_lock_irqsave(&beep_lock, lock_flags);
#elif (KIND == KIND_SEMAPHORE)
	down(&beep_sem);
#elif (KIND == KIND_MUTEX)
	mutex_lock(&beep_mutex);
#endif
}

static void beep_lock_give(void)
{
#if (KIND == KIND_SPINLOCK)
	spin_unlock_irqrestore(&beep_lock, lock_flags);
#elif (KIND == KIND_SEMAPHORE)
	up(&beep_sem);
#elif (KIND == KIND_MUTEX)
	mutex_unlock(&beep_mutex);
#endif
}

/*
 * 只做电平操作，不计数。release() 走这条 —— 否则 close 设备也会悄悄加计数，
 * 测试的账目就不干净了（期望增量必须是"进程数 × 每人 write 次数"）。
 */
static void beep_set_gpio(u8 sta)
{
	int val = (sta == BEEPON) ? 1 : 0;

	if (beep.active_low)
		val = !val;

	gpio_set_value(beep.gpio, val);
}

/*
 * write() 的临界区：计数（读-改-写）+ 换电平。
 *
 * ★ 窗口位置是关键：必须落在【读】和【写回】之间，才可能被抢占而丢更新。
 *   第一版把 mdelay 放在 sw_count++ 之前 —— 那三条指令中间被抢占的概率几乎为 0，
 *   结果五种变体全都"不丢"、全都是 403，实验毫无区分度（踩坑 #13）。
 */
static void beep_switch(u8 sta)
{
#if (KIND == KIND_NONE)
	/* ❌ 无保护：读 → 窗口 → 写回，中间会被抢占 */
	{
		unsigned long tmp = sw_count;

		race_window();
		sw_count = tmp + 1;
		cur_state = (sta == BEEPON);
		beep_set_gpio(sta);
	}

#elif (KIND == KIND_ATOMIC)
	/* ⚠️ 原子操作只保护【一个变量】的简单操作；cur_state 一致性问题它管不了 */
	atomic_inc(&sw_count_atomic);
	sw_count = (unsigned long)atomic_read(&sw_count_atomic);
	race_window();
	cur_state = (sta == BEEPON);
	beep_set_gpio(sta);

#else
	beep_lock_take();
	{
		unsigned long tmp = sw_count;

		race_window();          /* 窗口在锁里面：别的进程/任务进不来 */
		sw_count = tmp + 1;
		cur_state = (sta == BEEPON);
		beep_set_gpio(sta);
	}
	beep_lock_give();
#endif
}

static unsigned long count_get(void)
{
#if (KIND == KIND_ATOMIC)
	return (unsigned long)atomic_read(&sw_count_atomic);
#else
	return sw_count;
#endif
}

static const char *kind_name(void)
{
#if   (KIND == KIND_NONE)
	return "无保护（示范竞争）";
#elif (KIND == KIND_ATOMIC)
	return "原子操作 atomic_inc";
#elif (KIND == KIND_SPINLOCK)
	return "自旋锁 spin_lock_irqsave";
#elif (KIND == KIND_SEMAPHORE)
	return "信号量 down/up";
#else
	return "互斥体 mutex";
#endif
}

/* =========================== 字符设备接口 =========================== */

static int beep_open(struct inode *inode, struct file *filp)
{
	filp->private_data = &beep;
	return 0;
}

/*
 * read() 输出一行：<切换次数> <当前状态>
 * 测试程序（和 cat）都靠它拿结果。
 */
static ssize_t beep_read(struct file *filp, char __user *buf,
			 size_t cnt, loff_t *offt)
{
	char kbuf[64];
	int len;

	if (*offt)          /* 一次读完就 EOF，方便 cat /dev/beep */
		return 0;

	len = sprintf(kbuf, "%lu %d %s\n", count_get(), cur_state, kind_name());
	if (len > cnt)
		len = cnt;
	if (copy_to_user(buf, kbuf, len))
		return -EFAULT;

	*offt += len;
	return len;
}

static ssize_t beep_write(struct file *filp, const char __user *buf,
			  size_t cnt, loff_t *offt)
{
	int ret;
	unsigned char databuf[1];

	if (cnt < 1)
		return -EINVAL;

	ret = copy_from_user(databuf, buf, 1);
	if (ret < 0) {
		printk("kernel write failed!\r\n");
		return -EFAULT;
	}

	beep_switch(databuf[0]);
	return cnt;
}

static int beep_release(struct inode *inode, struct file *filp)
{
	beep_set_gpio(BEEPOFF);   /* 只关电平，不计数（见 beep_set_gpio 的注释） */
	return 0;
}

static struct file_operations beep_fops = {
	.owner   = THIS_MODULE,
	.open    = beep_open,
	.read    = beep_read,
	.write   = beep_write,
	.release = beep_release,
};

/* ============================ platform 驱动 ============================ */

static int beep_probe(struct platform_device *pdev)
{
	int ret = 0;
	const char *str;
	enum of_gpio_flags flags;
	struct pinctrl *pinctrl;
	struct pinctrl_state *state;

	beep.nd = pdev->dev.of_node;
	if (!beep.nd) {
		printk("mybeep node not find!\r\n");
		return -EINVAL;
	}
	printk("mybeep node find!\r\n");

#if (KIND == KIND_SEMAPHORE)
	sema_init(&beep_sem, 1);        /* 二值信号量 = 当锁用 */
#endif

	/* pinctrl 必须显式 select 一次（第45章踩坑 #11：纯字符驱动不会触发它） */
	pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(pinctrl)) {
		printk("beep: get pinctrl failed (%ld)\r\n", PTR_ERR(pinctrl));
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

	beep.gpio = of_get_named_gpio_flags(beep.nd, "beep-gpio", 0, &flags);
	if (beep.gpio < 0) {
		printk("get beep-gpio failed!\r\n");
		return -EINVAL;
	}
	beep.active_low = (flags & OF_GPIO_ACTIVE_LOW) ? 1 : 0;
	printk("beep_gpio num = %d, active_%s\r\n",
	       beep.gpio, beep.active_low ? "low" : "high");

	ret = gpio_request(beep.gpio, "beep");
	if (ret < 0) {
		printk("gpio_request failed!\r\n");
		return ret;
	}
	ret = gpio_direction_output(beep.gpio, beep.active_low ? 1 : 0);
	if (ret < 0) {
		gpio_free(beep.gpio);
		return ret;
	}

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

	beep.class = class_create(THIS_MODULE, BEEP_NAME);
	if (IS_ERR(beep.class)) {
		ret = PTR_ERR(beep.class);
		goto err_class;
	}
	beep.device = device_create(beep.class, NULL, beep.devid, NULL, BEEP_NAME);
	if (IS_ERR(beep.device)) {
		ret = PTR_ERR(beep.device);
		goto err_device;
	}

	printk("==== 第46章并发实验：本模块的保护方式是【%s】(KIND=%d) ====\r\n",
	       kind_name(), KIND);
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
	beep_set_gpio(BEEPOFF);

	if (beep.device)
		device_destroy(beep.class, beep.devid);
	if (beep.class)
		class_destroy(beep.class);
	cdev_del(&beep.cdev);
	unregister_chrdev_region(beep.devid, BEEP_CNT);
	gpio_free(beep.gpio);

	beep.device = NULL;
	beep.class = NULL;
	printk("beep removed (KIND=%d, 最终计数=%lu)\r\n", KIND, count_get());
	return 0;
}

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
