#pragma once

#include "playbackengine.h"

#include <mpv/client.h>

#include <QVariantList>

#include <optional>

// libmpv implementation of PlaybackEngine. Owns the mpv core; the video
// itself is drawn by MpvVideoItem via mpv's OpenGL render API.
class QProcess;

class MpvEngine : public PlaybackEngine
{
    Q_OBJECT
    Q_PROPERTY(QVariantList audioDevices READ audioDevices NOTIFY audioDevicesChanged)
    Q_PROPERTY(QString audioDevice READ audioDevice NOTIFY audioDevicesChanged)
    Q_PROPERTY(QVariantList chapters READ chapters NOTIFY chaptersChanged)

public:
    explicit MpvEngine(QObject *parent = nullptr);
    ~MpvEngine() override;

    mpv_handle *handle() const { return m_mpv; }

    // Called (queued, GUI thread) by the renderer once the mpv render context
    // exists. vo=libmpv can't configure video before that, so any load that
    // arrived earlier is parked and replayed here.
    void notifyRenderReady();

    QVariantList audioDevices() const { return m_audioDevices; }
    QString audioDevice() const { return m_audioDevice; }
    Q_INVOKABLE void setAudioDevice(const QString &name);
    // a satellite's key to its hub (device pairing): sent as a header on a
    // film from one of these hosts, and nowhere else
    void setHubAuth(const QStringList &hosts, const QString &key) { m_hubHosts = hosts; m_hubKey = key; }
    // Library-pretty title ("Avengers: Endgame (2019)") instead of the
    // scene filename in the OSD/PiP; empty clears back to mpv's default.
    void setForcedTitle(const QString &title);
    // The real length when mpv can only see a window of it (a party stream:
    // its playlist grows from where the room's encoder started).
    void setDurationHint(double s);
    // Preferred audio language (ISO code, default English): mpv's alang wins over
    // a mislabeled `default` flag, so an English film ripped with a foreign
    // default track still plays English. Mirrors the cast worker's pick.
    void setAudioLang(const QString &lang);
    Q_INVOKABLE void addSubFile(const QString &pathOrUrl, bool cached = false, bool select = true); // sub-add (cached: reuse a same-name track; !select: offer only)
    // the hub's OCR'd text of the active bitmap sub: labelled "OCR" + the bitmap
    // track's language (an untitled URL track was named after the URL's tail —
    // the OSD read "#2 · MKV&I=0&SRT=1")
    void addOcrSubFile(const QString &url);
    // The embedded index of the active sub if it is a bitmap (PGS/dvdsub), else
    // -1 — so a late OCR reply only takes over the track it was asked for.
    int activeBitmapSub() const { return m_activeBitmapSub; }
    Q_INVOKABLE void setSubtitleScale(double scale);
    Q_INVOKABLE void setSubtitleColor(const QString &hex);   // local caption colour
    Q_INVOKABLE void setSubtitleFont(const QString &family); // local caption font
    Q_INVOKABLE void setSubtitleLift(bool lifted);
    Q_INVOKABLE void setSubtitleBox(bool boxed);       // local captions on a dark band
    Q_INVOKABLE void setSubHonourStyle(bool honour);   // a styled .ass keeps its own look
    Q_INVOKABLE void setNightMode(bool on);
    // The YouTube login yt-dlp reads for each load (a --cookies-from-browser
    // spec); "" = anonymous (codec's own lists, or no browser signed in).
    void setYtCookieSpec(const QString &spec);
    QVariantList chapters() const { return m_chapters; }
    // Dev meter (CODEC_FPS): mpv's own frame counters for the file playing —
    // decoder drops, frames the output showed late, frames shown at the
    // wrong moment. Empty when nothing plays.
    QString frameStats() const
    {
        if (!m_mpv || idle())
            return QString();
        int64_t drop = 0, late = 0, mistimed = 0;
        mpv_get_property(m_mpv, "frame-drop-count", MPV_FORMAT_INT64, &drop);
        mpv_get_property(m_mpv, "vo-delayed-frame-count", MPV_FORMAT_INT64, &late);
        mpv_get_property(m_mpv, "mistimed-frame-count", MPV_FORMAT_INT64, &mistimed);
        return QStringLiteral("mpv drop %1 late %2 mistimed %3").arg(drop).arg(late).arg(mistimed);
    }
    // Dev hook for CODEC_SHOT renders (no file is decoded there): a chapter
    // list to draw. A no-op unless CODEC_SHOT is set.
    Q_INVOKABLE void shotMockChapters(const QVariantList &chapters)
    {
        if (!qEnvironmentVariableIsSet("CODEC_SHOT"))
            return;
        m_chapters = chapters;
        emit chaptersChanged();
    }

