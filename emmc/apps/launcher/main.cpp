/*
 * atk-launcher —— IMX6ULL 板子上的极简"桌面"
 *
 * 为什么需要：
 *   这块板子原来没有桌面环境（没有 X11/Wayland，Qt 直接画在 /dev/fb0 上）。
 *   一旦 SerialTool 退出，屏幕上就再没有程序接收触摸事件了 →
 *   现象就是"全部关掉之后触摸没反应"。所以需要一个常驻的、能响应触摸的
 *   "桌面"，从它上面点击启动应用的图标/按钮，应用退出后它再回来。
 *
 * 设计要点（都是踩过的坑换来的）：
 *   1) ★ 桌面**不自己拉起 SerialTool 子进程**，而是"退出"并让外层 shell 会话脚本
 *      （session.sh）按退出码决定跑谁。原因：evdev 的触摸事件会**发给所有打开
 *      该设备的进程**，桌面若同时存在就会和 SerialTool 抢事件（可能误触发重开）。
 *      让两者**互斥运行**最干净。
 *   2) 退出码约定：42 = 用户点了"启动 SerialTool"；其他 = 正常/异常退出。
 *   3) linuxfb 下 showFullScreen()/showMaximized() 都不可靠（实测窗口还是 715x430），
 *      所以用 setGeometry(屏幕几何) 显式铺满。
 *   4) 触摸设备显式指定（板子上 event0/2 是按键，只有 event1 是 GT911 触摸）。
 */
#include <QApplication>
#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QLabel>
#include <QTimer>
#include <QScreen>
#include <QFont>
#include <QDateTime>
#include <QNetworkInterface>
#include <QFrame>
#include <QFile>
#include <QByteArray>
#include <QList>
#include <QProcess>
#include <QElapsedTimer>
#include <QPainter>
#include <QPaintEvent>
#include <QDebug>

// 用户点了"启动 SerialTool"时用的退出码（session.sh 据此决定跑谁）
static const int EXIT_LAUNCH_SERIALTOOL = 42;

// ============================================================================
// ★ 槽位标识（OTA 整机 A/B 之后加的）
//
// 为什么需要：
//   a / b 两个槽装的系统内容**几乎一样** —— 光看桌面根本分不清现在跑的是哪个槽 ✗。
//   做了 OTA 之后这很致命：你分不清"升级到底生效了没有"、"现在是在新系统还是旧系统" ✗。
//
// 判据用 **/proc/mounts 里挂到 "/" 的设备**（权威 ✓，不依赖任何状态文件 ✓：
// 状态文件可能没挂上、可能被改过 ✗，而挂载表是内核说的 ✓）：
//     /dev/loop0       → b 槽（从 p2 上的 ext4 镜像 loop 起来的 ✓）
//     /dev/mmcblk1p2   → a 槽（p2 分区本体 ✓）
//
// 注意：`/slots/active` 是"**下次**启动进哪个槽" ✓，和"**现在**在哪个槽"是两码事 ✗，
//       两个都显示出来，刚做完 OTA 还没重启时你才不会困惑 ✓。
// ============================================================================
static QString runningSlot(QString *rootDev);

// ★ 时间是否可信（板子**没有 RTC 电池** ✗ → 每次开机都是 1970 ✗）
//   下限取 2020-01-01 ✓（和 /usr/bin/timesync.sh 里的 MIN_EPOCH 保持一致 ✓）
//   ★ 与其显示 "1970-01-01 02:02:17" 这种**假信息** ✗，不如老实说"时间未同步" ✓
static bool clockPlausible()
{
    // ★ 光看"时间大不大"是不够的 ✗：一个**假但合理**的时间（例如手动 date -s 设的 ✗）
    //   会骗过这个判断 ✗ → 从此以为已经对好了、再也不对时 ✗（实测被自己坑过一次 ✓）
    //   → 必须有 /slots/time-synced 这个"确实从网络取到过时间"的凭据 ✓✓
    if (!QFile::exists("/slots/time-synced"))
        return false;
    return QDateTime::currentSecsSinceEpoch() >= 1577836800LL;
}

// 开机多久了（分钟 ✓ 时间不可信时显示它 ✓ —— 这个信息永远是真的 ✓）
static int upMinutes()
{
    QFile f("/proc/uptime");
    if (!f.open(QIODevice::ReadOnly))
        return 0;
    return int(f.readLine().trimmed().split(' ').value(0).toDouble() / 60.0);
}

// 读状态文件的一行（读不到就返回空 ✓ 绝不能因为状态区异常就把桌面搞崩 ✗）
static QString readOneLine(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    return QString::fromUtf8(f.readLine()).trimmed();
}

