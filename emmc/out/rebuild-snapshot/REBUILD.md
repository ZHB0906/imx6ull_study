# 从源码重建这块板子的系统 —— 说明与验证

> 本文件随源码包一起提供 ✓
> 目标：**解压 → 按本文编译 → 得到与当前板子功能一致的系统** ✓
> 抓取时间：2026-09-22（板子在 a 槽、版本 20260922-4/5 时代 ✓）

---

## 0. 先说清楚"能保证什么、不能保证什么" ✗✓

| 能保证 ✓ | 不能保证 ✗ |
|---|---|
| 所有**我们自己写的**代码/脚本/配置**逐字节一致** ✓ | 内核/uboot 等二进制**逐字节相同** ✗（见 §6 说明 ✓）|
| 编译出的系统**配置与功能一致** ✓（同内核 config、同 Buildroot config、同补丁 ✓）| 内嵌的**构建时间戳**必然不同 ✗（`uname -v` 会不一样 ✓）|
| 板子上的**启动链**可以完整复原 ✓（U-Boot 环境快照 ✓）| eMMC 的分区**物理状态**（磨损、剩余寿命）✗ |

**一句话**：这是"**同一套源码 + 同一套配置**"✓，编出来的是**同一个系统** ✓（功能/配置层面 ✓），
而不是"比特级复制品" ✗（固件类工程本来也做不到 ✓，除非做可复现构建 ✗）。

---

## 1. 包里有什么

```
emmc/                                ← 主工程（编译都在这下面 ✓）
├── buildroot/                      ← Buildroot 源码 + dl/（已下载的第三方源码包 ✓ 可离线编 ✓）
│   └── output/                     ✗ 不含（5.6G 编译产物 ✓ 编的时候自己生成 ✓）
├── linux/IMX6ULL/linux-imx/        ← 内核树（★ 含我们的驱动改动 ✓ 见 §3 ✓）
├── uboot/                          ← U-Boot 树（★ 含我们的改动 ✓）
├── apps/                           ← 桌面 launcher + SerialTool 源码（含我们的补丁脚本 ✓）
├── br2-external/                   ← ★ Buildroot 外部树：defconfig + board overlay + 自写包 ✓
├── scripts/                        ← 全部构建/部署脚本 ✓（每个文件头都有用法 ✓）
├── ota/                            ← OTA 客户端(板子) + 发布端(虚拟机) + initramfs ✓
├── toolchain/  notes/
└── out/rebuild-snapshot/           ← ★★ 重建配方快照（见 §4 ✓）
sd/                                ← 只含 drivers/backups/tools/toolchain（小 ✓）
                                      ✗ 不含 sd/linux、sd/uboot（原厂源码树，2.3G，重建不需要 ✓）
*.md                                ← 全部操作记录/手册（★ 里面有每一步的原始命令 ✓）
out/                                ← 截图与 U-Boot bootcmd 备份 ✓
```

**`emmc/buildroot/dl/`** 保留是有意的 ✓：它是编译时需要的第三方源码包
（qt5base/qt5charts/qt5script/qt5serialport/qscintilla/busybox/linux/uboot 等 ✓），
**有了它才能离线编译** ✓（否则要重新联网下载 ✓，而且版本可能变 ✗）。

---

## 2. 环境前提

- **Ubuntu 20.04 / 22.04**（本项目实测环境 ✓；别的发行版可能踩 gcc/glibc 差异 ✗）
- 至少 **2 核 / 4G 内存 + 4G swap**（`br2-build.sh` 的注释里写了：`-j2` 是上限 ✓，别开大 ✓）
- 磁盘：源码 ~1.5G + 编译产物 ~8-10G（`buildroot/output` 5.6G ✓）→ **预留 15G** ✓
- 编译时间：Buildroot 全量（含内部工具链 gcc/glibc/binutils）**约 1~3 小时** ✓
- 需要的基础包：`build-essential git wget cpio unzip rsync bc bzip2 \
  libncurses5-dev python3 python3-pip device-tree-compiler` ✓
  （缺什么 Buildroot 会在开头就报出来 ✓）

★ **不要把源码解压到 VMware 共享目录** ✗（`/mnt/hgfs/...` ✓）——
本项目实测：那儿编译**又慢又容易莫名失败** ✗（见 `2026-09-12_系统裁剪记录.md` ✓）。解到 `~/` 这类 ext4 上 ✓。

---

## 3. 我们对第三方树做了什么改动（★ 最容易丢的部分 ✓）

源码包里是**改过的完整树** ✓（不是只给 patch ✗）→ 所以直接用就行 ✓。
为了让你**知道改了什么** ✓，要点如下：

