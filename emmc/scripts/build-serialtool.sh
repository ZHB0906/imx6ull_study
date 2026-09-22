#!/bin/bash
#
# build-serialtool.sh —— 交叉编译 SerialTool 并推到板子上
#
#   bash emmc/scripts/build-serialtool.sh build    # 打补丁 + 交叉编译
#   bash emmc/scripts/build-serialtool.sh patch     # 只打补丁（不需要 Qt，可先验证补丁能否干净应用）
#   bash emmc/scripts/build-serialtool.sh push      # 推到板子 /opt/serialtool/
#   bash emmc/scripts/build-serialtool.sh all       # build + push
#
# 背景（为什么需要打补丁）：
#   1) `.pro` 里 `QT += uitools` —— 只有 scriptextensionview.cpp 的 QUiLoader 用；
#      而 **Buildroot 2019.02 的 qt5tools 不提供 QtUiTools**（只有 linguist/pixeltool/
#      qtdiag/qtpaths/qtplugininfo），所以先把这处补掉，保证能编能跑。
#      （想保留"自定义 .ui 视图"这个功能的话，后面可以像 QScintilla 那样再写一个
#        QtUiTools 小包 —— 它就在 qttools 源码的 src/uitools/ 里，是个独立 qmake 工程。）
#   2) 其余（QScintilla / QtScript / QChart / QSerialPort）都由我们自己的包满足。
#   3) ★ 测试辅助钩子（默认完全不生效，只为能远程自动化测试）：
#      串口名**不写进配置**、openPort() 只能点工具栏按钮，而板子内核没编 uinput
#      （无法注入触摸）→ 不打个 env 开关就没法无人值守地测串口/波形性能。
#      用法：SERIALTOOL_TEST_AUTOOPEN=1 SERIALTOOL_TEST_PORT=/dev/ttymxc2 \
#            SERIALTOOL_TEST_BAUD=115200 ./run.sh
#      另可远程预置 ~/.config/SerialTool/config.ini 切换 PortType（串口 "Serial Port"
#      / 网络 "TCP/UDP"）走 TCP 通路测试。原始源码 apps/SerialTool-src/ 不被修改。
#
# 依赖：先跑完 `bash emmc/scripts/br2-build.sh`（需要 output/host/bin/qmake 与 Qt5 库）
#
set -uo pipefail

NEW=/home/zhb/linux-projects/emmc
BR=$NEW/buildroot
SRC=$NEW/apps/SerialTool-src/SerialTool
WORK=$NEW/apps/build-serialtool
QMAKE=$BR/output/host/bin/qmake
# ★ 必须显式带交叉 spec（同 package/qt5/qt5.mk 的 QT5_QMAKE）；不带就会用宿主 x86-64 spec。
QSPEC="devices/linux-buildroot-g++"
BOARD=192.168.10.2
SSH="ssh -i /home/zhb/.ssh/id_rsa_board -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ConnectTimeout=20 -o LogLevel=ERROR"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