// 从 key=value 形式的文件里取某个键（如 boot-info.txt 的 slot ✓）
static QString readKey(const QString &path, const QString &key)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QString();
    const QByteArray prefix = key.toLatin1() + '=';
    QByteArray line;
    // ★ 同样不能用 atEnd()（见 runningSlot 里的说明 ✗）
    while (!(line = f.readLine()).isEmpty()) {
        const QByteArray s = line.trimmed();
        if (s.startsWith(prefix))
            return QString::fromUtf8(s.mid(prefix.size())).trimmed();
    }
    return QString();
}

static QString runningSlot(QString *rootDev = nullptr)
{
    QFile f("/proc/mounts");
    if (f.open(QIODevice::ReadOnly)) {
        QByteArray line;
        // ★★ 这里**绝不能**写成 while (!f.atEnd()) ✗✗
        //   procfs 的 size() 恒为 0 → Qt 的 QFile::atEnd() 直接返回 true
        //   → 循环体一次都不执行 → 槽位永远判成 "?" ✗（实测踩到 ✓，屏幕上就显示 "? 槽" ✗）
        //   正确做法：一直 readLine() 直到读空 ✓
        while (!(line = f.readLine()).isEmpty()) {
            const QList<QByteArray> p = line.simplified().split(' ');
            if (p.size() >= 2 && p.at(1) == "/") {
                const QString dev = QString::fromLatin1(p.at(0));
                if (rootDev) *rootDev = dev;
                return dev.contains("loop") ? "b" : "a";
            }
        }
    }
    // 兜底：/slots/boot-info.txt 是 initramfs 启动时写的 ✓ 记的就是"本次启动的槽" ✓
    const QString bi = readKey("/slots/boot-info.txt", "slot");
    if (!bi.isEmpty())
        return bi.toLower();
    return QString("?");
}

// ============================================================================
// ★ WiFi 徽标：画"信号格 + SSID"（连带把 wlan0 的 IP 也显示出来 ✓）
//
// 为什么自己画格子而不是用符号/emoji ✗：
//   板子上的字体（DejaVu 子集）**没有 WiFi 图标字形** ✗，emoji 更是没有 ✗
//   → 用 QPainter 画 4 根柱子最稳 ✓ 任何字体环境都不会变成"豆腐块" ✓
//
// 数据来源：`wpa_cli -i wlan0 status`（取 ssid / wpa_state ✓）
//           `wpa_cli -i wlan0 signal_poll`（取 RSSI ✓）
//   ★ 这里**不用 `iw dev wlan0 link`** ✗ —— rtl8189fs + 4.1.15 下它恒报 Not connected ✗
//      （这个坑在本项目早先的文档里就记过 ✓，判定一律用 wpa_cli ✓）
// ============================================================================
class WifiBadge : public QWidget
{
public:
    explicit WifiBadge(QWidget *parent = nullptr) : QWidget(parent)
    {
        setMinimumHeight(30);
        // ★ 必须够宽 ✗：文字是 "SSID  信号 100%  10.23.61.95" ✓
        //   240 太窄会把 IP 截成 "10.2:" ✗（实测踩到 ✓ 界面不会报错、只会默默截断 ✗）
        setMinimumWidth(430);
    }

    // 同步跑一条命令并取回 stdout（wpa_cli 很快 ✓ 但还是要设超时 ✗ 免得界面卡死 ✗）
    static QString runCmd(const QString &prog, const QStringList &args, int timeoutMs = 1500)
    {
        QProcess p;
        p.start(prog, args);
        if (!p.waitForFinished(timeoutMs)) {
            p.kill();
            p.waitForFinished(300);
            return QString();
        }
        return QString::fromUtf8(p.readAllStandardOutput());
    }