| 树 | 我们的改动 | 相关文档 |
|---|---|---|
| **内核** `linux/IMX6ULL/linux-imx/` | ① 设备树（7 寸 1024×600 屏、GT911 触摸、RTL8189FS WiFi、eMMC ✓）<br>② 驱动：RTL8189FS(SDIO WiFi) 移植 + 编译进内核 ✓<br>③ 开机 logo 换成 `zhanghaibai`n 的 PPM（`drivers/video/logo/logo_linux_clut224.ppm` ✓）| `2026-09-12/13/14/15` ✓ |
| **U-Boot** `uboot/` | 网络/启动链相关（`bootcmd` 现在**不在 U-Boot 源码里** ✗ —— 它是环境变量 ✓ 见 §4.3 ✓）| `2026-09-19_..._Qt5与SerialTool移植.md` §18 ✓ |
| **Buildroot** | 全部走 `br2-external/` 外部树 ✓（**不改 Buildroot 本体** ✓）：<br>· `configs/atk_imx6ull_defconfig` + `atk_imx6ull.fragment`（配置 ✓）<br>· `board/atk/rootfs-overlay/`（★ 我们所有自家脚本/文件都在这里 ✓）<br>· `package/qscintilla/`（自写包 ✓）| `2026-09-18_..._Buildroot与免串口启动.md` ✓ |
| **Qt** | **没有独立源码树** ✓ —— Qt5 由 Buildroot 从 `dl/` 编 ✓ | — |
| **SerialTool** | 上游源码在 `apps/SerialTool-src/` ✓，我们对它的**所有改动都是打补丁** ✓（`scripts/build-serialtool.sh` 里的 `do_patch()` ✓，含触摸适配 / 禁关面板 / HOME 修复 ✓）| `2026-09-19_..._Qt5与SerialTool移植.md` §19 ✓ |

---

## 4. 重建配方快照（`emmc/out/rebuild-snapshot/` ✓）

| 文件 | 内容 | 用途 |
|---|---|---|
| `configs/buildroot.config` | 当前 Buildroot `.config`（95KB ✓）| 和 `br2-setup.sh` 生成的结果对照 ✓ |
| `configs/linux.config` | 当前内核 `.config` ✓ | ★ 保证编出**同一个内核配置** ✓ |
| `configs/uboot.config` | 当前 U-Boot `.config` ✓ | ★ 同上 ✓ |
| `configs/br2-external/` | ~~外部树副本~~ ✗ **已删**（与 `emmc/br2-external/` 逐字节重复 ✓ 直接看那份即可 ✓）| — |
| `board/uboot-env.txt` | **完整 U-Boot 环境变量快照** ✓ | ★ 启动链必须靠它复原 ✓ 见 §4.3 ✓ |
| `board/fingerprint.txt` | 板子上关键产物的 **md5 清单** ✓ | ★ 编完后拿来逐项对比 ✓ 见 §5 ✓ |

### 4.3 启动链不在源码里 ✗ —— 必须靠快照复原 ✓

板子的启动链由**三部分**组成，其中后两部分**不在任何源码树里** ✗：

```
① eMMC p1（FAT 分区）里的文件：zImage / imx6ull-...-7-1024x600-c.dtb / initrd / otaboot 标记
② U-Boot 环境变量：bootcmd（含 initrd 启动链 ✓）、bootargs、netretry=no …
③ eMMC p2（ext4）：rootfs
```
→ **① 由编译产物部署** ✓（`scripts/emmc-solidify.sh kernel` ✓）
→ **② 用 `board/uboot-env.txt` 复原** ✓（板子上有 `fw_setenv` ✓，格式：`fw_setenv <名字> <值>` ✓）
   ⚠️ 复原 `bootcmd` 时**务必**：值放文件里 ✓ → 非空守卫 ✓ → 写完**读回比对** ✓
   （本项目踩过：漏写 `bootcmd` 导致板子停在 U-Boot 提示符 ✗，只能靠串口救 ✓）
→ **③ 由 rootfs 镜像写入** ✓

---

## 5. 重建顺序（照做 ✓）

