################################################################################
#
# qscintilla —— SerialTool 的语法高亮依赖（Buildroot 2019.02 没有这个包，我们自己加）
#
# 为什么需要它：SerialTool 的 src/views/texttr/textedit.cpp 里
#     class TextEdit : public QsciScintilla     ← 直接继承 QScintilla
#   用它的 lexer 做 C++/bash/lua/json 语法高亮。砍掉它要改写这个类，
#   加个包更干净（而且 .pro 里的 `CONFIG += qscintilla2` 也就直接生效了）。
#
# 为什么用 generic-package 而不是 qmake-package：
#   这个版本的 Buildroot 没有 package/pkg-qmake.mk（2019.02 尚未引入），
#   所以照 package/qwt/qwt.mk 的做法手写 configure/build/install 三步。
#
# 装出来的东西：
#   staging: libqscintilla2_qt5.so + include/Qsci/* + mkspecs/features/qscintilla2.prf
#            （★ 那个 .prf 才是 `CONFIG += qscintilla2` 能生效的关键）
#   target : 只要 libqscintilla2_qt5.so.*（头文件和 mkspecs 不上板）
#
################################################################################

QSCINTILLA_VERSION = 2.10.8
QSCINTILLA_SOURCE = QScintilla_gpl-$(QSCINTILLA_VERSION).tar.gz
QSCINTILLA_SITE = https://www.riverbankcomputing.com/static/Downloads/QScintilla/$(QSCINTILLA_VERSION)

QSCINTILLA_INSTALL_STAGING = YES
QSCINTILLA_DEPENDENCIES = qt5base

QSCINTILLA_LICENSE = GPL-3.0+ (with exceptions) or commercial
QSCINTILLA_LICENSE_FILES = LICENSE

# 源码包里 Qt4/Qt5 共用一个工程目录：Qt4Qt5/qscintilla.pro
define QSCINTILLA_CONFIGURE_CMDS
	(cd $(@D)/Qt4Qt5; $(TARGET_MAKE_ENV) $(QT5_QMAKE) qscintilla.pro)
endef

define QSCINTILLA_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/Qt4Qt5
endef

# ── staging 安装 ────────────────────────────────────────────────────────────
# ★★ 绝对不要加 `INSTALL_ROOT=$(STAGING_DIR)`！★★
#   被它坑过一次（构建在 .stamp_staging_installed 处失败）：
#   qt5base 配置时带了 `-sysroot $(STAGING_DIR)`，所以 **qmake 生成的安装路径里
#   已经包含 sysroot**（比如 /home/.../sysroot/usr/lib）。再传 INSTALL_ROOT 就是
#   第二次加前缀 → 整个安装被套进
#       $(STAGING_DIR)/home/zhb/.../buildroot/output/host/.../sysroot/usr/lib/...
#   这种双层路径里。而 Buildroot 有个防呆检查（package/pkg-generic.mk 的
#   step_check_build_dir）：install-staging 之后如果存在 `$(STAGING_DIR)/$(O)`
#   就直接判失败 —— 于是整个包报
#       qscintilla: installs files in .../sysroot//home/...
#       make[1]: *** [package/pkg-generic.mk:287: .../.stamp_staging_installed] Error
#   同族的 qt5charts.mk 就是 `$(MAKE) -C $(@D) install`（**不带 INSTALL_ROOT**），照它写。
define QSCINTILLA_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/Qt4Qt5 install
	# ★ 再往 sysroot 里显式放一份 .prf（别删）：
	#   qscintilla.pro 在 Qt5 分支里写的是 features.path = $$[QT_HOST_DATA]/mkspecs/features
	#   → 正常会装到 $(HOST_DIR)/mkspecs/features/（qmake 也搜那里，没问题）；
	#   这里额外在 sysroot 的 /usr/lib/qt/mkspecs/features/ 放一份，
	#   因为那才是 qmake 的另一处搜索路径，双保险确保 `CONFIG += qscintilla2` 生效
	#   （失效是**静默**的：不报错，只是没有 -I.../Qsci 与 -lqscintilla2_qt5）。
	mkdir -p $(STAGING_DIR)/usr/lib/qt/mkspecs/features
	cp -f $(@D)/Qt4Qt5/features/qscintilla2.prf \
		$(STAGING_DIR)/usr/lib/qt/mkspecs/features/qscintilla2.prf
endef

# ── target 安装 ─────────────────────────────────────────────────────────────
# 同样不跑 `make install INSTALL_ROOT=$(TARGET_DIR)`（会双重前缀），
# 而是像 qt5charts 那样**从 staging 挑运行库拷过去**。板子只需要 .so：
# 头文件 / mkspecs(.prf) / qsci.pri / translations 都只在"板上再编译"时才有意义。
define QSCINTILLA_INSTALL_TARGET_CMDS
	for f in $(STAGING_DIR)/usr/lib/libqscintilla2_qt5.so*; do \
		[ -e "$$f" ] || continue; \
		cp -dpf "$$f" $(TARGET_DIR)/usr/lib/ || exit 1; \
	done
endef

$(eval $(generic-package))