    void poll()
    {
        QString ssid, state, rssi;
        // 网卡不在就直接显示"无 WiFi 网卡" ✓（别每 5 秒白跑两次 wpa_cli ✗）
        if (!QFile::exists("/sys/class/net/wlan0")) {
            m_state = 0;   // 0 = 没有网卡
            m_ssid.clear();
            m_rssi = 0;
            update();
            return;
        }
        const QString st = runCmd("/usr/sbin/wpa_cli", {"-i", "wlan0", "status"});
        for (const QString &l : st.split('\n')) {
            if (l.startsWith("ssid="))
                ssid = l.mid(5).trimmed();
            else if (l.startsWith("wpa_state="))
                state = l.mid(10).trimmed();
        }
        const QString sp = runCmd("/usr/sbin/wpa_cli", {"-i", "wlan0", "signal_poll"});
        for (const QString &l : sp.split('\n')) {
            if (l.startsWith("RSSI="))
                rssi = l.mid(5).trimmed();
        }
        m_rssi = rssi.toInt();
        // ★ 这个驱动（rtl8189fs 厂商驱动）报的 RSSI 是 **0-100 的信号质量** ✗ 不是 dBm ✗
        //   实测：`wpa_cli signal_poll` → RSSI=100 / LINKSPEED=0 / NOISE=0 / FREQUENCY=0
        //   → 所以**不能**在界面上写 "dBm" ✗（会显示成 "100 dBm" 这种假数据 ✗）
        //   这里按符号判断语义 ✓，两种驱动都能正确处理 ✓
        m_rssiIsPercent = (m_rssi > 0);
        m_ssid = ssid;
        m_state = (state == "COMPLETED" && !ssid.isEmpty()) ? 2 : 1;   // 2=已连接 1=有网卡未连接
        // IP（有就显示 ✓ 一眼看出 WiFi 到底通没通 ✓）
        //   ★ `ip -o` 的输出里是**多个连续空格** ✗ → 必须先 simplified() 再切 ✗
        //     （按单空格 section 会拿到空串 ✗ 实测就丢过 IP ✓）
        m_ip.clear();
        if (readOneLine("/sys/class/net/wlan0/operstate") == "up") {
            const QStringList w =
                runCmd("/sbin/ip", {"-4", "-o", "addr", "show", "wlan0"}).simplified().split(' ');
            const int i = w.indexOf("inet");
            if (i >= 0 && i + 1 < w.size())
                m_ip = w.at(i + 1).section('/', 0, 0);
        }
        update();
    }

    // 统一成 0-100 的"信号质量"分 ✓（同时兼容 dBm 和百分比两种上报 ✓）
    int quality() const
    {
        if (m_state != 2)
            return 0;
        if (m_rssiIsPercent)
            return qBound(0, m_rssi, 100);
        // dBm 到质量分的常用换算：-100 → 0，-50 → 100 ✓
        if (m_rssi >= -50)  return 100;
        if (m_rssi <= -100) return 0;
        return 2 * (m_rssi + 100);
    }

    int bars() const
    {
        const int q = quality();
        if (q >= 75) return 4;
        if (q >= 50) return 3;
        if (q >= 25) return 2;
        if (q > 0)   return 1;
        return 0;
    }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter g(this);
        g.setRenderHint(QPainter::Antialiasing, true);

        const int baseY = height() - 7;
        const int n = bars();
        const bool weak = (m_state == 2 && n <= 1);
        QColor on = weak ? QColor("#f0883e") : QColor("#3fb950");
        QColor off("#33415c");

        int x = 6;
        for (int i = 0; i < 4; ++i) {
            const int h = 7 + i * 5;
            g.setBrush(i < n ? on : off);
            g.setPen(Qt::NoPen);
            g.drawRoundedRect(QRect(x, baseY - h, 7, h), 2, 2);
            x += 10;
        }

        // 文字：SSID + 信号强度（或状态说明 ✓）
        QString txt;
        QColor tc;
        if (m_state == 0) {
            txt = QString::fromUtf8("无 WiFi 网卡");
            tc = QColor("#6b7f9c");
        } else if (m_state == 1) {
            txt = QString::fromUtf8("WiFi 未连接");
            tc = QColor("#d29922");
        } else {
            txt = m_ssid;
            if (m_rssi)
                txt += m_rssiIsPercent ? QString::fromUtf8("  信号 %1%").arg(m_rssi)
                                       : QString("  %1 dBm").arg(m_rssi);
            if (!m_ip.isEmpty())
                txt += QString("  %1").arg(m_ip);
            tc = QColor("#c9d7ea");
        }
        QFont f = font();
        f.setPointSize(12);
        g.setFont(f);
        g.setPen(tc);
        g.drawText(QRect(x + 6, 0, width() - x - 10, height()), Qt::AlignVCenter | Qt::AlignLeft, txt);
    }

private:
    int m_state = 1;   // 0=无网卡 1=有网卡未连接 2=已连接
    int m_rssi = 0;
    bool m_rssiIsPercent = true;   // ★ true=0-100 质量（本驱动 ✓） false=dBm ✓
    QString m_ssid;
    QString m_ip;
};

