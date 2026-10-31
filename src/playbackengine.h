#pragma once

#include <QObject>
#include <QString>

// Abstract playback backend. The UI and controller talk only to this
// interface; concrete engines (MpvEngine today, a libVLC engine later)
// implement the virtuals and push state through the protected setters.
class PlaybackEngine : public QObject
{
    Q_OBJECT
    Q_PROPERTY(double position READ position NOTIFY positionChanged)
    Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
    Q_PROPERTY(bool idle READ idle NOTIFY idleChanged)
    // mpv is waiting on its cache (paused-for-cache): the link can't feed the
    // file right now. The controller's stall step-down reads this.
    Q_PROPERTY(bool cacheStalled READ cacheStalled NOTIFY cacheStalledChanged)
    Q_PROPERTY(QString mediaTitle READ mediaTitle NOTIFY mediaTitleChanged)
    Q_PROPERTY(QString path READ path NOTIFY pathChanged)
    Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted NOTIFY mutedChanged)
    Q_PROPERTY(double speed READ speed NOTIFY speedChanged)
    Q_PROPERTY(int zoomMode READ zoomMode NOTIFY zoomModeChanged)
    Q_PROPERTY(QString audioText READ audioText NOTIFY tracksChanged)
    Q_PROPERTY(QString subText READ subText NOTIFY tracksChanged)
    Q_PROPERTY(int audioId READ audioId NOTIFY tracksChanged)
    Q_PROPERTY(int subId READ subId NOTIFY tracksChanged)
    Q_PROPERTY(double subDelay READ subDelay NOTIFY subDelayChanged)
    Q_PROPERTY(QString videoInfo READ videoInfo NOTIFY videoInfoChanged)

public:
    enum ZoomMode { Fit = 0, Zoom = 1, Stretch = 2 };
    Q_ENUM(ZoomMode)

    explicit PlaybackEngine(QObject *parent = nullptr) : QObject(parent) {}

    double position() const { return m_position; }
    double duration() const { return m_duration; }
    bool paused() const { return m_paused; }
    bool idle() const { return m_idle; }
    bool cacheStalled() const { return m_cacheStalled; }
    QString mediaTitle() const { return m_mediaTitle; }
    QString path() const { return m_path; }
    double volume() const { return m_volume; }
    bool muted() const { return m_muted; }
    double speed() const { return m_speed; }
    int zoomMode() const { return m_zoomMode; }
    QString audioText() const { return m_audioText; }
    QString subText() const { return m_subText; }
    int audioId() const { return m_audioId; }
    int subId() const { return m_subId; }
    double subDelay() const { return m_subDelay; }
    QString videoInfo() const { return m_videoInfo; }

    // Dev/shot-only: fake a now-playing state so playback-dependent UI (the
    // queue's NOW block, the player OSD, party/live badges) can be rendered by
    // the CODEC_SHOT harness without real decode. No-op outside a shot run; an
    // empty title clears it back to idle.
    Q_INVOKABLE void shotMockPlaying(const QString &title,
                                     double durationS = 5400,
                                     double positionS = 1830,
                                     const QString &mockPath = QString(),
                                     bool mockPaused = true)
    {
        if (!qEnvironmentVariableIsSet("CODEC_SHOT"))
            return;
        if (title.isEmpty()) {
            setIdle(true);
            setPath(QString());
            setMediaTitle(QString());
            return;
        }
        // a real library path lets the shot show what that title wears (its logo)
        setPath(mockPath.isEmpty() ? QStringLiteral("/dev/shot-mock.mkv") : mockPath);
        setMediaTitle(title);
        setIdle(false);
        setDuration(durationS);
        setPosition(positionS);
        // paused holds the OSD open for the shot (osdVisible tracks paused);
        // mockPaused=false = a film PLAYING (the UI sounds' quiet, the inhibitor)
        setPausedState(mockPaused);
    }