do_patch() {
	say "① 准备干净的工作副本"
	[ -d "$SRC" ] || die "找不到源码 $SRC"
	rm -rf "$WORK"; mkdir -p "$WORK"
	cp -a "$SRC/." "$WORK/"
	echo "  文件数: $(find $WORK -type f | wc -l)"

	say "② 打补丁：去掉 uitools 依赖 + 补掉 QUiLoader 用法"
	sed -i 's/^QT       += core gui widgets serialport network charts script uitools$/QT       += core gui widgets serialport network charts script/' "$WORK/SerialTool.pro"
	grep -n "^QT " "$WORK/SerialTool.pro" | sed 's/^/  /'
	python3 - "$WORK" <<'PY'
import sys, re, pathlib
work = pathlib.Path(sys.argv[1])
f = work / "src/views/scriptextension/scriptextensionview.cpp"
s = f.read_text(encoding="utf-8", errors="surrogateescape")

# 去掉 QUiLoader 头
s = s.replace("#include <QUiLoader>\n", "")
# 把 loadUi() 变成空实现（保留函数，避免调用点报错）
old = '''void ScriptExtensionView::loadUi(const QString &fileName)
{
    QFile uiFile(fileName);
    if (uiFile.open(QIODevice::ReadOnly)) {
        QUiLoader loader;
        QHBoxLayout *layout = new QHBoxLayout(this);
        QWidget *widget = loader.load(&uiFile, this);
        layout->addWidget(widget);
        setLayout(layout);
    }
}'''
new = '''void ScriptExtensionView::loadUi(const QString &fileName)
{
    // 本版本未编译 QtUiTools（Buildroot 2019.02 的 qt5tools 不含它），
    // 因此"用 .ui 自定义视图"这个高级功能在此构建里不可用；其余功能不受影响。
    Q_UNUSED(fileName);
    static bool warned = false;
    if (!warned) {
        warned = true;
        qWarning("SerialTool: .ui 自定义视图未启用（本构建无 QtUiTools）");
    }
}'''
if old in s:
    s = s.replace(old, new); print("  ✅ loadUi() 已替换为空实现")
else:
    print("  ⚠️ 没找到 loadUi() 原文，可能已打过补丁或版本不同")
f.write_text(s, encoding="utf-8", errors="surrogateescape")

# ============================================================================
# ②b 测试辅助钩子（★ 默认完全不生效，只作用于本次构建的工作副本）
#
# 为什么需要：SerialTool 的串口名**不写进配置**（只有 BaudRate 会保存），
# 端口只能从界面下拉框里选，而 openPort() 只由工具栏按钮触发。
# 板子上既没有键盘鼠标，内核又**没编 uinput**（无法注入触摸事件），
# 于是"打开端口"这一步无法远程完成 —— 每跑一次测试都要人上手点两下。
#
# 办法：加一个环境变量开关，设置时才自动打开指定端口；不设置时行为与官方版本一致。
#   SERIALTOOL_TEST_AUTOOPEN=1 SERIALTOOL_TEST_PORT=/dev/ttymxc2 SERIALTOOL_TEST_BAUD=115200 ./run.sh
# 这两个改动只有 8 行，去掉本段即恢复原样；原始源码 apps/SerialTool-src/ 不被修改。
# ============================================================================
mw = work / "src/mainwindow.cpp"
s = mw.read_text(encoding="utf-8", errors="surrogateescape")
anchor = "    loadConfig(); // 加载配置\n"
hook = anchor + '''
    // ---- 测试辅助（未设置 SERIALTOOL_TEST_AUTOOPEN 时完全不生效）----
    // 详见 emmc/scripts/build-serialtool.sh 里的说明。
    if (!qEnvironmentVariableIsEmpty("SERIALTOOL_TEST_AUTOOPEN")) {
        qInfo("SERIALTOOL_TEST_AUTOOPEN: 自动打开端口 %s",
              qPrintable(qEnvironmentVariable("SERIALTOOL_TEST_PORT",
                                              QStringLiteral("/dev/ttymxc2"))));
        openPort();
    }
'''
if "SERIALTOOL_TEST_AUTOOPEN" in s:
    print("  ⚠️ mainwindow.cpp 已含测试钩子，跳过")
elif anchor in s:
    s = s.replace(anchor, hook, 1)
    mw.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("  ✅ mainwindow.cpp: 已插入自动开端口测试钩子（env 控制）")
else:
    print("  ⚠️ mainwindow.cpp 找不到锚点 '    loadConfig(); // 加载配置'，测试钩子未插入")

sp = work / "src/port/serialport.cpp"
s = sp.read_text(encoding="utf-8", errors="surrogateescape")
old = '''bool SerialPort::open()
{
    QString name = ui->portNameBox->currentText().section(' ', 0, 0);
'''
new = '''bool SerialPort::open()
{
    QString name = ui->portNameBox->currentText().section(' ', 0, 0);

    // 测试辅助：允许用环境变量直接指定端口/波特率（板子上无法远程操作界面）
    const QString testDev = qEnvironmentVariable("SERIALTOOL_TEST_PORT");
    if (!testDev.isEmpty())
        name = testDev;
    const QString testBaud = qEnvironmentVariable("SERIALTOOL_TEST_BAUD");
    if (!testBaud.isEmpty()) {
        // ★ 顺序很关键（被坑过一次）：组合框的值变化会通过 currentTextChanged 信号
        //   反过来调用 setBaudRate()，所以必须**先设组合框、最后设波特率**，
        //   否则好不容易设好的 115200 会被组合框里的旧值覆盖，
        //   结果串口以非法波特率打开失败（现象：状态栏显示 CLOSED、RX 恒为 0）。
        //   另外用 setCurrentIndex(findText()) 而不是 setCurrentText()：
        //   后者在可编辑组合框上会弹开下拉列表，在触摸屏上一直挡着界面。
        const int bi = ui->baudRateBox->findText(testBaud);
        if (bi >= 0)
            ui->baudRateBox->setCurrentIndex(bi);
        serialPort->setBaudRate(testBaud.toInt());   // ← 必须放在最后
    }
'''
if "SERIALTOOL_TEST_PORT" in s:
    print("  ⚠️ serialport.cpp 已含测试钩子，跳过")
elif old in s:
    s = s.replace(old, new, 1)
    sp.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("  ✅ serialport.cpp: 已插入端口覆盖测试钩子（env 控制）")
else:
    print("  ⚠️ serialport.cpp 找不到 SerialPort::open() 锚点，测试钩子未插入")

# ---- ②b4 触摸适配：隐藏菜单栏 + 工具栏加"退出"按钮（linuxfb 下 QMenu 会卡死）----
# 现象：点 File/Edit 菜单后整个程序"卡死"（界面还在，但点哪都没反应，状态栏也变 CLOSED）。
# 原因：linuxfb 平台没有窗口管理器，QMenu 弹出菜单会**抢走输入抓取(grab)** 但窗口不可见
#   → 之后所有触摸事件都被那个看不见的弹窗吃掉 ✗。
#   （工具栏按钮、QComboBox 下拉都正常，唯独 QMenu 会出问题。）
# 修法：隐藏菜单栏，并在工具栏上加一个"退出"按钮顶替 File→Close。
#   env 开关 SERIALTOOL_TOUCH_UI=1 控制（默认不影响原版行为）。
mw2 = work / "src/mainwindow.cpp"
s = mw2.read_text(encoding="utf-8", errors="surrogateescape")
old = """    loadConfig(); // 加载配置
"""
new = """    // ★ 记下"默认布局" ✓：必须在 loadConfig() 里那句 restoreState() **之前** ✓
    //   （loadConfig 会把上次保存的布局恢复回来 ✗ —— 包括"面板被关掉"这种坏布局 ✗）
    const QByteArray atkDefaultDockState = saveState();

    loadConfig(); // 加载配置

    // 触摸适配（未设置 SERIALTOOL_TOUCH_UI 时不影响原行为）：
    // linuxfb 下 QMenu 弹出菜单会抢走输入抓取但不可见，表现为"点菜单就卡死" ✗，
    // 所以隐藏菜单栏，并在工具栏加一个"退出"按钮（等价于 File→Close，用于回到桌面）。
    if (!qEnvironmentVariableIsEmpty(\"SERIALTOOL_TOUCH_UI\")) {
        menuBar()->hide();

        // ★★ 禁止关闭面板 ✗✗（用户实测踩到的坑 ✓）
        //   面板标题栏右上角那个小 ✗ 会把整个 dock 关掉 ✗，
        //   而 SerialTool 界面上**没有任何办法把它调回来** ✗
        //   （菜单栏此时又是隐藏的 ✗ → 彻底"无法恢复" ✗，用户只能干瞪眼 ✗）
        //   而 linuxfb 是触摸屏 ✗，手指点在标题栏上误触那个 ✗ 的概率并不低 ✗
        //   → 直接拿掉"可关闭/可浮动"两个特性 ✓ 从根上不可能再被关掉 ✓
        for (QDockWidget *dk : findChildren<QDockWidget *>()) {
            dk->setFeatures(dk->features()
                            & ~QDockWidget::DockWidgetClosable
                            & ~QDockWidget::DockWidgetFloatable);
            dk->show();
        }
        // ★ 标签页同理 ✗：把 Text Tx/Rx / Terminal / Plot / File Transmit 的标签叉掉 ✗
        //   会只剩一片空白（File Transmit 页中间本来就没有可交互元素 ✗）
        //   → 看着像"界面死了/触摸坏了" ✗（也是实测踩到的 ✓）
        for (QTabWidget *tw : findChildren<QTabWidget *>())
            tw->setTabsClosable(false);

        QAction *quitAct = ui->toolBar1->addAction(QString::fromUtf8(\"退出\"));
        quitAct->setToolTip(QString::fromUtf8(\"关闭 SerialTool，回到桌面\"));
        connect(quitAct, &QAction::triggered, this, &QWidget::close);

        // ★★ 强制铺满屏幕 ✗✗（又一种"无法恢复"的根因 ✓，实测踩到 ✓）
        //   保存下来的 MainWindowGeometry 可能把窗口放到**屏幕外/屏幕上方** ✗
        //   → 工具栏整个看不见 ✗
        //   → 而工具栏上那个「退出」按钮是**唯一**能回到桌面的入口 ✗✗
        //   → 于是又变成"点哪都没反应、也退不出去" ✗（用户报的就是这个现象 ✓）
        //   linuxfb 没有窗口管理器 ✗，没人会把跑出去的窗口拉回来 ✗
        //   → 触摸模式下直接无视保存的几何，按屏幕尺寸铺满 ✓
        //   （本行在 loadConfig() 之后执行 ✓，所以能盖掉它恢复出来的几何 ✓）
        if (QScreen *atkScr = QGuiApplication::primaryScreen())
            setGeometry(atkScr->geometry());

        // 万一还是被拖乱了（面板能移动 ✓），给一个一键回默认布局的按钮 ✓
        QAction *resetAct = ui->toolBar1->addAction(QString::fromUtf8(\"重置布局\"));
        resetAct->setToolTip(QString::fromUtf8(\"把面板恢复成默认排列\"));
        connect(resetAct, &QAction::triggered, this, [this, atkDefaultDockState]() {
            restoreState(atkDefaultDockState);
            for (QDockWidget *dk : findChildren<QDockWidget *>())
                dk->show();
            if (QScreen *sc = QGuiApplication::primaryScreen())
                setGeometry(sc->geometry());
        });
    }
"""
if "SERIALTOOL_TOUCH_UI" in s:
    print("  ⚠️ mainwindow.cpp 已含触摸适配钩子，跳过")
elif old in s:
    s = s.replace(old, new, 1)
    # 确保 QMenuBar / QAction / QDockWidget / QTabWidget / QScreen 可用
    if "#include <QMenuBar>" not in s:
        s = s.replace('#include "mainwindow.h"',
                      '#include "mainwindow.h"\n#include <QMenuBar>\n#include <QAction>\n'
                      '#include <QDockWidget>\n#include <QTabWidget>\n'
                      '#include <QScreen>\n#include <QGuiApplication>', 1)
    mw2.write_text(s, encoding="utf-8", errors="surrogateescape")
    print('  OK: mainwindow.cpp 已加 隐藏菜单栏+退出按钮+★禁止关闭面板/标签页+重置布局')
else:
    print("  ERR: 找不到 loadConfig 锚点")

# ---- ②b3 默认端口优先选 ttymxc2（移植适配）----
# 板子上 ttymxc0 是**调试串口 console**，而 scanPort() 默认 setCurrentIndex(0)
# 永远选中列表第一项 = ttymxc0 → 用户顺手点"打开端口"就会去开控制台 ✗。
# 这里让它在没有历史选择时优先选 ttymxc2；可用 SERIALTOOL_DEFAULT_PORT 覆盖，
# 设为空字符串则恢复原行为。
sp2 = work / "src/port/serialport.cpp"
s = sp2.read_text(encoding="utf-8", errors="surrogateescape")
old = """        // 设置当前选中的端口
        if (!text.isEmpty() && (box->findText(text) != -1 || edited)) {
            box->setCurrentText(text);
        } else {
            box->setCurrentIndex(0);
        }"""
new = """        // 设置当前选中的端口
        // 移植适配：默认优先选 ttymxc2 —— 板子上 ttymxc0 是调试串口(console)，
        // 选中它再点"打开端口"会误开控制台。可用 SERIALTOOL_DEFAULT_PORT 覆盖。
        const QString preferPort =
            qEnvironmentVariable("SERIALTOOL_DEFAULT_PORT", QStringLiteral("ttymxc2"));
        if (!text.isEmpty() && (box->findText(text) != -1 || edited)) {
            box->setCurrentText(text);
        } else if (!preferPort.isEmpty()
                   && box->findText(preferPort, Qt::MatchStartsWith) != -1) {
            box->setCurrentIndex(box->findText(preferPort, Qt::MatchStartsWith));
        } else {
            box->setCurrentIndex(0);
        }"""
if "SERIALTOOL_DEFAULT_PORT" in s:
    print("  ⚠️ serialport.cpp 已含默认端口适配，跳过")
elif old in s:
    s = s.replace(old, new, 1)
    sp2.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("  ✅ serialport.cpp: 已加默认端口优先选 ttymxc2")
else:
    print("  ⚠️ serialport.cpp 找不到 scanPort 的锚点")

# ---- ②b2 启动即切换到指定视图（测试辅助）----
# 为什么需要：SerialTool 只把数据发给"可见"的视图
#   （ViewManager::receiveData 里有 if (view->isVisible())），
#   而板子上无法远程点击标签页 → 要测 Plot 波形就必须让它启动就停在那一页。
# 视图顺序：0=TextTx/Rx  1=Terminal  2=Plot  3=FileTransmit
vm = work / "src/views/viewmanager.cpp"
s = vm.read_text(encoding="utf-8", errors="surrogateescape")
old = """        connect(view, &AbstractView::transmitData, this, &ViewManager::transmitData);
        connect(view, &AbstractView::sendMessage, this, &ViewManager::dispatchMessage);
    }
}"""
new = """        connect(view, &AbstractView::transmitData, this, &ViewManager::transmitData);
        connect(view, &AbstractView::sendMessage, this, &ViewManager::dispatchMessage);
    }

    // 测试辅助（未设置 SERIALTOOL_TEST_VIEW 时完全不生效）：
    // 把指定视图提到最前。参数可以是序号（0=TextTx/Rx 1=Terminal 2=Plot 3=FileTransmit）
    // 或 iid 的子串（大小写不敏感，如 "plot"）。
    const QString wantView = qEnvironmentVariable("SERIALTOOL_TEST_VIEW");
    if (!wantView.isEmpty()) {
        bool numeric = false;
        const int wantIdx = wantView.toInt(&numeric);
        int i = 0;
        for (AbstractView *view : *m_views) {
            const bool hit = (numeric && wantIdx == i)
                    || (!numeric && view->iid().contains(wantView, Qt::CaseInsensitive));
            if (hit) {
                if (QDockWidget *d = qobject_cast<QDockWidget *>(view->parentWidget())) {
                    d->raise();
                    d->show();
                }
                // linuxfb 下 raise() 之后中央区经常不重绘（实测启动后一片空白）；
                // 手动点标签页时 Qt 会正确重绘，但程序化切换不会 -> 补一次显式重绘。
                QTimer::singleShot(400, window, [window, view]() {
                    view->update();
                    window->update();
                });
                break;
            }
            ++i;
        }
    }
}"""
if "#include <QTimer>" not in s:
    s = s.replace('#include "viewmanager.h"', '#include "viewmanager.h"\n#include <QTimer>', 1)
if "SERIALTOOL_TEST_VIEW" in s:
    print("  ⚠️ viewmanager.cpp 已含视图切换钩子，跳过")
elif old in s:
    s = s.replace(old, new, 1)
    vm.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("  ✅ viewmanager.cpp: 已插入启动视图切换钩子（env 控制）")
else:
    print("  ⚠️ viewmanager.cpp 找不到锚点")

# ---- ②c 最大化启动（测试辅助）----
# 7 寸 1024x600 屏上，SerialTool 默认窗口只有 715x430，四周大片黑边。
# 设了 SERIALTOOL_TEST_MAXIMIZE=1 就以最大化启动；不设则与原版完全一致。
mc = work / "src/main.cpp"
s = mc.read_text(encoding="utf-8", errors="surrogateescape")
# ★ 必须先加 <QScreen>：只 include <QApplication> 时 QScreen 只有前向声明，
#   调用 primaryScreen()->geometry() 会报"对不完全的类型 QScreen 的非法使用"
if "#include <QScreen>" not in s:
    s = s.replace('#include <QtWidgets/QApplication>',
                  '#include <QtWidgets/QApplication>\n#include <QScreen>', 1)
old = "    MainWindow w;\n    w.show();\n"
new = ("    MainWindow w;\n"
       "    // 测试辅助（未设置 SERIALTOOL_TEST_MAXIMIZE 时与原版一致）：\n"
       "    // 7 寸 1024x600 屏上默认窗口只有 715x430，四周黑边，故支持最大化启动。\n"
       "    if (!qEnvironmentVariableIsEmpty(\"SERIALTOOL_TEST_MAXIMIZE\")) {\n"
       "        // linuxfb 下 showMaximized() 不生效（窗口仍是 715x430）。\n"
       "        // ★ 必须在 show() **之前** resize，不能 show() 之后再 setGeometry：\n"
       "        //   实测后者会让**菜单栏和 dock 区域整块不被创建/绘制**（画面只剩工具栏\n"
       "        //   + 状态栏、中间一片空白）—— 窗口首次映射后再改几何，子控件不会重新布局。\n"
       "        if (QGuiApplication::primaryScreen())\n"
       "            w.resize(QGuiApplication::primaryScreen()->geometry().size());\n"
       "    }\n"
       "    w.show();\n")
if "SERIALTOOL_TEST_MAXIMIZE" in s:
    print("  ⚠️ main.cpp 已含最大化钩子，跳过")
elif old in s:
    s = s.replace(old, new, 1)
    mc.write_text(s, encoding="utf-8", errors="surrogateescape")
    print("  ✅ main.cpp: 已插入最大化启动钩子（env 控制）")
else:
    print("  ⚠️ main.cpp 找不到 'MainWindow w; w.show();' 锚点")
PY
}