    // True while the loaded file carries an HDR transfer (PQ/HLG). Drives the
    // controller's engage state machine.
    bool hdrContent() const { return m_hdrContent; }
    // Renderer target: PQ/BT.2020 at the panel's peak vs plain SDR. The window
    // buffer is 8-bit (NVIDIA Wayland EGL has no deep GL configs), so the PQ
    // signal is dithered down or gradients band.
    void setHdrOutput(bool on, double peakNits);

signals:
    void audioDevicesChanged();
    void chaptersChanged();
    void hdrContentChanged();

public:
    void load(const QString &path, double startPos = 0,
              int aid = -1, int sid = -1,
              double speed = 1.0, int zoomMode = Fit,
              const QString &streamUrl = QString()) override;
    void stop() override;
    void togglePause() override;
    void setPaused(bool paused) override;
    void seekRel(double seconds) override;
    void seekAbs(double seconds) override;
    void seekPct(double pct) override;
    void frameStep(bool back) override;
    void addVolume(double delta) override;
    void setVolume(double volume) override;
    void toggleMute() override;
    void multiplySpeed(double factor) override;
    void resetSpeed() override;
    void setSpeed(double speed) override;
    void cycleAudio() override;
    void cycleSub() override;
    void addSubDelay(double seconds) override;
    void setSubDelay(double seconds) override;
    void reloadSubs() override;
    void setZoomMode(int mode) override;
    void cycleZoomMode() override;
    void chapterStep(int dir) override;

private slots:
    void processEvents();

private:
    void handleEvent(mpv_event *event);
    void handlePropertyChange(mpv_event_property *prop);
    void updateTrackTexts();
    void applyZoomProperties(int mode);

    void command(const QStringList &args);
    void setProp(const char *name, double value);
    void setProp(const char *name, const QString &value);

    mpv_handle *m_mpv = nullptr;
    QProcess *m_cookieProbe = nullptr;   // background yt cookie-spec probe (ctor → first YT load)
    QVariantList m_trackList;
    QVariantList m_chapters;
    QString m_aid = QStringLiteral("no");
    QString m_sid = QStringLiteral("no");
    double m_durationHint = 0;
    double m_pendingSpeed = 1.0;
    double m_speedSent = 1.0; // last speed pushed by setSpeed (dedupe guard)
    int m_pendingZoom = Fit;
    bool m_expectEof = false;
    bool m_announceAudio = false;
    bool m_announceSub = false;
    int m_ocrAskedFor = -1;       // the bitmap sub (embedded index) last handed to the controller
    int m_activeBitmapSub = -1;   // embedded index of the ACTIVE sub when it is a bitmap, else -1
    QList<int> subCycleIds(QList<int> *embeddedIds = nullptr) const;
    int m_requestedSid = -1;      // the sid this load asked for (a saved pref), to spot a missing one
    QString m_ocrLang;            // the bitmap track's language, for the OCR track's label
    bool m_hdrContent = false;

    QVariantList m_audioDevices;
    QString m_audioDevice;
    QStringList m_hubHosts;
    QString m_hubKey;
    bool m_renderReady = false;
    struct PendingLoad {
        QString path;
        double startPos;
        int aid;
        int sid;
        double speed;
        int zoomMode;
        QString streamUrl;
    };
    std::optional<PendingLoad> m_pendingLoad;
};
