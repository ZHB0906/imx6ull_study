include $(sort $(wildcard $(BR2_EXTERNAL_ATK_IMX6ULL_PATH)/package/*/*.mk))

# ============================================================================
# host-dtc 1.4.7 编不过：同一个 yylloc 坑（GCC 10+ 默认 -fno-common）
#
# 报错：
#   /usr/bin/ld: dtc-parser.tab.o:(.bss+0x10): multiple definition of `yylloc';
#                 dtc-lexer.lex.o:(.bss+0x0): first defined here
#   make[1]: *** [.../host-dtc-1.4.7/.stamp_built] Error 2
#
# 这个坑在内核那边已经见过 —— 内核是用命令行 HOSTCC="gcc -fcommon" 绕过的
# （见实施计划 0.5 原则 5）。到了 Buildroot 里，dtc 由 Buildroot 自己编，
# 就得在 Buildroot 侧修。
#
# ★ 为什么不能改 dtc 的 Makefile：
#   package/dtc/dtc.mk 第 58 行是
#       $(HOST_CONFIGURE_OPTS) $(MAKE) CFLAGS="$(HOST_CFLAGS) -fPIC" -C $(@D) ...
#   CFLAGS 是**命令行传入**的，会覆盖 Makefile 里的同名变量，
#   所以必须加在 HOST_CFLAGS 上。
#
# ★ 为什么要用 ifneq 保护：
#   本文件在顶层 Makefile 里被 include 两次（第 187 行、第 544 行），
#   而 package/Makefile.in（定义 `HOST_CFLAGS ?= -O2` 等）在第 509 行才 include。
#   如果在 187 行那次就无条件 `HOST_CFLAGS += -fcommon`，
#   变量会"先被定义"，导致第 223 行的 `?= -O2` 失效、丢掉 -O2。
#   ifneq 保证只在 HOST_CFLAGS 已经存在（= 544 行那次）时才追加。
#
# 影响面：-fcommon 是 GCC 10 之前的默认行为，加回去对所有宿主包都安全；
#         顺带把这一类"老 yacc/lex 代码 + 新 GCC"的坑一次性堵住。
# ============================================================================
ifneq ($(HOST_CFLAGS),)
HOST_CFLAGS += -fcommon
endif

# ============================================================================
# host-m4 1.4.18 在 glibc >= 2.34 上编不过 —— post-extract 补丁
#
# 报错：lib/c-stack.c:55: error: missing binary operator before token "("
#       #elif HAVE_LIBSIGSEGV && SIGSTKSZ < 16384
# 根因：glibc 2.34 起 SIGSTKSZ 从常量变成**函数式宏** sysconf(_SC_SIGSTKSZ)，
#       不能再出现在 #if/#elif 表达式里（短路也救不了，整个表达式都要先解析）。
# 影响面：这条分支在我们这里本来就是死的（HAVE_LIBSIGSEGV=0，没装 libsigsegv），
#       所以补丁只是把那个比较去掉、保留原来的意图。
# 做法：跟 fakeroot 同理 —— 用 post-extract 钩子，
#       因为 HOST_M4_PATCH 已被 infra 用 `?=` 填成 package/m4/*.patch 的 wildcard，
#       在 br2-external 里赋 M4_PATCH 会被静默忽略（fakeroot 那次已经验证过）。
# ============================================================================
define M4_FIX_SIGSTKSZ
	cd $(@D) && patch -p1 < $(BR2_EXTERNAL_ATK_IMX6ULL_PATH)/board/atk/patches/m4-0003-SIGSTKSZ-glibc-2.34.patch
endef
HOST_M4_POST_EXTRACT_HOOKS += M4_FIX_SIGSTKSZ

# ============================================================================
# qt5base 5.11.3 在**宿主 GCC >= 11** 下编不过 —— 宿主 spec 预包含 <limits>
#
# 报错（发生在 qmake 引导阶段，注意编译命令用的是 /usr/bin/g++ 即宿主编译器）：
#   src/corelib/tools/qbytearraymatcher.h:103:38:
#     error: 'numeric_limits' is not a member of 'std'
#         const auto uchar_max = (std::numeric_limits<uchar>::max)();
#
# 根因：GCC 11 的 libstdc++ 不再通过 <algorithm> 等**间接**包含 <limits>，
#       而 Qt 5.11（2018）里 17 个头文件直接用了 std::numeric_limits 却没写 include。
#       目标侧不受影响 —— Buildroot 的交叉 GCC 是 7.4，仍会间接包含。
#       受影响的是宿主侧：qmake 引导、以及 moc/rcc 等**宿主工具**（编的是同一批 QtCore 代码）。
#
# 为什么改宿主 spec 而不是逐个补 #include：17 个文件逐个补是打地鼠，而且引导阶段
#   单线程、错一个才暴露一个，一轮一轮试太慢。在宿主 spec 上强制预包含一次即整类解决。
#   失败的 Makefile 里 QMAKESPEC = .../mkspecs/linux-g++ ✓（宿主 spec），
#   放在它里面 = 只影响宿主，不污染交叉编译的目标 CXXFLAGS。
#
# 应用方式同 host-m4：用 post-extract 钩子（$(PKG)_PATCH 在 infra 里已被 `?=` 填过，
# 在 br2-external 里再赋值会被静默忽略 —— fakeroot 那次已经验证过）。
# 带 grep 守卫，重复应用安全。
# ============================================================================
define QT5BASE_FIX_HOST_GCC11_LIMITS
	if ! grep -q 'include limits' $(@D)/mkspecs/linux-g++/qmake.conf; then \
		cd $(@D) && patch -p1 < $(BR2_EXTERNAL_ATK_IMX6ULL_PATH)/board/atk/patches/qt5base-0001-host-spec-gcc11-limits.patch ; \
	fi
endef
QT5BASE_POST_EXTRACT_HOOKS += QT5BASE_FIX_HOST_GCC11_LIMITS

# ============================================================================
# 记录：host-fakeroot（Buildroot 2019.02 自带 1.20.2）在 Ubuntu 22.04 上不可用
#
# 【现象 1】编不过
#   libfakeroot.c 里 `_STAT_VER undeclared`（16 处）
#   因为 glibc 2.33 起删掉了 _STAT_VER 宏与 __xstat 系列的头文件声明。
#
# 【现象 2】★ 补上 `#define _STAT_VER 1` 后能编过，但**功能静默失效**
#   nm -D output/host/lib/libfakeroot.so | grep " T "
#       → 只有 __xstat / __xstat64 / chown，**没有 stat / lstat / fstat**
#   现代程序（glibc ≥ 2.33 编译的）直接调 `stat`，不再走 `__xstat`，
#   所以伪造结果根本不被查询：
#       $ fakeroot -- sh -c 'touch /tmp/f; chown 1234:5678 /tmp/f; ls -ln /tmp/f'
#       -rw-rw-r-- 1 1000 1000 0 ...      ← 伪造没生效
#   （这条我差点当成"修好了"放过去 —— 编译通过 ≠ 功能正确）
#
# 【已试过、无效的路】
#   - `override FAKEROOT_VERSION = 1.30.1`（+ _SOURCE/_SITE）：
#     override 压不住，因为包变量在顶层 Makefile 第 533 行
#     `$(eval $(host-autotools-package))` 时就**展开进规则字符串**了，
#     external.mk 即使在第 544 行被二次 include 也改不动已生成的规则。
#     实测仍然去建 output/build/host-fakeroot-1.20.2。
#   - 只补 _STAT_VER：见现象 2。
#
# 【验证过的事实（供以后修的时候省事）】
#   - glibc 2.35 的 libc.so.6 里 __xstat64/__lxstat64/__fxstat64 **仍然导出**
#     （compat 符号 @@GLIBC_2.2.5），且 `__xstat64(1, path, &st)` 返回 0
#   - sources.buildroot.net 上有 fakeroot_1.26 / 1.30.1 的 orig tarball（206）
#     sha256(fakeroot_1.30.1.orig.tar.gz) =
#       32ebb1f421aca0db7141c32a8c104eb95d2b45c393058b9435fbf903dd2b6a75
#   - 1.26 / 1.30.1 都仍带 configure（autotools，兼容旧 .mk 的构建方式）
#
# 【可行的修法（留给"固化到 SD/eMMC"里程碑）】
#   A. 用 BR2_PACKAGE_OVERRIDE_FILE（默认 buildroot/local.mk）里的
#      `FAKEROOT_OVERRIDE_SRCDIR = .../board/atk/src/fakeroot-1.30.1`
#      —— 这是 Buildroot 官方的"用本地源码目录替换某包"机制；
#   B. 或者正经回移上游对 stat/lstat/fstat 的 interpose（1.26+ 的做法）。
#   ★ 无论哪种，验收判据都必须是那条 fakeroot 烟雾测试（伪造 chown 1234:5678
#     后 `ls -ln` 要显示 1234 5678），不能只看编过。
#
# 【本轮决定】先关掉 EXT2/TAR 镜像（见 atk_imx6ull.fragment），
#   用 output/target/ 作 NFS 根 —— M3~M5 不需要镜像，fakeroot 自然不在依赖图里。
# ============================================================================