class Desktop : public QWidget
{
public:
    Desktop()
    {
        setWindowTitle("ATK Desktop");

        QPalette pal = palette();
        pal.setColor(QPalette::Window, QColor(18, 28, 48));
        setAutoFillBackground(true);
        setPalette(pal);

        QVBoxLayout *root = new QVBoxLayout(this);
        root->setContentsMargins(40, 14, 40, 14);
        root->setSpacing(10);

        // ── ★★ 槽位横幅：全场最显眼的东西，a/b 槽一眼可分 ──
        //   a 槽 = 绿   b 槽 = 橙红    （和蓝色按钮区分开 ✓ 隔两米也能认出来 ✓）
        m_slot = runningSlot(&m_rootDev);
        const bool isB = (m_slot == "b");

        m_banner = new QLabel(this);
        m_banner->setAlignment(Qt::AlignCenter);
        {
            QFont bf = m_banner->font();
            bf.setPointSize(24);
            bf.setBold(true);
            m_banner->setFont(bf);
            m_banner->setStyleSheet(QString("QLabel { background-color: %1; color: #ffffff;"
                                            " border-radius: 12px; padding: 8px 16px; }")
                                        .arg(isB ? "#9a3412" : "#0b6b3a"));
            // ★ 文字**不能只在这里拼一次** ✗：
            //   launcher 由 S12 启动（约 uptime 8s）✗，而 S99otaconfirm 要到 uptime ~42s
            //   才把 tries 清 0 ✓ → 一次性快照会一直显示"试用中 tries=N"的**过期信息** ✗
            //   （实测就显示过 "试用中 tries=2" ✗ 而实际早已确认 ✓）
            //   → 交给 refreshBanner() 定时刷新 ✓，顺带让"下次启动 → X 槽"实时更新 ✓
            refreshBanner();
        }
        root->addWidget(m_banner);

        // ── 标题 ──
        QLabel *title = new QLabel(QString::fromUtf8("zhanghaibin  ·  IMX6ULL 桌面"), this);
        QFont tf = title->font();
        tf.setPointSize(20);
        tf.setBold(true);
        title->setFont(tf);
        title->setStyleSheet("color: #e8f0ff;");
        title->setAlignment(Qt::AlignCenter);
        root->addWidget(title);

        root->addStretch(1);

        // ── 大按钮：启动 SerialTool（触摸友好：480x170）──
        m_btn = new QPushButton(QString::fromUtf8("▶   启动 SerialTool"), this);
        m_btn->setMinimumSize(520, 170);
        m_btn->setMaximumSize(560, 190);
        QFont bf2 = m_btn->font();
        bf2.setPointSize(26);
        bf2.setBold(true);
        m_btn->setFont(bf2);
        m_btn->setStyleSheet(
            "QPushButton { background-color: #1f6feb; color: white;"
            "              border: 3px solid #58a6ff; border-radius: 18px; }"
            "QPushButton:pressed { background-color: #388bfd; border-color: #a5d6ff; }");
        connect(m_btn, &QPushButton::clicked, this, [this]() {
            qInfo("launcher: 用户点击了启动 SerialTool");
            // 直接退出，由 session.sh 去跑 SerialTool（见文件头说明第 1 条）
            QCoreApplication::exit(EXIT_LAUNCH_SERIALTOOL);
        });

        QHBoxLayout *btnRow = new QHBoxLayout;
        btnRow->addStretch(1);
        btnRow->addWidget(m_btn);
        btnRow->addStretch(1);
        root->addLayout(btnRow);

        // ── ★ 一键升级（OTA）按钮 ──
        //   为什么是"两次点击"而不是真的按一下就升 ✗：
        //     升级会**写另一个槽并重启** ✗，误触代价太大 ✗
        //     → 第一次点"检查更新" ✓ 只有真发现新版本，按钮才变成"立即升级到 X" ✓
        //       第二次点才真的升 ✓（这也是 99% 场景下的一次点击 ✓）
        m_ota = new QPushButton(QString::fromUtf8("检查更新"), this);
        m_ota->setMinimumHeight(56);
        m_ota->setMinimumWidth(360);   // ★ 必须给最小宽度 ✗ 否则按钮缩成文字那么宽、不好按 ✗
        m_ota->setMaximumWidth(560);
        QFont of = m_ota->font();
        of.setPointSize(16);
        of.setBold(true);
        m_ota->setFont(of);
        m_ota->setStyleSheet(otaStyle(false));
        connect(m_ota, &QPushButton::clicked, this, &Desktop::onOtaClicked);

        QHBoxLayout *otaRow = new QHBoxLayout;
        otaRow->addStretch(1);
        otaRow->addWidget(m_ota);
        otaRow->addStretch(1);
        root->addLayout(otaRow);

        // 升级过程/结果/失败原因都显示在这里 ✓（★ 失败绝不能只显示"失败" ✗ 要给出原因 ✓）
        m_otaMsg = new QLabel(QString(), this);
        m_otaMsg->setAlignment(Qt::AlignCenter);
        m_otaMsg->setWordWrap(true);
        QFont mf = m_otaMsg->font();
        mf.setPointSize(12);
        m_otaMsg->setFont(mf);
        m_otaMsg->setMinimumHeight(18);
        setOtaMsg(QString::fromUtf8("在 A 槽时可一键升级（会写入另一个槽，重启后生效）"));
        root->addWidget(m_otaMsg);

        root->addStretch(1);

        // ── WiFi 徽标（信号格 + SSID + IP）──
        m_wifi = new WifiBadge(this);
        QHBoxLayout *wifiRow = new QHBoxLayout;
        wifiRow->addStretch(1);
        wifiRow->addWidget(m_wifi);
        wifiRow->addStretch(1);
        root->addLayout(wifiRow);

        // ── 状态栏（IP / 时间 / 槽位）──
        m_status = new QLabel(this);
        m_status->setAlignment(Qt::AlignCenter);
        QFont sf = m_status->font();
        sf.setPointSize(13);
        m_status->setFont(sf);
        m_status->setStyleSheet("color: #9fb3d1;");
        root->addWidget(m_status);

        QLabel *hint = new QLabel(
            QString::fromUtf8("提示：SerialTool 里点工具栏右侧的「退出」按钮，就会回到这个桌面"), this);
        hint->setAlignment(Qt::AlignCenter);
        QFont hf = hint->font();
        hf.setPointSize(12);
        hint->setFont(hf);
        hint->setStyleSheet("color: #6b7f9c;");
        root->addWidget(hint);

        // WiFi 每 5 秒刷一次 ✓（wpa_cli 很快 ✓ 不会拖慢界面 ✓）
        QTimer *wt = new QTimer(this);
        connect(wt, &QTimer::timeout, this, [this]() { m_wifi->poll(); });
        wt->start(5000);
        QTimer::singleShot(1500, this, [this]() { m_wifi->poll(); });

        QTimer *t = new QTimer(this);
        connect(t, &QTimer::timeout, this, &Desktop::refresh);
        t->start(1000);
        refresh();

        // ★ 对时兜底 ✓：S97timesync 的后台任务万一没成/早死 ✗，桌面每 5 分钟再试一次 ✓
        //   （只在时间仍不可信时才拉 ✓ 一次就一个 HTTP 请求 ✓ 开销可忽略 ✓）
        QTimer *tt = new QTimer(this);
        connect(tt, &QTimer::timeout, this, [this]() {
            if (!clockPlausible()) {
                qInfo("launcher: 时间仍不可信 → 后台再试一次对时");
                QProcess::startDetached("/usr/bin/timesync.sh", QStringList() << "--quiet");
            }
        });
        tt->start(5 * 60 * 1000);

        // 横幅每 2 秒刷新一次 ✓（tries 会在开机后由确认脚本清零 ✓ 必须能自己纠正过来 ✓）
        QTimer *bt = new QTimer(this);
        connect(bt, &QTimer::timeout, this, [this]() { refreshBanner(); });
        bt->start(2000);

        // 定期整屏重绘（自愈）：
        //   内核的 fbcon 控制台和 Qt 共用同一块 /dev/fb0 —— 任何往控制台写的东西
        //   （printk、init 脚本的 echo、驱动加载信息）都会直接盖在桌面上。
        //   平时桌面只重画"时钟"那一小块，被盖的区域永远不回血，
        //   现象就是"桌面上残留着开机 logo 或半截文字"。
        //   所以每 2 秒整屏重绘一次（软件渲染约 12ms，开销可忽略）。
        QTimer *heal = new QTimer(this);
        connect(heal, &QTimer::timeout, this, [this]() { update(); });
        heal->start(2000);

        // 启动早期（init 的 S12，约 7 秒）Qt 窗口常常拿不到有效的 expose，
        // 于是 update() 变成空操作 —— 现象是"桌面进程在跑、但屏幕一直停在开机 logo"。
        // 这里用 resize 抖动在启动后两次强制触发完整重绘，与启动时机解耦。
        for (int delay : {3000, 10000}) {
            QTimer::singleShot(delay, this, [this]() {
                const QSize g = size();
                resize(g.width() + 1, g.height());
                resize(g);
                update();
            });
        }

        // ★ 自检钩子：ATK_OTA_AUTOTEST=1 时，启动后自动触发一次"检查更新" ✓
        //   为什么需要：这个板子只有触摸输入 ✗，**没法从 SSH 点按钮** ✗
        //   → 想验证"发现新版本"这个界面状态就只能靠它 ✓（实测就是这么验的 ✓）
        //   平时不设这个环境变量就完全不生效 ✓ 对正常使用零影响 ✓
        //   ATK_OTA_AUTOTEST=1 → 只点一次 ✓
        //   ATK_OTA_AUTOTEST=2 → **连点两次（相隔 150ms）** ✓ 用来验证"防重复触发"的两道闸 ✓✓
        //                         （模拟"一次触摸同时产生触摸+鼠标事件"的真实故障 ✗）
        const QByteArray autotest = qgetenv("ATK_OTA_AUTOTEST");
        if (autotest == "1" || autotest == "2") {
            qInfo("launcher: ATK_OTA_AUTOTEST=%s → 4 秒后自动点击（2=连点两次）",
                  autotest.constData());
            QTimer::singleShot(4000, this, [this]() { onOtaClicked(); });
            if (autotest == "2")
                QTimer::singleShot(4150, this, [this]() { onOtaClicked(); });
        }

        // ★ linuxfb 下 showFullScreen()/showMaximized() 不可靠，显式铺满
        show();
        if (QScreen *scr = QGuiApplication::primaryScreen())
            setGeometry(scr->geometry());
    }

private:
    // ---- 一键升级（OTA）----
    //   状态机：Idle →(点) Busy → UpToDate（几秒后回 Idle）
    //                        → Ready →(点) Busy → Done →(点) 重启
    //                        → Blocked / Error（回 Idle 可重试 ✓）
    enum OtaState { Idle, Busy, UpToDate, Ready, Done, Blocked, Error };