do_build() {
	do_patch

	say "③ 用 Buildroot 的交叉 qmake 配置"
	[ -x "$QMAKE" ] || die "找不到 $QMAKE —— Qt5 还没编完？"
	"$QMAKE" -v 2>&1 | head -3 | sed 's/^/  /'
	(cd "$WORK" && "$QMAKE" -spec "$QSPEC" SerialTool.pro 2>&1 | tail -5)
	# 硬判据：QScintilla 的 feature 必须真的被 qmake 找到。
	# 找不到时 qmake 不报错（CONFIG += qscintilla2 静默失效），要到编译期才炸
	# "Qsci/qsciscintilla.h: No such file or directory"，所以这里先卡住。
	grep -q -- "-lqscintilla2_qt5" "$WORK/Makefile" \
		|| die "Makefile 里没有 -lqscintilla2_qt5 → QScintilla 的 .prf 没被 qmake 找到"
	echo "  ✅ QScintilla 已被 qmake 识别（-lqscintilla2_qt5 在 Makefile 里）"

	say "④ 编译（-j2）"
	(cd "$WORK" && make -j2 2>&1 | tail -25)
	local bin
	bin=$(find "$WORK" -maxdepth 2 -type f -name SerialTool -perm -u+x | head -1)
	[ -n "$bin" ] || die "编译结束但没找到可执行文件 SerialTool"
	file "$bin" | cut -c1-120 | sed 's/^/  /'
	file "$bin" | grep -q "ARM" || die "编出来的不是 ARM 二进制 —— qmake 的 spec 没生效！"
	ls -lh "$bin" | awk '{print "  大小: "$5}'
}

