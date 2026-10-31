#include "mpris.h"
#include "sysvolume.h"

#include "appcontroller.h"
#include "playbackengine.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QVariant>

QString MprisPlayer::playbackStatus() const
{
    if (m_engine->idle() || m_engine->path().isEmpty())
        return QStringLiteral("Stopped");
    return m_engine->paused() ? QStringLiteral("Paused") : QStringLiteral("Playing");
}

QVariantMap MprisPlayer::metadata() const
{
    QVariantMap m;
    // A valid object path is required even when there is no real track list.
    m.insert(QStringLiteral("mpris:trackid"),
             QVariant::fromValue(QDBusObjectPath(
                 QStringLiteral("/org/mpris/MediaPlayer2/codec/track/current"))));
    const QString title = m_app->nowTitle().isEmpty() ? m_engine->mediaTitle()
                                                       : m_app->nowTitle();
    if (!title.isEmpty())
        m.insert(QStringLiteral("xesam:title"), title);
    const double dur = m_engine->duration();
    if (dur > 0)
        m.insert(QStringLiteral("mpris:length"), qlonglong(dur * 1'000'000.0));
    return m;
}

double MprisPlayer::volume() const
{
    // codec's volume IS the system sink (mpv sits at 100 + an OSD boost), so
    // that is what MPRIS reports and drives. Mapping it to mpv let
    // `playerctl volume 0.5` silently halve the audio under an OSD that still
    // read the system level — nothing in the UI showed or undid it.
    if (m_sys && m_sys->available())
        return m_sys->volume() / 100.0;
    return m_engine->volume() / 100.0; // no system volume: mpv 0..100
}

void MprisPlayer::setVolume(double v)
{
    if (m_sys && m_sys->available()) {
        const int delta = qRound(qBound(0.0, v, 1.0) * 100.0) - m_sys->volume();
        if (delta)
            m_sys->step(delta);
        return;
    }
    m_engine->setVolume(qBound(0.0, v, 1.0) * 100.0);
}

qlonglong MprisPlayer::position() const
{
    return qlonglong(m_engine->position() * 1'000'000.0);
}

// Transport goes through AppController (party sync, resume, cast all live there),
// never straight to the engine. Hyprland binds both Play and Pause to
// `playerctl play-pause`, so PlayPause is the one that matters, but Play/Pause
// are implemented correctly too by consulting the current paused state.
void MprisPlayer::PlayPause() { m_app->playPause(); }
void MprisPlayer::Play()      { if (m_engine->paused()) m_app->playPause(); }
void MprisPlayer::Pause()     { if (!m_engine->paused()) m_app->playPause(); }
void MprisPlayer::Next()      { m_app->playerNext(); }
void MprisPlayer::Previous()  { m_app->playerPrev(); }
void MprisPlayer::Stop()      { m_app->stopPlayback(); }

// Seek/SetPosition route through AppController (party-safe) like the transport.
// MPRIS uses microseconds; the Seeked signal reports the new position so clients
// (waybar, playerctl) update their scrub bar.
void MprisPlayer::Seek(qlonglong offset)
{
    const qlonglong now = position();
    m_app->seekBy(offset / 1'000'000.0);
    emit Seeked(qMax<qlonglong>(0, now + offset));
}

void MprisPlayer::SetPosition(const QDBusObjectPath &, qlonglong pos)
{
    m_app->seekTo(pos / 1'000'000.0);
    emit Seeked(pos);
}

// playerctl open <uri> → play it now (queues the rest if several), reusing the
// single-instance enqueue path.
void MprisPlayer::OpenUri(const QString &uri)
{
    if (!uri.isEmpty())
        m_app->playPaths({uri});
}

void MprisPlayer::emitPropertiesChanged()
{
    QVariantMap changed;
    changed.insert(QStringLiteral("PlaybackStatus"), playbackStatus());
    changed.insert(QStringLiteral("Metadata"), metadata());
    QDBusMessage msg = QDBusMessage::createSignal(
        QStringLiteral("/org/mpris/MediaPlayer2"),
        QStringLiteral("org.freedesktop.DBus.Properties"),
        QStringLiteral("PropertiesChanged"));
    msg << QStringLiteral("org.mpris.MediaPlayer2.Player") << changed << QStringList();
    QDBusConnection::sessionBus().send(msg);
}

int CodecIpc::Enqueue(const QStringList &paths)
{
    m_app->enqueuePaths(paths);
    return paths.size();
}
void CodecIpc::PlayNow(const QStringList &paths) { m_app->playPaths(paths); }
void CodecIpc::Present()                          { m_app->presentWindow(); }
QString CodecIpc::Display()
{
    return m_app->stage() == QLatin1String("chooser") ? QString() : m_app->display();
}
void CodecIpc::MoveTo(const QString &display)     { m_app->moveToDisplay(display); }
void CodecIpc::Front()                            { m_app->frontWindow(); }
void CodecIpc::Rescan()                           { m_app->newFilesArrived(); }

Mpris::Mpris(AppController *app, PlaybackEngine *engine, SysVolume *sys, QObject *parent)
    : QObject(parent)
{
    new MprisRoot(this);
    m_player = new MprisPlayer(this, app, engine, sys);

    QDBusConnection bus = QDBusConnection::sessionBus();
    // registerObject exports the adaptor interfaces attached to `this`.
    if (!bus.registerObject(QStringLiteral("/org/mpris/MediaPlayer2"), this))
        qWarning("codec: MPRIS registerObject failed");
    if (!bus.registerService(QStringLiteral("org.mpris.MediaPlayer2.codec")))
        qWarning("codec: MPRIS registerService failed (another instance?)");

    // codec's own control channel on its own object, so single-instance file
    // forwarding never rides the MPRIS interface. main.cpp checks whether
    // org.codec.App is already owned; the first instance to get here owns it.
    auto *ipcObj = new QObject(this);
    new CodecIpc(ipcObj, app);
    if (!bus.registerObject(QStringLiteral("/org/codec/App"), ipcObj))
        qWarning("codec: IPC registerObject failed");
    if (!bus.registerService(QStringLiteral("org.codec.App")))
        qWarning("codec: IPC registerService failed (another instance?)");

    // Refresh now-playing/status for waybar & friends on any state change.
    connect(app, &AppController::nowChanged, this,
            [this] { m_player->emitPropertiesChanged(); });
    connect(engine, &PlaybackEngine::pausedChanged, this,
            [this] { m_player->emitPropertiesChanged(); });
    connect(engine, &PlaybackEngine::idleChanged, this,
            [this] { m_player->emitPropertiesChanged(); });
}
