# IMX6ULL（正点原子 ATK-IMX6ULL-ALPHA / eMMC 版）从内核到桌面到 OTA 的完整移植

> 一块 **i.MX6ULL（Cortex-A7）** 开发板，从原厂出厂系统开始，一路做到
> **自己的内核/驱动 → Buildroot 根文件系统 → Qt5 桌面 → 串口工具 → 固化 eMMC → 整机 A/B OTA 升级** ✓。
> 全过程（含每一步的原始命令与踩过的坑）都记录在仓库里的中文文档中 ✓。

**目录**：[硬件](#一硬件与系统) · [已完成](#二已经做到什么) · [**★ 复现同一系统**](#三如何复现出"同一个系统"详细步骤) · [结构](#四仓库结构) · [**★ 第三方与许可证**](#五第三方组件与许可证声明) · [文档](#六文档索引)

---

## 一、硬件与系统

| 项 | 值 |
|---|---|
| 板子 | 正点原子 **ATK-IMX6ULL-ALPHA**（eMMC 版，512MB DDR3）|
| SoC | NXP **i.MX6ULL** Cortex-A7 @ 792MHz（无 GPU ✗ → Qt 用 linuxfb 软件渲染 ✓）|
| 存储 | eMMC 8GB：`p1` **FAT32 128MB**（启动产物） / `p2` **ext4 7.1GB**（rootfs + `/slots` 状态区）|
| 屏幕 | 7 寸 **1024×600** RGB；触摸 **GT911**（I2C，`/dev/input/event1`）|
| 网络 | `eth0` 直连实验网（`192.168.10.2`）+ **RTL8189FS SDIO WiFi** |
| 串口 | `ttymxc0` @115200（控制台；`getty` 常驻 ✓）|

**软件版本（★ 全部写死 ✓，换版本可能编不出一样的东西 ✗）**

| 组件 | 版本 |
|---|---|
| Buildroot | **2019.02.6** |
| Linux 内核 | **4.1.15**（NXP 官方 + 正点原子出厂补丁：`linux-imx-4.1.15-2.1.0-e48931b1-v2.8`）|
| U-Boot | **2016.03**（`uboot-imx-2016.03-2.1.0-g0ae7e33-v1.7`）|
| Qt | **5.11.3**（qtbase / qtcharts / qtscript / qtserialport）|
| QScintilla | **2.10.8** |
| busybox | **1.29.3** |
| 交叉工具链 | Buildroot 内部：**gcc 7.4.0 + glibc 2.28** |
| SerialTool | 上游 gitee 镜像提交 **20896fb**（源码已随仓库提供 ✓）|

**启动链**（U-Boot 环境变量 + eMMC 内容，**不在源码里** ✗ → 靠快照复原 ✓，见 §3.7）

```
上电 → eMMC boot0 的 U-Boot 2016.03
     → bootcmd: 从 p1 fatload {initrd, zImage, dtb} → 设 bootargs → bootz → 失败则 run emmcboot
     → initramfs(/init) 读 p2 的 /slots/active 选槽（a=p2 本体 / b=p2 上的 ext4 镜像）
     → 挂好 /slots → exec chroot <新根> /sbin/init
     → S39eth0 配 eth0 → S12launcher 起桌面 → S95wifi 连 WiFi → S97timesync 对时 → S99otaconfirm 确认槽位
```

## 二、已经做到什么

- ✅ **内核**：7 寸屏 + GT911 触摸 + **RTL8189FS SDIO WiFi** 驱动就位；开机 logo 换成自定义
- ✅ **根文件系统**：Buildroot 全量自建（含内部工具链、Qt5、以及自写 QScintilla 包）
- ✅ **Qt5 桌面**（`emmc/apps/launcher`，自写）：槽位横幅（**a 槽绿 / b 槽橙**，一眼分得清 ✓）、
  WiFi 徽标（信号格 + SSID + IP，QPainter 手绘不依赖字体 ✓）、**一键 OTA 升级**按钮
- ✅ **串口工具**：上游 **SerialTool** 移植上板 —— 触摸适配、隐藏菜单栏（linuxfb 下 QMenu 会卡死 ✗）、
  面板/标签页禁止误关、布局自愈、`HOME` 修复
- ✅ **免串口启动**：不依赖网络与虚拟机 ✓（`bootcmd` 全走 eMMC 本地文件 ✓）
- ✅ **整机 A/B OTA**：发布端签名 → 板子拉取（sha256 校验）→ 写**非活动槽** → 切槽 → 重启 →
  **自动确认**、连续未确认**自动回退**、initramfs 失败**自愈** ✓
- ✅ **自动对时**：板子无 RTC 电池 → 走 HTTP `Date:` 头对时 + 写回 SNVS RTC ✓；
  时间不可信时桌面**老实显示"未同步"**（绝不显示 1970 这种假信息 ✗）
- ✅ **启动速度**：去掉内核 `ip=` 参数（**不插网线会白等 120 秒** ✗）→ 改为用户态配 eth0 ✓

## 三、如何复现出"同一个系统"（详细步骤）

> ★ 先明确"能保证什么" ✓✗：
> **能保证**：所有我们自己的代码/脚本/配置**逐字节一致** ✓、编译出的系统**配置与功能一致** ✓；
> **不能保证**：内核等二进制**逐字节相同** ✗（内核会内嵌构建时间戳与绝对路径 ✓ —— 除非做可复现构建 ✓）。
> 详细判据见 §3.9 ✓。

### 3.0 需要另外准备的第三方源码（不在本仓库 ✗）

本仓库**只放我们自己的东西 + 配置 + 文档** ✓（体积小、可 review ✓）。
编译前需要把下面这些第三方源码树放到位（版本必须一致 ✗）：

| 目录 | 从哪来 | 说明 |
|---|---|---|
| `emmc/buildroot/` | Buildroot **2019.02.6** 官方源码 | 解压后把我们的外部树接上（§3.2 ✓）|
| `emmc/linux/IMX6ULL/linux-imx/` | 正点原子资料里的 `linux-imx-4.1.15-2.1.0-e48931b1-v2.8.tar.bz2` | ★ 解压后要**打上**本仓库的 `patches/kernel-our-changes.patch` ✓（见 §3.4）。<br>★ 那个补丁**只有 4 个文件 / 1.33MB** ✓ —— RTL8189FS 等 **Realtek vendor 驱动（1227 文件 ✗）随厂家内核包自带** ✓，不在本仓库 ✗ |
| `emmc/uboot/` | 正点原子资料里的 `uboot-imx-2016.03-2.1.0-g0ae7e33-v1.7.tar.bz2` | 我们的改动较少 ✓（见 §3.5）|
| `emmc/apps/SerialTool-src/` | **已随仓库提供** ✓ | 上游 GPL-3.0 源码（139 文件 ✓）|

> 参考：当年这些包就放在 `/mnt/hgfs/shared_folders/imx6ull/01_source_code/` ✓（见 `2026-09-12_系统裁剪记录.md` ✓）

### 3.1 环境准备

- **Ubuntu 20.04 / 22.04**（本项目实测环境 ✓）
- **2 核 / 4GB 内存 + ≥4GB swap**（`br2-build.sh` 注释里写了：`-j2` 是上限 ✓ 别开大 ✓）
- **磁盘 ≥15GB**（第三方源码 ~3GB + 编译产物 ~8GB ✓）
- 依赖包：
  ```bash
  sudo apt install -y build-essential git wget cpio unzip rsync bc bzip2 \
       libncurses5-dev python3 python3-pip device-tree-compiler
  ```
- ★ **别解压到 VMware 共享目录**（`/mnt/hgfs/...`）✗ —— 实测那儿编译**又慢又容易莫名失败** ✗，
  解到 `~/` 这类 ext4 上 ✓。

### 3.2 接入 Buildroot 外部树

```bash
# 把 Buildroot 2019.02.6 解压成 emmc/buildroot/，然后：
cd emmc/buildroot
make BR2_EXTERNAL=../br2-external atk_imx6ull_defconfig     # 或者直接用下面的脚本生成 ✓
```
我们有现成脚本（**推荐 ✓**，它会 merge 增量 fragment 并跑判据 ✓）：
```bash
sh emmc/scripts/br2-setup.sh
#   判据不对就别开编 ✗（脚本自己会校验 ✓）
#   产物：emmc/buildroot/.config ✓（可与 emmc/out/rebuild-snapshot/configs/buildroot.config 对照 ✓）
```

### 3.3 全量编译 Buildroot（★ 1~3 小时 ✓）

```bash
sh emmc/scripts/br2-build.sh          # 前台，会 tee 到日志 ✓
#   大头是内部工具链（gcc + glibc + binutils）✓
#   产物：emmc/buildroot/output/images/rootfs.tar 等 ✓

# ★ 编完必须确认 overlay 进去了 ✓：
ls emmc/buildroot/output/target/etc/init.d/S39eth0        # 应存在 ✓
ls emmc/buildroot/output/target/opt/launcher/launcher     # 应存在 ✓
ls emmc/buildroot/output/target/usr/bin/ota-client.sh     # 应存在 ✓
```
> 如果这些**不在** ✗ → 说明外部树没接对 ✓（检查 `BR2_EXTERNAL` 与 `br2-external/external.mk` ✓）。

### 3.4 编译内核

```bash
cd emmc/linux/IMX6ULL/linux-imx

# ① 先打我们的改动（RTL8189FS WiFi 驱动 + uaccess 修补 + 自定义开机 logo ✓）
git apply ~/linux-projects/patches/kernel-our-changes.patch   # 只有 4 个文件 ✓
#      （RTL8189FS 等 Realtek 驱动由厂家内核包自带 ✓ 不需要额外下载 ✓）

# ② 用快照里的 .config（★ 保证是同一个内核配置 ✓）
cp ~/linux-projects/emmc/out/rebuild-snapshot/configs/linux.config .config

CROSS=~/linux-projects/emmc/buildroot/output/host/bin/arm-buildroot-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$CROSS oldconfig
make ARCH=arm CROSS_COMPILE=$CROSS zImage dtbs -j2

# 产物：
#   arch/arm/boot/zImage
#   arch/arm/boot/dts/imx6ull-14x14-emmc-7-1024x600-c.dtb
```

### 3.5 编译 U-Boot

```bash
cd emmc/uboot
cp ~/linux-projects/emmc/out/rebuild-snapshot/configs/uboot.config .config
make ARCH=arm CROSS_COMPILE=$CROSS oldconfig
make ARCH=arm CROSS_COMPILE=$CROSS -j2
```
> ★ U-Boot 的**启动行为主要不在源码里** ✗，而在**环境变量** `bootcmd` ✓
> → 必须按 §3.7 用快照复原 ✓。

### 3.6 编译应用（桌面 + SerialTool）

```bash
cd ~/linux-projects
bash emmc/scripts/build-launcher.sh build      # 编桌面 ✓ 会自动拷进 rootfs overlay ✓
bash emmc/scripts/build-serialtool.sh patch    # 先只验补丁能不能干净应用 ✓（几秒 ✓ 不需要 Qt ✓）
bash emmc/scripts/build-serialtool.sh build    # 打补丁 + 交叉编译 ✓
```
> 两个脚本都会把产物**复制进 `emmc/br2-external/board/atk/rootfs-overlay/`** ✓
> → 所以**顺序很重要** ✗：先编应用 ✓ 再出 rootfs 镜像 ✓。
> ★ SerialTool 的所有改动都是**补丁**（在 `build-serialtool.sh` 的 `do_patch()` 里 ✓）：
> 触摸适配、隐藏菜单栏、禁关面板/标签页、强制铺满、HOME 修复 ✓。

### 3.7 部署到板子（★ 启动链复原，最需要小心的一步 ✗）

```bash
# ① p1（FAT）放三件套 + 标记
#    zImage、imx6ull-14x14-emmc-7-1024x600-c.dtb、initrd（initramfs ✓）、otaboot 标记（内容随便 ≥1 字节 ✓）
#    initrd 由 emmc/ota/initramfs/ 打包，见 2026-09-21_手动操作流程_OTA整机AB升级.md §3 ✓

# ② 复原 U-Boot 环境（★ 值放文件 ✓ 非空守卫 ✓ 写完读回比对 ✓ —— 本项目漏写过一次，
#    结果板子停在 U-Boot 提示符、只能靠串口救 ✗）
#    快照：emmc/out/rebuild-snapshot/board/uboot-env.txt ✓
fw_printenv -n bootcmd          # 先看现在的值 ✓
#    然后用 fw_setenv 写入快照里的 bootcmd / bootargs（注意单引号，别让宿主 shell 吃掉 ${...} ✓）

# ③ rootfs 写入 p2（★ 在板子上以 root 做 ✓ 保属主 ✓；用 mke2fs -d 不需要挂载 ✓）
bash emmc/scripts/emmc-solidify.sh image
bash emmc/scripts/emmc-solidify.sh kernel
```

### 3.8 发布一个 OTA 包（可选 ✓）

```bash
# ① 在板子上以 root 把当前系统打成 ext4 镜像（保属主 ✓）
ssh root@192.168.10.2 'sh -s' -- /slots/build-rootfs-b.ext4 300 20260922-6 \
    < emmc/ota/server/build-image-on-board.sh
scp root@192.168.10.2:/slots/build-rootfs-b.ext4 /tmp/rootfs.img

# ② 拉回虚拟机 → gzip + 清单 + Ed25519 签名（虚拟机才有 openssl ✓）
bash emmc/ota/server/publish.sh /tmp/rootfs.img 20260922-6 /home/zhb/otatest/ota
python3 -m http.server 8899 --directory /home/zhb/otatest &

# ③ 板子上（★ 必须先跑在 a 槽 ✓ —— 客户端不会覆盖正在运行的根 ✗）
ota-client.sh check
OTA_ALLOW_UNSIGNED=1 ota-client.sh update      # ⚠ 板上还没有验签器 ✗ → 这是实验室开关 ✓
reboot
# ④ 重启后**等 uptime ≥45 秒**再验证 ✓（S95wifi 要阻塞约 28 秒 ✗）
cat /slots/otaconfirm.log ; cat /slots/tries    # tries 应为 0 ✓
```

### 3.9 验证"编出来还是这一个" ✓

```bash
# ① 输入一致性（最快 ✓ 不用等编译 ✓）
md5sum emmc/out/rebuild-snapshot/configs/linux.config       # 与你复制的 .config 比 ✓
# ② 编完后对照"期望清单"逐项比 ✓
cat emmc/out/rebuild-snapshot/expected-md5.txt
#    在板子上：md5sum /usr/bin/ota-client.sh /etc/init.d/S99otaconfirm …  ← 应完全一致 ✓✓
# ③ 板子实测指纹（用抓取脚本 ✓）
ssh root@192.168.10.2 'sh -s' < emmc/out/rebuild-snapshot/board/grab-fingerprint.sh
```

**预期结果**（诚实说明 ✗✓）

| 产物 | 预期 |
|---|---|
| 自家**脚本**（`ota-client.sh` / `S99otaconfirm` / `timesync.sh` / `session.sh` …）| **md5 完全一致** ✓✓ |
| `launcher` / `SerialTool` 二进制 | 通常一致 ✓（同源码 + 同工具链 ✓）|
| `zImage` | **md5 一定不同** ✗（内嵌构建时间戳 `uname -v` + 绝对路径 ✓）→ 判据改为：`.config` 一致 ✓ + 起得来 ✓ |
| `initrd` / rootfs 镜像 | md5 可能不同 ✗（cpio/ext4 时间戳 ✓）→ 用**挖出文件比 md5** 的办法 ✓ |

**最小够用判据** ✓：① 内核 `.config` 逐字节一致 ✓ ② 那 8 个自家脚本 md5 全对 ✓
③ 板子起得来、桌面/SerialTool/WiFi/OTA/对时都正常 ✓。

---

## 四、仓库结构

```
emmc/                        主工程
├── apps/
│   ├── launcher/           自写 Qt5 桌面（main.cpp + .pro）
│   ├── SerialTool-src/     上游 SerialTool 源码（GPL-3.0 ✓，139 文件）
│   └── uart-loopback/ qttest/   小工具与测试
├── br2-external/           ★ Buildroot 外部树（不改 Buildroot 本体 ✓）
│   ├── configs/atk_imx6ull_defconfig
│   ├── atk_imx6ull.fragment   配置增量
│   ├── board/atk/             设备相关：patches/ + post-build.sh + ★ rootfs-overlay/
│   └── package/qscintilla/   自写 Buildroot 包（GPL-3.0+/商业 ✓）
├── ota/
│   ├── board/              板子端：ota-client.sh / ota.conf
│   ├── server/             发布端：publish.sh（gzip+清单+Ed25519 签名）+ build-image-on-board.sh
│   ├── initramfs/          ★ A/B 槽选择器（/init）+ 打包用的 root/（busybox 等 ✓）
│   └── tests/              mock 零风险测试脚本
├── scripts/                25 个构建·部署·验证脚本（每个文件头都有用法 ✓）
├── out/rebuild-snapshot/   ★ 重建配方（见下）
│   ├── REBUILD.md          重建说明（本 README §3 的详细版 ✓）
│   ├── configs/            buildroot.config / linux.config / uboot.config / br2-external 副本
│   ├── board/              uboot-env.txt（U-Boot 环境快照）+ 指纹抓取脚本
│   └── expected-md5.txt    ★ 重建后应得到的 md5 清单
└── toolchain/ notes/
patches/kernel-our-changes.patch   ★ 我们对内核的全部改动（**4 个文件 / 1.33MB** ✓）
sd/backups/ sd/drivers/          早期的 dtb·uboot 备份、44/45/46 章驱动学习代码
out/                               截图与 U-Boot bootcmd 备份
*.md                               ★ 全部操作记录与手册
```

**不在仓库里（有意 ✗）**：`emmc/linux/`、`emmc/uboot/`、`emmc/buildroot/`（第三方源码，共约 7GB ✓ 自行获取 ✓）、
编译产物、eMMC 整盘备份与 sdcard 镜像（>100MB 会被 GitHub 拒收 ✗）、`ota-signing.key`（私钥 ✗）。

## 五、第三方组件与许可证声明

> 本仓库是**个人学习/移植记录** ✓。**本仓库不分发**下列第三方组件的完整源码 ✗
> （仅包含：我们对内核的改动补丁 ✓、上游 SerialTool 源码副本 ✓、以及指向它们的配置与脚本 ✓）。
> 各组件的版权与许可证归**各自作者/公司**所有 ✓，使用与再分发请遵守其许可证条款 ✓。

| 组件 | 版本 | 许可证 | 在本仓库里的体现 |
|---|---|---|---|
| **Qt / Qt5**（qtbase/qtcharts/qtscript/qtserialport）| **5.11.3** | **LGPL-3.0**（或 GPL-2.0+/商业，见 Qt 官方条款）| ★ 桌面与 SerialTool 均基于 Qt 构建 ✓；本仓库含**我们自己的** Qt 应用源码（`emmc/apps/` ✓），**不含 Qt 本体** ✗。Qt 由 Buildroot 在编译时获取 ✓ —— **使用/分发 Qt 需遵守 LGPL-3.0 ✓（含动态链接、提供替换 Qt 的方式等要求 ✓）** |
| **Buildroot** | 2019.02.6 | GPL-2.0+ | 通过外部树 `emmc/br2-external/` 使用 ✓（仅含**我们的**配置与包定义 ✓）|
| **Linux 内核** | 4.1.15（NXP + 正点原子出厂补丁）| GPL-2.0 | 仅提供**我们的改动补丁** `patches/kernel-our-changes.patch` ✓ |
| **U-Boot** | 2016.03 | GPL-2.0+（含多种例外，见其 `Licenses/` ✓）| 仅提供构建脚本与环境快照 ✓ |
| **busybox** | 1.29.3 | GPL-2.0 | 由 Buildroot 编译 ✓ |
| **QScintilla** | 2.10.8 | GPL-3.0+（带例外）或商业 | 自写 Buildroot 包 `emmc/br2-external/package/qscintilla/` ✓（仅包定义 ✓）|
| **SerialTool** | 上游 `20896fb` | **GPL-3.0** | ★ 源码副本随仓库提供 ✓（`emmc/apps/SerialTool-src/LICENSE` ✓ 保留原许可证 ✓）；我们的改动以**补丁脚本**形式给出 ✓ |
| **Realtek WiFi 驱动**（RTL8189FS 等）| 厂商发布版 | **GPL-2.0**（源文件头部声明 ✓）| ★ **不在本仓库** ✗ —— 随正点原子出厂内核源码包提供 ✓（本仓库只含我们那 4 个文件的改动补丁 ✓）|
| **DroidSansFallbackFull.ttf** | — | Apache-2.0 | 中文字体，随 overlay 提供 ✓ |

**说明** ✓：
1. 若你要**再分发**本仓库或基于它构建的固件 ✗，请自行确认满足上表的许可证义务 ✓
   （尤其 **Qt 的 LGPL-3.0** ✓：动态链接、提供替换 Qt 库的方式、附带许可证文本等 ✓）。
2. 本仓库**不包含** Qt / Buildroot / 内核 / U-Boot 的完整源码 ✗，因此**不构成**对它们的再分发 ✓。
3. 若作者（上游组件版权方）认为本仓库中某项内容不妥 ✓，请联系删除 ✓。

## 六、文档索引

★ **从这里开始** → [`README_文档索引.md`](README_文档索引.md) ✓

| 文档 | 内容 |
|---|---|
| `2026-09-12_系统裁剪记录.md` | 起点：源码布局、Buildroot 选型、内核裁剪 |
| `2026-09-13 / 14 / 15_操作记录_*.md` | 设备树 → 第一个驱动 → U-Boot 网络 → WiFi 扫描成功 |
| `2026-09-18_操作记录_Buildroot与免串口启动.md` | Buildroot 全量构建、免串口启动 |
| **`2026-09-19_操作记录_Qt5与SerialTool移植.md`** | ★ **最详细**：Qt5 与 SerialTool 移植上板、桌面、开机 logo、U-Boot bootcmd 改造；<br>§19 面板被叉掉无法恢复 / §19.5c `HOME=/` 读错配置 / §20 不插网线慢 120 秒 |
| `2026-09-20_OTA升级可行性分析与实验记录.md` | OTA 可行性、架构决策、实测数据 |
| **`2026-09-21_OTA整机AB升级_总结.md`** | ★ A/B 升级总结：验证矩阵、坑清单；§10–§12 端到端首跑 / 桌面控制台 / 自动对时 |
| `2026-09-21_手动操作流程_OTA整机AB升级.md` | 操作手册版（照着敲 ✓）|
| `README_代码地图_移植_应用_驱动.md` | 各目录/文件的作用（学习用 ✓）|
| `README_改动溯源_官方对照.md` | 正点原子 vs 官方源码 vs 我们的改动，三层溯源 ✓ |

## 七、说明

- 文档中出现的 **IP、WiFi 名称、串口设备名、MAC** 等，都是当时实验环境的记录 ✓，换环境时按文档说明改对应配置即可 ✓。
- 板子 **root 密码**在 Buildroot 配置里为 `root` ✓（`BR2_TARGET_GENERIC_ROOT_PASSWD` ✓）——
  这是**为了可复现**保留的 ✓；若你对外使用，请务必改掉 ✗（`emmc/br2-external/atk_imx6ull.fragment` ✓）。
- 许可证问题请以上表为准 ✓；本仓库作者不对第三方组件的可用性/合规性作担保 ✓。