do_push() {
	say "⑤ 打包（二进制 + themes/language/config）+ 推到板子"
	local bin
	bin=$(find "$WORK" -maxdepth 2 -type f -name SerialTool -perm -u+x | head -1)
	[ -n "$bin" ] || die "先 build"

	STAGE=$NEW/apps/serialtool-stage
	rm -rf "$STAGE"; mkdir -p "$STAGE"
	cp "$bin" "$STAGE/SerialTool"
	for d in themes language config; do
		[ -d "$WORK/$d" ] && cp -a "$WORK/$d" "$STAGE/"
	done
	# 启动脚本：★ 应用用的是相对路径（themes/ language/），所以必须先 cd 进去
	cat > "$STAGE/run.sh" <<'EOF'
#!/bin/sh
# SerialTool 启动器（linuxfb + 触摸）
cd "$(dirname "$0")" || exit 1

# 内核 printk 会直接写进 /dev/fb0，在 Qt 画面上叠字/花屏 —— 只留 emergency 级别
dmesg -n 1 2>/dev/null || true
# fbcon 与 Qt 共用 /dev/fb0，启动前解绑，避免桌面被开机 logo 覆盖
sh /usr/bin/fbcon-off >/dev/null 2>&1 || true

# 无 GPU → 软件渲染
export QT_QPA_PLATFORM=linuxfb
# 触摸：GT911 走 evdev（显式指定 event1，板子上 event0/2 是按键）
export QT_QPA_GENERIC_PLUGINS=evdevtouch
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS=/dev/input/event1
export QT_QPA_FONTDIR=/usr/share/fonts
# 让它别去找 X11
unset DISPLAY

exec ./SerialTool "$@"
EOF
	chmod 755 "$STAGE/run.sh"
	echo "  打包内容:"; ls -l "$STAGE" | sed 's/^/    /'

	# 板子上 busybox tar 不支持 -z，所以这边压缩、那边 gunzip 后解包
	echo "  传输到板子 /opt/serialtool/ ..."
	( cd "$STAGE" && tar cf - . ) | gzip -c | \
		timeout 300 $SSH root@$BOARD 'mkdir -p /opt/serialtool && cd /opt/serialtool && gzip -d | tar xf - && chmod 755 run.sh SerialTool && ls -l /opt/serialtool | head -8'
	echo
	echo "  板子上确认："
	timeout 60 $SSH root@$BOARD 'export PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH; ls -l /opt/serialtool/ | head -8; echo "---"; file /opt/serialtool/SerialTool 2>/dev/null || true'
}

case "${1:-all}" in
build) do_build ;;
patch) do_patch ;;
push)  do_push ;;
all)   do_build && do_push ;;
*)     sed -n '2,12p' "$0"; exit 1 ;;
esac
