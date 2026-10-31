#pragma once

// MPRIS (org.mpris.MediaPlayer2) so the compositor's media keys drive codec:
// Hyprland binds XF86AudioPlay/Pause/Next/Prev → `playerctl`, which needs an
// MPRIS player to talk to. Without this the OFA remote's dedicated Play/Pause/
// Next/Prev buttons (Hyprland grabs them before codec) do nothing. Bonus: codec
// then shows up as now-playing in waybar / lockscreens.

#include <QObject>
#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QVariantMap>
#include <QStringList>

class AppController;
class PlaybackEngine;
class SysVolume;

// org.mpris.MediaPlayer2 — the root interface.
class MprisRoot : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(QString Identity READ identity)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry)
    Q_PROPERTY(bool CanQuit READ canQuit)
    Q_PROPERTY(bool CanRaise READ canRaise)
    Q_PROPERTY(bool HasTrackList READ hasTrackList)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes)
    Q_PROPERTY(QStringList SupportedMimeTypes READ supportedMimeTypes)
public:
    explicit MprisRoot(QObject *parent) : QDBusAbstractAdaptor(parent) {}
    QString identity() const { return QStringLiteral("codec"); }
    QString desktopEntry() const { return QStringLiteral("codec"); }
    bool canQuit() const { return false; }
    bool canRaise() const { return false; }
    bool hasTrackList() const { return false; }
    QStringList supportedUriSchemes() const { return {}; }
    QStringList supportedMimeTypes() const { return {}; }
public slots:
    void Raise() {}
    void Quit() {}
};

// org.mpris.MediaPlayer2.Player — transport + status.
class MprisPlayer : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(double Rate READ rate)
    Q_PROPERTY(double MinimumRate READ rate)
    Q_PROPERTY(double MaximumRate READ rate)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(bool CanGoNext READ canControl)
    Q_PROPERTY(bool CanGoPrevious READ canControl)
    Q_PROPERTY(bool CanPlay READ canControl)
    Q_PROPERTY(bool CanPause READ canControl)
    Q_PROPERTY(bool CanSeek READ canSeek)
    Q_PROPERTY(bool CanControl READ canControl)
public:
    MprisPlayer(QObject *parent, AppController *app, PlaybackEngine *engine,
                SysVolume *sys = nullptr)
        : QDBusAbstractAdaptor(parent), m_app(app), m_engine(engine), m_sys(sys) {}

    QString playbackStatus() const;
    double rate() const { return 1.0; }
    QVariantMap metadata() const;
    double volume() const;
    void setVolume(double v);
    qlonglong position() const;
    bool canControl() const { return true; }
    bool canSeek() const { return true; }

    // Fire org.freedesktop.DBus.Properties.PropertiesChanged for the Player
    // interface so waybar/lockscreens refresh on play/pause/title changes.
    void emitPropertiesChanged();

public slots:
    void Next();
    void Previous();
    void Pause();
    void PlayPause();
    void Stop();
    void Play();
    void Seek(qlonglong offset);                              // relative µs
    void SetPosition(const QDBusObjectPath &trackId, qlonglong pos); // absolute µs
    void OpenUri(const QString &uri);
signals:
    void Seeked(qlonglong);

private:
    AppController *m_app;
    PlaybackEngine *m_engine;
    SysVolume *m_sys = nullptr;   // the volume codec actually shows (system sink)
};

// org.codec.App — codec's own control channel, exported at /org/codec/App.
// This is what makes codec single-instance for file opens (VLC-style): a second
// `codec <file>` / `codec --enqueue <files>` hands its files to the already-
// running instance over this interface and exits, instead of opening a second
// window. Used by the Dolphin service-menu actions and the "Open with codec"
// MIME handler.
class CodecIpc : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.codec.App")
public:
    CodecIpc(QObject *parent, AppController *app)
        : QDBusAbstractAdaptor(parent), m_app(app) {}
public slots:
    int Enqueue(const QStringList &paths);  // append to the queue; returns count
    void PlayNow(const QStringList &paths); // play the first, queue the rest
    void Present();                         // raise/focus the codec window
    QString Display();                      // the screen codec is on ("" = still choosing)
    void MoveTo(const QString &display);    // carry codec there (the remote's INPUT key)
    void Front();                           // front codec's window, pointer handed over hidden
    void Rescan();                          // new titles on disk (the torrent importer)
private:
    AppController *m_app;
};

// Owns the exported objects + services and keeps PropertiesChanged flowing.
class Mpris : public QObject
{
    Q_OBJECT
public:
    Mpris(AppController *app, PlaybackEngine *engine, SysVolume *sys = nullptr,
          QObject *parent = nullptr);
private:
    MprisPlayer *m_player = nullptr;
};