```bash
# ── 0) 解压 ──
tar xzf atk-source-YYYYMMDD.tar.gz -C ~/        # 解到 ext4 上 ✓ 别放 /mnt/hgfs ✗
cd ~/linux-projects

# ── 1) 生成 Buildroot 配置（可重复执行 ✓）──
sh emmc/scripts/br2-setup.sh
#    判据：脚本自己会校验 ✓（不对就别开编 ✓）

# ── 2) 全量编 Buildroot（★ 1~3 小时 ✓ 内部工具链是大头 ✓）──
sh emmc/scripts/br2-build.sh                    # 前台会 tee 到日志 ✓
#    产物：emmc/buildroot/output/images/rootfs.tar 等 ✓
#    ★ 编完必须确认 emmc/buildroot/output/target/ 里已包含我们的 overlay ✓
#      （etc/init.d/S39eth0、S97timesync、S99otaconfirm、usr/bin/ota-*.sh、opt/launcher/、opt/serialtool/ ✓）

# ── 3) 内核（用快照里的 .config ✓ 保证同配置）──
cd emmc/linux/IMX6ULL/linux-imx
cp ../../../out/rebuild-snapshot/configs/linux.config .config
CROSS=../../buildroot/output/host/bin/arm-buildroot-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$CROSS oldconfig
make ARCH=arm CROSS_COMPILE=$CROSS zImage dtbs -j2
#    产物：arch/arm/boot/zImage ✓、arch/arm/boot/dts/imx6ull-14x14-emmc-7-1024x600-c.dtb ✓

# ── 4) U-Boot（同上 ✓）──
cd ~/linux-projects/emmc/uboot
cp ../out/rebuild-snapshot/configs/uboot.config .config
make ARCH=arm CROSS_COMPILE=$CROSS oldconfig
make ARCH=arm CROSS_COMPILE=$CROSS -j2

# ── 5) 应用（桌面 + SerialTool ✓ 会自动拷进 rootfs overlay ✓）──
cd ~/linux-projects
bash emmc/scripts/build-launcher.sh build
bash emmc/scripts/build-serialtool.sh build      # 打补丁 + 交叉编译 ✓

# ── 6) 出 rootfs 镜像（★ 在板子上以 root 做 ✓ 保属主 ✓）──
#    先按 §4.3 把系统跑到板子上，然后：
ssh root@192.168.10.2 'sh -s' -- /slots/build-rootfs-b.ext4 300 <版本号> \
    < emmc/ota/server/build-image-on-board.sh
#    拉回虚拟机 → 发布 OTA 包 ✓
bash emmc/ota/server/publish.sh /path/rootfs.img 20260922-6 /home/zhb/otatest/ota
```

> 每一步的**原始命令 + 判据 + 当时的报错**都写在顶层那些 `.md` 里 ✓
> （按时间排 ✓：`2026-09-12` → `2026-09-22` ✓）。**卡住先翻那里** ✓。

---

## 6. 验证"编出来还是这一个" ✓

```bash
# ① 先核对"输入"完全一致（最快 ✓ 不用等编译 ✓）
#    把解压出来的关键文件与包内快照/原始哈希对比：
md5sum emmc/br2-external/board/atk/rootfs-overlay/etc/init.d/S99otaconfirm
md5sum emmc/apps/launcher/main.cpp
# ② 编完后，用板子指纹逐项对比（见 emmc/out/rebuild-snapshot/board/fingerprint.txt ✓）
```

**预期结果**（诚实说明 ✗✓）：

| 产物 | 预期 |
|---|---|
| 我们自己的**脚本**（`ota-client.sh` / `S99otaconfirm` / `timesync.sh` / `session.sh` …）| **md5 完全一致** ✓✓ |
| `launcher` / `SerialTool` 二进制 | 通常一致 ✓（同源码 + 同工具链 ✓）；若 Qt 版本/宿主 gcc 不同则可能不同 ✗ |
| `zImage` / `vmlinux` | **md5 一定不同** ✗ —— 内核会内嵌构建时间戳（`uname -v` ✓）与绝对路径 ✓；<br>**判断标准改成**：`uname -v` 之外，`.config` 一致 ✓、`zImage` 大小接近 ✓、起得来 ✓ |
| `initrd`（cpio.gz）| md5 可能不同 ✗（cpio 记录 mtime ✓）→ 用**解出来的文件列表 + 各文件 md5** 对比 ✓ |
| rootfs 镜像 | md5 不同 ✗（ext4 的 UUID/时间戳 ✓）→ 用 `debugfs -R "cat <路径>"` 挖出关键文件比 md5 ✓（本项目一直这么验 ✓）|

★ **推荐的最小判据**（够用 ✓）：
1. 内核 `.config` 与 `configs/linux.config` **逐字节一致** ✓
2. rootfs 里那 8 个自家脚本 md5 **与指纹全对** ✓
3. 板子能起来、桌面/SerialTool/WiFi/OTA/时间同步**功能正常** ✓

---

## 7. 不含什么（有意的 ✗）

| 不含 | 原因 | 想要的话 |
|---|---|---|
| `emmc/buildroot/output/`（5.6G ✗）| 纯编译产物 ✓ 编的时候生成 ✓ | 可单独打包 ✓ |
| `emmc/out/emmc-backup/`（418M ✗）| 当前板子的 **eMMC 整盘备份** ✗（不是源码 ✓）| ★ 建议**单独留一份** ✓（这是唯一能把板子恢复成"现在这个物理状态"的东西 ✓）|
| `sd/linux`、`sd/uboot`（2.3G ✗）| 正点原子原厂源码树 ✓ 重建不需要 ✓ | 可从原厂资料重新解压 ✓ |
| `ota-signing.key`（签名私钥 ✗）| 已单独放在 `emmc/out/rebuild-snapshot/`（⚠️ 是**私钥** ✓ 别外传 ✗）| 见下 ✓ |

> ⚠️ **签名私钥说明**：`ota-signing.key` 是给 OTA 清单签名用的 ✓。
> 你**继续用同一个包发布升级**就需要它 ✓；换了新密钥就必须把新公钥 `ota-pub.pem` 也刷到板子上 ✓
> （否则板上验签会失败 ✗ —— 不过现在板上还没有验签器 ✓，暂时不影响 ✓）。
