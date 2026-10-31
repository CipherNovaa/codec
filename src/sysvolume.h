#pragma once

#include <QObject>
#include <QProcess>
#include <QTimer>

// The SYSTEM volume (default PipeWire sink) — what the keyboard's volume keys
// change — as seen and driven from codec's OSD. Read/set with wpctl (capped at
// 100%, like ~/scripts/bar/vol-up.sh), and watch `pactl subscribe` so a change
// made anywhere (the volume keys, another app) lands here at once.
//
// While codec's player is up it also keeps $XDG_RUNTIME_DIR/codec-osd-active
// fresh; quickshell's VolumeOSD skips its own popup while that file is young,
// so a volume change shows on codec's OSD instead of over it.
class SysVolume : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int volume READ volume NOTIFY changed)   // 0..100 (%)
    Q_PROPERTY(bool muted READ muted NOTIFY changed)
    Q_PROPERTY(bool available READ available NOTIFY changed)
    // True while codec's player owns the screen → codec shows volume changes.
    Q_PROPERTY(bool ownsOsd READ ownsOsd WRITE setOwnsOsd NOTIFY ownsOsdChanged)

public:
    explicit SysVolume(QObject *parent = nullptr);
    ~SysVolume() override;

    int volume() const { return m_volume; }
    bool muted() const { return m_muted; }
    bool available() const { return m_available; }
    bool ownsOsd() const { return m_ownsOsd; }
    void setOwnsOsd(bool on);

    Q_INVOKABLE void step(int percent); // +/- percent, capped 0..100, unmutes on up
    Q_INVOKABLE void setLevel(int percent); // ABSOLUTE 0..100 (the 100% detent lands exactly)
    Q_INVOKABLE void toggleMute();
    // Idempotent (set-mute 0/1): safe beside a step() in flight, which a
    // `toggle` is not — the two raced and could leave the sink muted.
    Q_INVOKABLE void setMuted(bool on);

signals:
    void changed();
    // A change that did NOT come from step()/toggleMute() (the volume keys) —
    // the player pops its OSD for it.
    void changedExternally();
    void ownsOsdChanged();

private:
    void refresh();
    void startWatch();
    void touchFlag();

    int m_volume = 0;
    bool m_muted = false;
    bool m_available = false;
    bool m_ownsOsd = false;
    qint64 m_selfChangeUntil = 0;   // ms epoch: changes before this are ours
    QProcess *m_watch = nullptr;
    QTimer m_refreshDebounce;
    QTimer m_flagTimer;
    bool m_refreshing = false;
    bool m_refreshAgain = false;
};