public slots:
    // startPos<=0 means "from the beginning"; aid/sid -1 means engine default.
    // streamUrl (when non-empty) is the URL the engine actually OPENS, while
    // `path` stays the reported identity (path()) — used to play a YouTube
    // livestream through the hub's smooth restream lane while chat/history/cast
    // still see the real youtube URL.
    virtual void load(const QString &path, double startPos = 0,
                      int aid = -1, int sid = -1,
                      double speed = 1.0, int zoomMode = Fit,
                      const QString &streamUrl = QString()) = 0;
    virtual void stop() = 0;
    virtual void togglePause() = 0;
    virtual void setPaused(bool paused) = 0;
    virtual void seekRel(double seconds) = 0;
    virtual void seekAbs(double seconds) = 0;
    virtual void seekPct(double pct) = 0;
    virtual void frameStep(bool back) = 0;
    virtual void addVolume(double delta) = 0;
    virtual void setVolume(double volume) = 0;   // absolute, 0..volume-max (200)
    virtual void toggleMute() = 0;
    virtual void multiplySpeed(double factor) = 0;
    virtual void resetSpeed() = 0;
    // Absolute, unlike multiplySpeed — a watch-party follower converges on the
    // shared clock by holding a slightly different speed, so it needs to set a
    // rate rather than compound one.
    virtual void setSpeed(double speed) = 0;
    virtual void cycleAudio() = 0;
    virtual void cycleSub() = 0;
    virtual void addSubDelay(double seconds) = 0;
    virtual void setSubDelay(double) {}   // the absolute delay (a remembered nudge restored at load)
    virtual void reloadSubs() {}          // re-read the external subtitle (the hub re-timed it on disk)
    virtual void setZoomMode(int mode) = 0;
    virtual void cycleZoomMode() = 0;
    virtual void chapterStep(int dir) = 0;

signals:
    void positionChanged();
    void durationChanged();
    void pausedChanged();
    void idleChanged();
    void cacheStalledChanged();
    void subDelayChanged();
    void mediaTitleChanged();
    void pathChanged();
    void volumeChanged();
    void mutedChanged();
    void speedChanged();
    void zoomModeChanged();
    void tracksChanged();
    void videoInfoChanged();
    void fileLoaded();
    // Fired when playback reaches the end of the file normally.
    void endReached(const QString &path);
    // Fired when a file could not be played (bad stream URL, codec, ...).
    void loadFailed(const QString &path, const QString &error);
    // Engine is going down (e.g. IPC quit) — controller should save and exit.
    void shutdownRequested();
    void osdMessage(const QString &text);
    // Fired by cycleSub() when the file carries NO subtitle tracks at all, so the
    // controller can fall back to an online fetch instead of dead-ending on a
    // "NO SUBTITLES" toast. (the author's ask: subs should just grab on the first press.)
    void subFetchRequested();
    // Fired when the ACTIVE sub track is a BITMAP (PGS/dvdsub) — the controller
    // sideloads the hub's OCR'd TEXT version instead (styled MGS, no burned-in
    // bitmap). Arg = the sub-relative stream index (for the hub's /subs?i=).
    void ocrSubRequested(int subIndex);

protected:
    void setPosition(double v) { if (v != m_position) { m_position = v; emit positionChanged(); } }
    void setDuration(double v) { if (v != m_duration) { m_duration = v; emit durationChanged(); } }
    void setPausedState(bool v) { if (v != m_paused) { m_paused = v; emit pausedChanged(); } }
    void setIdle(bool v) { if (v != m_idle) { m_idle = v; emit idleChanged(); } }
    void setCacheStalledState(bool v) { if (v != m_cacheStalled) { m_cacheStalled = v; emit cacheStalledChanged(); } }
    void setSubDelayState(double v) { if (!qFuzzyCompare(v + 1.0, m_subDelay + 1.0)) { m_subDelay = v; emit subDelayChanged(); } }
    void setMediaTitle(const QString &v) { if (v != m_mediaTitle) { m_mediaTitle = v; emit mediaTitleChanged(); } }
    void setPath(const QString &v) { if (v != m_path) { m_path = v; emit pathChanged(); } }
    void setVolumeState(double v) { if (v != m_volume) { m_volume = v; emit volumeChanged(); } }
    void setMutedState(bool v) { if (v != m_muted) { m_muted = v; emit mutedChanged(); } }
    void setSpeedState(double v) { if (v != m_speed) { m_speed = v; emit speedChanged(); } }
    void setZoomModeState(int v) { if (v != m_zoomMode) { m_zoomMode = v; emit zoomModeChanged(); } }
    void setTracks(const QString &audio, const QString &sub, int aid, int sid)
    {
        if (audio != m_audioText || sub != m_subText || aid != m_audioId || sid != m_subId) {
            m_audioText = audio; m_subText = sub; m_audioId = aid; m_subId = sid;
            emit tracksChanged();
        }
    }
    void setVideoInfo(const QString &v) { if (v != m_videoInfo) { m_videoInfo = v; emit videoInfoChanged(); } }

private:
    double m_position = 0;
    double m_duration = 0;
    bool m_paused = true;
    bool m_idle = true;
    bool m_cacheStalled = false;
    double m_subDelay = 0.0;
    QString m_mediaTitle;
    QString m_path;
    double m_volume = 100;
    bool m_muted = false;
    double m_speed = 1.0;
    int m_zoomMode = Fit;
    QString m_audioText;
    QString m_subText;
    int m_audioId = -1;
    int m_subId = -1;
    QString m_videoInfo;
};
