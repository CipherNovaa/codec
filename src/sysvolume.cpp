#include "sysvolume.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QRegularExpression>
#include <QStandardPaths>

static QString flagPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation)
           + QStringLiteral("/codec-osd-active");
}

SysVolume::SysVolume(QObject *parent)
    : QObject(parent)
{
    // Events arrive in bursts (a key held down = a dozen "change on sink");
    // one read per burst is plenty.
    m_refreshDebounce.setSingleShot(true);
    m_refreshDebounce.setInterval(40);
    connect(&m_refreshDebounce, &QTimer::timeout, this, &SysVolume::refresh);

    // The quickshell popup checks the flag's AGE (< ~2 s = codec owns it), so
    // it is touched every second while the player is up and simply goes stale
    // when it is not — a crash can never leave quickshell muted for good.
    m_flagTimer.setInterval(1000);
    connect(&m_flagTimer, &QTimer::timeout, this, &SysVolume::touchFlag);

    refresh();
    startWatch();
}

SysVolume::~SysVolume()
{
    if (m_watch) {
        m_watch->disconnect(this);
        m_watch->kill();
        m_watch->waitForFinished(500);
    }
    QFile::remove(flagPath());
}

void SysVolume::setOwnsOsd(bool on)
{
    if (on == m_ownsOsd)
        return;
    m_ownsOsd = on;
    if (on) {
        touchFlag();
        m_flagTimer.start();
    } else {
        m_flagTimer.stop();
        QFile::remove(flagPath());
    }
    emit ownsOsdChanged();
}

void SysVolume::touchFlag()
{
    QFile f(flagPath());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write("codec\n");
}

void SysVolume::startWatch()
{
    m_watch = new QProcess(this);
    m_watch->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_watch, &QProcess::readyReadStandardOutput, this, [this] {
        bool relevant = false;
        while (m_watch->canReadLine()) {
            const QByteArray line = m_watch->readLine();
            if (line.contains(" sink ") || line.contains(" server "))
                relevant = true;
        }
        if (relevant)
            m_refreshDebounce.start();
    });
    // pactl exits if PipeWire restarts; come back rather than go deaf.
    connect(m_watch, &QProcess::finished, this, [this] {
        QTimer::singleShot(3000, this, [this] {
            if (m_watch)
                m_watch->start(QStringLiteral("pactl"), {QStringLiteral("subscribe")});
        });
    });
    m_watch->start(QStringLiteral("pactl"), {QStringLiteral("subscribe")});
}

void SysVolume::refresh()
{
    // Never two reads in flight: a burst coalesces into one more read after.
    if (m_refreshing) {
        m_refreshAgain = true;
        return;
    }
    m_refreshing = true;
    auto *p = new QProcess(this);
    // A wpctl that never STARTS (not installed, PATH under a user unit) emits
    // errorOccurred and never finished — m_refreshing stayed latched and the
    // system volume was frozen for the session. A hung read is killed (which
    // does emit finished).
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart)
            return;
        p->deleteLater();
        m_refreshing = false;
        m_refreshAgain = false;
    });
    QTimer::singleShot(3000, p, [p] {
        if (p->state() != QProcess::NotRunning)
            p->kill();
    });
    connect(p, &QProcess::finished, this, [this, p](int code) {
        const QString out = QString::fromUtf8(p->readAllStandardOutput());
        p->deleteLater();
        m_refreshing = false;
        // "Volume: 0.45" or "Volume: 0.45 [MUTED]"
        static const QRegularExpression re(QStringLiteral("Volume:\\s*([0-9.]+)"));
        const auto m = re.match(out);
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (code == 0 && m.hasMatch() && now <= m_selfChangeUntil
            && qRound(m.captured(1).toDouble() * 100.0) != m_volume) {
            // A read that was in flight when we stepped: it predates our own
            // change and would undo the optimistic level (and PlayerView would
            // then drop the 100-200% boost the user just added). Read again
            // once our change has landed.
            QTimer::singleShot(int(m_selfChangeUntil - now) + 50, this, &SysVolume::refresh);
        } else if (code == 0 && m.hasMatch()) {
            const int vol = qRound(m.captured(1).toDouble() * 100.0);
            const bool mute = out.contains(QLatin1String("MUTED"));
            const bool diff = vol != m_volume || mute != m_muted || !m_available;
            m_volume = vol;
            m_muted = mute;
            m_available = true;
            if (diff) {
                emit changed();
                if (QDateTime::currentMSecsSinceEpoch() > m_selfChangeUntil)
                    emit changedExternally();
            }
        }
        if (m_refreshAgain) {
            m_refreshAgain = false;
            m_refreshDebounce.start();
        }
    });
    p->start(QStringLiteral("wpctl"),
             {QStringLiteral("get-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@")});
}

void SysVolume::step(int percent)
{
    if (percent == 0)
        return;
    m_selfChangeUntil = QDateTime::currentMSecsSinceEpoch() + 600;
    // Optimistic: the OSD moves with the wheel now; the watch confirms.
    m_volume = qBound(0, m_volume + percent, 100);
    if (percent > 0)
        m_muted = false;
    emit changed();
    const QString amount = QStringLiteral("%1%%2").arg(qAbs(percent))
                               .arg(percent > 0 ? QLatin1Char('+') : QLatin1Char('-'));
    if (percent > 0)
        QProcess::startDetached(QStringLiteral("wpctl"),
                                {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"),
                                 QStringLiteral("0")});
    // -l 1.0: never past 100% (the volume keys' own cap).
    QProcess::startDetached(QStringLiteral("wpctl"),
                            {QStringLiteral("set-volume"), QStringLiteral("-l"),
                             QStringLiteral("1.0"), QStringLiteral("@DEFAULT_AUDIO_SINK@"), amount});
}

// An absolute level. Relative wpctl steps add to a FLOAT volume, so a sink that
// read "97" (0.968) stepped +3 landed on 0.998 — "100" on the OSD, a hair quiet
// in the ear. The player's 100% detent sets the level outright instead.
void SysVolume::setLevel(int percent)
{
    percent = qBound(0, percent, 100);
    m_selfChangeUntil = QDateTime::currentMSecsSinceEpoch() + 600;
    const bool up = percent > m_volume;
    m_volume = percent;
    if (up)
        m_muted = false;
    emit changed();
    if (up)
        QProcess::startDetached(QStringLiteral("wpctl"),
                                {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"),
                                 QStringLiteral("0")});
    QProcess::startDetached(QStringLiteral("wpctl"),
                            {QStringLiteral("set-volume"), QStringLiteral("@DEFAULT_AUDIO_SINK@"),
                             QString::number(percent / 100.0, 'f', 2)});
}

void SysVolume::setMuted(bool on)
{
    if (on == m_muted)
        return;
    m_selfChangeUntil = QDateTime::currentMSecsSinceEpoch() + 600;
    m_muted = on;
    emit changed();
    QProcess::startDetached(QStringLiteral("wpctl"),
                            {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"),
                             on ? QStringLiteral("1") : QStringLiteral("0")});
}

void SysVolume::toggleMute()
{
    m_selfChangeUntil = QDateTime::currentMSecsSinceEpoch() + 600;
    m_muted = !m_muted;
    emit changed();
    QProcess::startDetached(QStringLiteral("wpctl"),
                            {QStringLiteral("set-mute"), QStringLiteral("@DEFAULT_AUDIO_SINK@"),
                             QStringLiteral("toggle")});
}