    static QString otaStyle(bool hot)
    {
        if (hot)
            return "QPushButton { background-color: #9a6700; color: white;"
                   " border: 2px solid #d29922; border-radius: 12px; }"
                   "QPushButton:pressed { background-color: #bb8009; }"
                   "QPushButton:disabled { background-color: #2b3038; color: #8b9bb4;"
                   " border: 2px solid #3d444d; }";
        return "QPushButton { background-color: #21262d; color: #c9d7ea;"
               " border: 2px solid #3d444d; border-radius: 12px; }"
               "QPushButton:pressed { background-color: #30363d; }"
               "QPushButton:disabled { background-color: #1b1f26; color: #6b7f9c;"
               " border: 2px solid #2d333b; }";
    }

    void setOtaMsg(const QString &s, const QString &color = "#8b9bb4")
    {
        m_otaMsg->setText(s);
        m_otaMsg->setStyleSheet(QString("color: %1;").arg(color));
    }

    void resetOtaButton()
    {
        m_otaState = Idle;
        m_ota->setEnabled(true);
        m_ota->setText(QString::fromUtf8("检查更新"));
        m_ota->setStyleSheet(otaStyle(false));
    }

    void onOtaClicked()
    {
        // ★★ 防"一次触摸被当成两次点击" ✗✗（这是本页最危险的地方 ✓）
        //
        //  事实（实测日志 ✓）：Qt5 的 linuxfb 集成会**无条件**建一个 evdev 鼠标管理器 ✗
        //    → 它把**触摸屏自己**也认成鼠标 ✗
        //      （日志：Found new-style touchscreen at event1 → Adding mouse at event1 ✗）
        //    → 同一个 tap 会同时产生"触摸事件"和"鼠标事件" ✗ → 按钮可能被点两次 ✗
        //  这个现象**改之前就存在** ✓（不是本次引入的 ✗），
        //  以前点两次同一个按钮无所谓 ✓；但现在：
        //    "检查更新" 的第二次触发正好按在刚变出来的 "立即升级" 上 ✗✗ → 直接开始升级 ✗
        //
        //  所以两道闸：① 900ms 内的重复点击直接丢弃 ✓
        //             ② 刚变成"可升级"的头 1.2 秒内不允许真的升级 ✓（必须人再点一次 ✓）
        qInfo("launcher: OTA 按钮被点击（state=%d 文本=%s）", (int)m_otaState, qPrintable(m_ota->text()));
        if (m_otaClickGuard.isValid() && m_otaClickGuard.elapsed() < 900) {
            qInfo("launcher: → 忽略（距上次点击仅 %lld ms，判为同一次触摸的双重触发）",
                  (long long)m_otaClickGuard.elapsed());
            return;
        }
        m_otaClickGuard.restart();

        if (m_otaState == Ready && (!m_otaReadyGuard.isValid() || m_otaReadyGuard.elapsed() < 1200)) {
            qInfo("launcher: → 忽略（新版本刚出现，防止顺手就被点掉）");
            return;
        }

        switch (m_otaState) {
        case Idle:  startOta({"check"}); break;
        case Ready: startOta({"do"}); break;
        case Done:  startOta({"reboot"}); break;
        default:    break;   // Busy / UpToDate / Blocked / Error 期间忽略点击 ✓
        }
    }

