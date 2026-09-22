// qttest —— IMX6ULL + Qt5 Widgets 最小验证程序
//
// 目的（对应目标的第②步）：在一个程序里同时回答四个问题
//   1) Qt5 的 linuxfb 平台插件在 1024x600 上能不能起窗口
//   2) 触摸（GT911 / evdevtouch）能不能收到事件、坐标对不对
//   3) 字体渲染有没有问题（需要字体文件）
//   4) ★ 软件渲染的真实性能：每秒能跑多少帧、每帧画多久
//
// 用法（板子上）：
//   cd /opt/qttest && ./run.sh          # 屏幕上出现渐变背景 + 移动方块
//   点屏幕 → 命令行会打印触摸坐标，画面上留下红点
//   每秒打印一行 FPS / 平均绘制耗时
//
#include <QApplication>
#include <QWidget>
#include <QPainter>
#include <QLinearGradient>
#include <QTimer>
#include <QElapsedTimer>
#include <QMouseEvent>
#include <QList>
#include <QPoint>
#include <QScreen>
#include <QFontDatabase>
#include <QFont>
#include <QDebug>

class TestWidget : public QWidget
{
public:
    TestWidget()
    {
        setWindowTitle("Qt5 on IMX6ULL");
        setAttribute(Qt::WA_AcceptTouchEvents, true);
        setCursor(Qt::BlankCursor);        // 触摸屏没有鼠标指针更清爽
        m_fpsTimer.start();
        m_paintTimer.start();

        // 以 30fps 为目标持续重绘 —— 帧率上不去就说明性能不够
        QTimer *repaintTimer = new QTimer(this);
        connect(repaintTimer, &QTimer::timeout, this, [this]() {
            m_frames++;
            update();
        });
        repaintTimer->start(1000 / 30);

        // 每秒打印一次统计
        QTimer *statTimer = new QTimer(this);
        connect(statTimer, &QTimer::timeout, this, [this]() {
            const double elapsed = m_fpsTimer.elapsed() / 1000.0;
            const double avgPaint = m_frames > 0 ? (m_paintMs / m_frames) : 0.0;
            // ★ 存进成员，屏幕上那两行才会显示真实数值（否则永远是 0.0，
            //   而我要靠截图来判断性能，画面上的数字必须可信）
            m_lastFps = elapsed > 0 ? m_frames / elapsed : 0.0;
            m_lastAvgPaint = avgPaint;
            qInfo("STAT fps=%.1f frames=%d avg_paint=%.1fms clicks=%d size=%dx%d",
                  m_lastFps, m_frames, avgPaint, m_clicks, width(), height());
            m_frames = 0;
            m_paintMs = 0;
            m_fpsTimer.restart();
        });
        statTimer->start(1000);
    }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QElapsedTimer t;
        t.start();

        QPainter p(this);

        // 渐变背景（考较重的填充性能）
        QLinearGradient g(0, 0, width(), height());
        g.setColorAt(0.0, QColor(18, 28, 58));
        g.setColorAt(1.0, QColor(58, 18, 40));
        p.fillRect(rect(), g);

        // 移动色块（一眼看出卡不卡）
        const int step = m_totalFrames * 9;
        const int x = width() > 120 ? step % (width() - 120) : 0;
        p.fillRect(x, height() / 2 - 60, 120, 120, QColor(0, 200, 120));

        // 文字（验证字体）
        p.setPen(Qt::white);
        QFont f = p.font();
        f.setPointSize(30);
        p.setFont(f);
        p.drawText(rect().adjusted(0, -140, 0, 0), Qt::AlignCenter, "Qt5 Widgets OK");

        f.setPointSize(15);
        p.setFont(f);
        p.drawText(rect().adjusted(0, -40, 0, 0), Qt::AlignCenter,
                   QString("linuxfb  %1x%2   touches: %3").arg(width()).arg(height()).arg(m_clicks));
        p.drawText(rect().adjusted(0, 40, 0, 0), Qt::AlignCenter,
                   QString("fps(total)=%1   avg paint=%2 ms")
                       .arg(m_lastFps, 0, 'f', 1)
                       .arg(m_lastAvgPaint, 0, 'f', 1));

        // 触摸点
        p.setPen(Qt::NoPen);
        p.setBrush(QColor(255, 80, 80));
        for (int i = 0; i < m_points.size(); ++i)
            p.drawEllipse(m_points.at(i), 16, 16);

        m_paintMs += t.elapsed();
        m_totalFrames++;
    }

    void mousePressEvent(QMouseEvent *e) override
    {
        m_clicks++;
        m_points.append(e->pos());
        while (m_points.size() > 12)
            m_points.removeFirst();
        qInfo("TOUCH click #%d at (%d, %d)", m_clicks, e->pos().x(), e->pos().y());
        update();
    }

private:
    QList<QPoint> m_points;
    QElapsedTimer m_fpsTimer;
    QElapsedTimer m_paintTimer;
    int m_frames = 0;
    int m_totalFrames = 0;
    int m_clicks = 0;
    qint64 m_paintMs = 0;
    double m_lastFps = 0.0;
    double m_lastAvgPaint = 0.0;
};

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    qInfo("=== Qt5 环境 ===");
    qInfo("platform     : %s", qPrintable(app.platformName()));
    qInfo("screen       : %dx%d", app.primaryScreen()->size().width(),
          app.primaryScreen()->size().height());
    qInfo("depth        : %d bpp", app.primaryScreen()->depth());
    // ★ Qt5 里 QFontDatabase::families() 是**非静态成员函数**（Qt6 才改成静态），
    //   所以必须先建实例再调用 —— 直接写 QFontDatabase::families() 会编译失败：
    //   "没有对象无法调用成员函数 QStringList QFontDatabase::families(...) const"
    QFontDatabase fdb;
    qInfo("font families: %d", fdb.families().size());
    qInfo("Qt version   : %s", qVersion());

    TestWidget w;
    w.show();
    return app.exec();
}