    void startOta(const QStringList &args)
    {
        if (m_otaProc) {
            m_otaProc->deleteLater();
            m_otaProc = nullptr;
        }
        m_otaOut.clear();
        m_otaNote.clear();
        m_otaState = Busy;
        m_ota->setEnabled(false);
        m_ota->setStyleSheet(otaStyle(false));

        if (args.contains("check")) {
            m_ota->setText(QString::fromUtf8("检查中…"));
            setOtaMsg(QString::fromUtf8("正在从服务器取清单…"));
        } else if (args.contains("do")) {
            m_ota->setText(QString::fromUtf8("升级中…请勿断电"));
            setOtaMsg(QString::fromUtf8("开始升级…"), "#d29922");
        } else {
            m_ota->setText(QString::fromUtf8("重启中…"));
        }

        m_otaProc = new QProcess(this);
        m_otaProc->setProcessChannelMode(QProcess::MergedChannels);
        connect(m_otaProc, &QProcess::readyRead, this, [this]() { consumeOtaOutput(); });
        connect(m_otaProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this](int, QProcess::ExitStatus) { onOtaFinished(); });
        m_otaProc->start("/usr/bin/ota-upgrade.sh", args);
    }

    // 累积输出 + 实时显示进度 + 抓 OTA_NOTE ✓
    //   ★ 进程结束时必须再调一次 ✗：readyRead 不保证把收尾数据都发完 ✓
    void consumeOtaOutput()
    {
        if (!m_otaProc)
            return;
        const QString s = QString::fromUtf8(m_otaProc->readAll());
        if (s.isEmpty())
            return;
        m_otaOut += s;
        for (const QString &l : s.split('\n')) {
            const QString t = l.trimmed();
            if (t.startsWith("OTA_PROGRESS"))
                setOtaMsg(t.mid(QString("OTA_PROGRESS").length()).trimmed(), "#d29922");
            else if (t.startsWith("OTA_NOTE"))
                m_otaNote = t.mid(QString("OTA_NOTE").length()).trimmed();
        }
    }

    void onOtaFinished()
    {
        consumeOtaOutput();

        // ota-upgrade.sh 保证"结论"是一行固定 token ✓（Qt 侧绝不去解析中文文案 ✗）
        //   ★★ 必须跳过 OTA_NOTE / OTA_PROGRESS ✗✗
        //      ota-upgrade.sh 在有警告时会**先**输出一行 OTA_NOTE ✓
        //      不跳过的话解析就停在那一行 ✗ → 界面显示"升级失败：⚠" ✗（实测踩到 ✓）
        QString tok, a1, a2, rest;
        for (const QString &l : m_otaOut.split('\n')) {
            const QString t = l.trimmed();
            if (!t.startsWith("OTA_") || t.startsWith("OTA_PROGRESS") || t.startsWith("OTA_NOTE"))
                continue;
            tok = t.section(' ', 0, 0);
            a1 = t.section(' ', 1, 1);
            a2 = t.section(' ', 2, 2);
            rest = t.mid(tok.length()).trimmed();   // ★ 错误信息可能含空格 ✓ 不能只取第一个词 ✗
            break;
        }
        qInfo("launcher: OTA 结果 token=%s a1=%s a2=%s", qPrintable(tok), qPrintable(a1), qPrintable(a2));

        if (tok == "OTA_AVAILABLE") {
            m_otaState = Ready;
            m_otaReadyGuard.restart();   // ★ 配合 onOtaClicked 的第二道闸 ✓
            m_ota->setEnabled(true);
            m_ota->setText(QString::fromUtf8("立即升级到 %1").arg(a2));
            m_ota->setStyleSheet(otaStyle(true));
            QString m = QString::fromUtf8("发现新版本：%1 → %2（写入另一个槽，重启后生效）")
                            .arg(a1.isEmpty() ? QString::fromUtf8("无记录") : a1, a2);
            if (!m_otaNote.isEmpty())
                m += QString::fromUtf8("\n") + m_otaNote;
            setOtaMsg(m, "#d29922");
        } else if (tok == "OTA_UP_TO_DATE") {
            m_otaState = UpToDate;
            m_ota->setEnabled(false);
            m_ota->setText(QString::fromUtf8("已是最新（%1）").arg(a1));
            setOtaMsg(QString::fromUtf8("当前已是最新版本，无需升级 ✓"), "#3fb950");
            QTimer::singleShot(4000, this, [this]() {
                if (m_otaState == UpToDate) {
                    resetOtaButton();
                    setOtaMsg(QString::fromUtf8("在 A 槽时可一键升级（会写入另一个槽，重启后生效）"));
                }
            });
        } else if (tok == "OTA_BLOCKED_SLOT") {
            m_otaState = Blocked;
            m_ota->setEnabled(false);
            m_ota->setText(QString::fromUtf8("当前在 %1 槽，无法升级").arg(a1.toUpper()));
            setOtaMsg(QString::fromUtf8("★ 升级必须从 A 槽发起 ✗：客户端不会把正在运行的根覆盖掉 ✗。"
                                        "回 A 槽：在串口/SSH 执行  echo a > /slots/active && reboot"),
                      "#d29922");
        } else if (tok == "OTA_DONE") {
            m_otaState = Done;
            m_ota->setEnabled(true);
            m_ota->setText(QString::fromUtf8("重启进入新系统"));
            m_ota->setStyleSheet(otaStyle(true));
            QString m = QString::fromUtf8("升级完成：已写入另一个槽（版本 %1）✓ 点按钮重启生效").arg(a1);
            if (!m_otaNote.isEmpty())
                m += QString::fromUtf8("\n") + m_otaNote;
            setOtaMsg(m, "#3fb950");
        } else {
            m_otaState = Error;
            m_ota->setEnabled(true);
            m_ota->setText(QString::fromUtf8("重试"));
            // ★ 用 rest 而不是 a1 ✗：像 "[ota] ✗ 没有验签工具 → 拒绝升级 ✗" 这种带空格的信息
            //   只取第一个词会显示成 "[ota]" 这种没用的东西 ✗
            setOtaMsg(rest.isEmpty() ? QString::fromUtf8("升级失败（无输出）")
                                     : QString::fromUtf8("升级失败：%1").arg(rest),
                      "#f85149");
        }
    }

    // 横幅文字随状态**实时**更新 ✓（tries / 下次启动 都会变 ✓）
    void refreshBanner()
    {
        const QString active = readOneLine("/slots/active");
        // ★ 版本优先取"**本槽 rootfs 自带的**" /etc/atk-version ✓✓
        //   为什么：/slots/ota-version 是**两个槽共用的一个文件** ✗
        //   → OTA 写入 b 之后、再回滚到 a，那个文件说的还是新版本 ✗
        //   → 屏幕会显示"a 槽 = 新版本"这种**假信息** ✗（和"分不清槽位"是同一类毛病 ✗）
        //   真实固件都是把版本号打在**自己的 rootfs 里** ✓（build-image-on-board.sh 负责写入 ✓）
        QString ver = readOneLine("/etc/atk-version");
        if (ver.isEmpty())
            ver = readOneLine("/slots/ota-version");   // 兜底（老镜像没有这个文件 ✓）
        const QString tries = readOneLine("/slots/tries");
        QString txt = QString("%1 槽运行中").arg(m_slot.toUpper());
        if (!ver.isEmpty())
            txt += QString("    ·    版本 %1").arg(ver);
        // 刚做完 OTA 还没重启时，这行最能说明问题 ✓
        if (!active.isEmpty() && active != m_slot)
            txt += QString("    ·    下次启动 → %1 槽").arg(active.toUpper());
        // tries > 0 表示"本次是试用启动，尚未被确认" ✓ 排障时很有用 ✓
        if (!tries.isEmpty() && tries != "0")
            txt += QString("    ·    试用中 tries=%1").arg(tries);
        if (m_banner->text() != txt)
            m_banner->setText(txt);
    }

    void refresh()
    {
        QString ip = "no-ip";
        for (const QHostAddress &a : QNetworkInterface::allAddresses()) {
            if (a.protocol() == QAbstractSocket::IPv4Protocol && !a.isLoopback()) {
                ip = a.toString();
                break;
            }
        }
        // 时间：可信才显示日期时间 ✓ 不可信就显示"开机多久"并明说没同步 ✓
        //   （★ 绝不显示 1970 那种假信息 ✗ —— 这跟"分不清槽位"是同一类毛病 ✗）
        QString when;
        if (clockPlausible())
            when = QDateTime::currentDateTime().toString("yyyy-MM-dd hh:mm:ss");
        else
            when = QString::fromUtf8("已开机 %1 分 · 时间未同步").arg(upMinutes());

        // 状态行也带上槽位 ✓（横幅万一被内核输出盖住，这里还能核对 ✓）
        m_status->setText(QString("%1     %2     %3 槽").arg(ip, when, m_slot.toUpper()));
    }

    QPushButton *m_btn = nullptr;
    QLabel *m_status = nullptr;
    QLabel *m_banner = nullptr;
    QPushButton *m_ota = nullptr;
    QLabel *m_otaMsg = nullptr;
    QProcess *m_otaProc = nullptr;
    QString m_otaOut;
    QString m_otaNote;
    OtaState m_otaState = Idle;
    QElapsedTimer m_otaClickGuard;
    QElapsedTimer m_otaReadyGuard;
    WifiBadge *m_wifi = nullptr;
    QString m_slot;
    QString m_rootDev;
};

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    qInfo("=== ATK 桌面 ===");
    qInfo("platform : %s", qPrintable(app.platformName()));
    if (QScreen *s = QGuiApplication::primaryScreen())
        qInfo("screen   : %dx%d", s->geometry().width(), s->geometry().height());

    Desktop d;
    return app.exec();
}
