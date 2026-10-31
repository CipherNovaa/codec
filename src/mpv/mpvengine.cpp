#include "mpvengine.h"
#include "../scriptpath.h"
#include <QUrl>

#include <QRegularExpression>

#include <QDir>
#include <QFileInfo>
#include <QMetaObject>
#include <QProcess>
#include <QStandardPaths>
#include <QVariantMap>

#include <clocale>
#include <stdexcept>
#include <vector>

// yt-dlp options mpv passes for every YouTube load (captions incl. auto-subs);
// the browser cookie spec is appended once codec_yt answers.
static constexpr char kYtdlRaw[] = "write-subs=,write-auto-subs=,sub-langs=en.*";

namespace {

// Minimal mpv_node -> QVariant conversion (enough for track-list).
QVariant nodeToVariant(const mpv_node *node)
{
    switch (node->format) {
    case MPV_FORMAT_STRING:
        return QString::fromUtf8(node->u.string);
    case MPV_FORMAT_FLAG:
        return node->u.flag != 0;
    case MPV_FORMAT_INT64:
        return qlonglong(node->u.int64);
    case MPV_FORMAT_DOUBLE:
        return node->u.double_;
    case MPV_FORMAT_NODE_ARRAY: {
        QVariantList list;
        for (int i = 0; i < node->u.list->num; ++i)
            list.append(nodeToVariant(&node->u.list->values[i]));
        return list;
    }
    case MPV_FORMAT_NODE_MAP: {
        QVariantMap map;
        for (int i = 0; i < node->u.list->num; ++i)
            map.insert(QString::fromUtf8(node->u.list->keys[i]),
                       nodeToVariant(&node->u.list->values[i]));
        return map;
    }
    default:
        return {};
    }
}

void onMpvWakeup(void *ctx)
{
    // Called from mpv's thread — bounce to the GUI thread ("processEvents"
    // must be a slot for the string-based lookup to resolve).
    auto *engine = static_cast<MpvEngine *>(ctx);
    QMetaObject::invokeMethod(engine, "processEvents", Qt::QueuedConnection);
}

} // namespace

MpvEngine::MpvEngine(QObject *parent)
    : PlaybackEngine(parent)
{
    // libmpv refuses to run under a locale where "." is not the decimal
    // separator; Qt may have reset it from the environment.
    std::setlocale(LC_NUMERIC, "C");

    m_mpv = mpv_create();
    if (!m_mpv)
        throw std::runtime_error("could not create mpv context");

    mpv_set_option_string(m_mpv, "vo", "libmpv");
    mpv_set_option_string(m_mpv, "hwdec", "auto-safe");
    mpv_set_option_string(m_mpv, "terminal", "no");
    mpv_set_option_string(m_mpv, "msg-level", "all=warn");
    mpv_set_option_string(m_mpv, "input-default-bindings", "no");
    mpv_set_option_string(m_mpv, "osd-level", "0");
    // VLC-style boost: past a full system volume the player itself amplifies,
    // up to 200% (the OSD's volume steps fill the system first, then this).
    mpv_set_option_string(m_mpv, "volume-max", "200");
    mpv_set_option_string(m_mpv, "sub-auto", "fuzzy");
    // A release's own Subs/ folder loads too (the hub and the cast lanes have
    // always looked there; the local player never did).
    mpv_set_option_string(m_mpv, "sub-file-paths", "Subs:subs:Subtitles:subtitles:Sub");
    // ONE caption look: codec's font, colour and border apply to ASS/SSA
    // tracks as well — mpv's default ("scale") keeps a styled file's own
    // colours, so the ink Settings promised never reached those. SUB FILE
    // STYLING in Settings hands a file its own look back (sign-heavy anime).
    mpv_set_option_string(m_mpv, "sub-ass-override", "force");
    // YouTube: without these yt-dlp returns no caption tracks at all, so "s"
    // had nothing to cycle. Auto-subs included — most videos are ASR-only.
    // Premium cookies ride along: anonymous streams can carry YouTube's
    // SERVER-STITCHED ads (docs/BUGS.md 2026-07-17); with the browser's
    // Premium session ads are impossible. codec_yt owns profile detection.
    // The cookie-spec probe is a ~275 ms Python start, so it runs in the
    // BACKGROUND instead of blocking every launch: mpv starts with the plain
    // options and the spec is applied when it answers (ytdl_hook re-reads
    // ytdl-raw-options on each load). A YouTube load that beats it waits for
    // it in load(), so the Premium cookies are never skipped.
    mpv_set_option_string(m_mpv, "ytdl-raw-options", kYtdlRaw);
    m_cookieProbe = new QProcess(this);
    connect(m_cookieProbe, &QProcess::finished, this, [this] {
        if (!m_cookieProbe)
            return;
        const QByteArray spec = m_cookieProbe->readAllStandardOutput().trimmed();
        if (!spec.isEmpty() && m_mpv) {
            const QByteArray raw = QByteArray(kYtdlRaw) + ",cookies-from-browser=" + spec;
            mpv_set_property_string(m_mpv, "ytdl-raw-options", raw.constData());
        }
        m_cookieProbe->deleteLater();
        m_cookieProbe = nullptr;
    });
    connect(m_cookieProbe, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart || !m_cookieProbe)
            return;
        m_cookieProbe->deleteLater();   // no python / no script: plain options stand
        m_cookieProbe = nullptr;
    });
    m_cookieProbe->start(QStringLiteral("/usr/bin/python3"),
                         {codecScript(QStringLiteral("codec_yt.py")),
                          QStringLiteral("--cookie-spec")});
    // System font standard: every subtitle surface renders Iosevka. Short
    // alias on purpose — fontconfig's prepend rules hijack the long name.
    mpv_set_option_string(m_mpv, "sub-font", "Iosevka NFP");
    mpv_set_option_string(m_mpv, "sub-ass-style-overrides",
                          "FontName=Iosevka NFP");
#ifdef CODEC_SOURCE_DIR
    // Make the codec faces (MGS Codec/HUD, mecha…) available to libmpv so LOCAL
    // captions can use them, exactly like the cast overlay's @font-face does.
    mpv_set_option_string(m_mpv, "sub-fonts-dir", CODEC_SOURCE_DIR "/assets/mechui");
#endif
    // The "nice" caption look ported from the TV overlay (#cap's text-shadow
    // glow): a strong black outline + soft shadow so text stays legible over any
    // scene, whatever font/colour the viewer picks.
    mpv_set_option_string(m_mpv, "sub-border-size", "2.6");
    mpv_set_option_string(m_mpv, "sub-border-color", "#000000");
    mpv_set_option_string(m_mpv, "sub-shadow-offset", "1.2");
    mpv_set_option_string(m_mpv, "sub-shadow-color", "#000000");
    mpv_set_option_string(m_mpv, "audio-client-name", "codec");
    mpv_set_option_string(m_mpv, "keep-open", "no");
    // Route through PipeWire/Pulse, never a raw-ALSA exclusive grab (which
    // fails silently when the card is already held by the sound server).
    mpv_set_option_string(m_mpv, "ao", "pipewire,pulse,alsa");
    // If a device can't open, fall back to another AO instead of disabling
    // audio for the whole file (the "sometimes no sound at all" bug).
    mpv_set_option_string(m_mpv, "audio-fallback-to-null", "no");

    // Network cache — a satellite streams hub titles over HTTP (LAN or, when
    // roaming, the tailnet). Without a seekable cache a seek dumps mpv's tiny
    // default buffer and stalls hard rebuilding demuxer state on a 15GB remux;
    // that read as a "freeze on seek". A big forward+back buffer plus a
    // seekable cache makes scrubbing land within RAM, and force-seekable keeps
    // seeking alive even if a stream under-reports it. Harmless for local
    // files (fast, and they rarely fill the buffer).
    mpv_set_option_string(m_mpv, "cache", "yes");
    mpv_set_option_string(m_mpv, "demuxer-seekable-cache", "yes");
    mpv_set_option_string(m_mpv, "demuxer-max-bytes", "256MiB");
    mpv_set_option_string(m_mpv, "demuxer-max-back-bytes", "128MiB");
    mpv_set_option_string(m_mpv, "demuxer-readahead-secs", "20");
    mpv_set_option_string(m_mpv, "force-seekable", "yes");
    // Auto-reconnect the HTTP stream. A roaming satellite pulls over the
    // tailnet across someone else's wifi; a brief drop or an unexpected EOF
    // must retry, not end the movie. (ffmpeg http demuxer options.)
    // Bounded, not infinite. reconnect_max_retries caps consecutive attempts
    // (a successful read resets the count, so a transient blip mid-film still
    // recovers) and rw_timeout errors a stalled read — so a genuinely dead
    // stream gives up (~21s of backoff, then EOF/ERROR -> loadFailed -> toast)
    // instead of retrying forever behind a frozen player. Verified accepted by
    // the linked FFmpeg (n9.0). Pairs with reachableHub/hybrid-resume, which
    // handle the cold-start side; this is the mid-stream drop.
    mpv_set_option_string(m_mpv, "stream-lavf-o",
                          "reconnect=1,reconnect_streamed=1,"
                          "reconnect_on_network_error=1,reconnect_delay_max=7,"
                          "reconnect_max_retries=5,rw_timeout=30000000");

    // Scriptability + automated testing: full mpv IPC on a predictable socket.
    const QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (!runtime.isEmpty()) {
        const QString sock = runtime + QStringLiteral("/codec-mpv.sock");
        mpv_set_option_string(m_mpv, "input-ipc-server", sock.toUtf8().constData());
    }

    if (mpv_initialize(m_mpv) < 0)
        throw std::runtime_error("could not initialize mpv context");

    mpv_observe_property(m_mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "pause", MPV_FORMAT_FLAG);
    // core-idle had no handler branch — every change woke the GUI thread to do
    // nothing. idle-active (below) is the one we actually act on; don't observe
    // core-idle at all rather than pay for dead wakeups.
    mpv_observe_property(m_mpv, 0, "idle-active", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "media-title", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 0, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "mute", MPV_FORMAT_FLAG);
    mpv_observe_property(m_mpv, 0, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "track-list", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "chapter-list", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "aid", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 0, "sid", MPV_FORMAT_STRING);
    mpv_observe_property(m_mpv, 0, "sub-delay", MPV_FORMAT_DOUBLE);
    mpv_observe_property(m_mpv, 0, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "audio-device-list", MPV_FORMAT_NODE);
    mpv_observe_property(m_mpv, 0, "audio-device", MPV_FORMAT_STRING);

    mpv_set_wakeup_callback(m_mpv, onMpvWakeup, this);
}

MpvEngine::~MpvEngine()
{
    if (m_mpv) {
        mpv_set_wakeup_callback(m_mpv, nullptr, nullptr);
        mpv_terminate_destroy(m_mpv);
        m_mpv = nullptr;
    }
}

void MpvEngine::command(const QStringList &args)
{
    if (!m_mpv)
        return;
    std::vector<QByteArray> storage;
    storage.reserve(args.size());
    std::vector<const char *> argv;
    argv.reserve(args.size() + 1);
    for (const QString &arg : args) {
        storage.push_back(arg.toUtf8());
        argv.push_back(storage.back().constData());
    }
    argv.push_back(nullptr);
    mpv_command_async(m_mpv, 0, argv.data());
}

void MpvEngine::setProp(const char *name, double value)
{
    if (m_mpv)
        mpv_set_property_async(m_mpv, 0, name, MPV_FORMAT_DOUBLE, &value);
}

void MpvEngine::setProp(const char *name, const QString &value)
{
    if (m_mpv)
        mpv_set_property_string(m_mpv, name, value.toUtf8().constData());
}

void MpvEngine::setSubtitleScale(double scale)
{
    if (!m_mpv)
        return;
    const QByteArray v = QByteArray::number(qBound(0.25, scale, 2.0));
    mpv_set_option_string(m_mpv, "sub-scale", v.constData());
}

void MpvEngine::setSubtitleColor(const QString &hex)
{
    if (!m_mpv)
        return;
    mpv_set_option_string(m_mpv, "sub-color", hex.toUtf8().constData());
}

void MpvEngine::setSubtitleFont(const QString &family)
{
    if (!m_mpv)
        return;
    const QByteArray f = family.toUtf8();
    mpv_set_option_string(m_mpv, "sub-font", f.constData());
    // ASS/SSA subs carry their own FontName; override it so the pick applies to
    // styled subs too (same reason the Iosevka default is force-set at init).
    mpv_set_option_string(m_mpv, "sub-ass-style-overrides",
                          (QByteArray("FontName=") + f).constData());
}

void MpvEngine::setSubtitleLift(bool lifted)
{
    // Subtitles sit at the bottom of the frame and so does the OSD, so while
    // the controls are up the text reads THROUGH the panel. Every player that
    // gets this right moves the subtitles rather than hiding them — you are
    // usually opening the OSD to seek, which is exactly when you still want to
    // read. sub-pos is a percentage of frame height from the top: 100 is the
    // bottom edge, and the OSD occupies roughly the bottom fifth.
    if (!m_mpv)
        return;
    mpv_set_option_string(m_mpv, "sub-pos", lifted ? "82" : "100");
}

void MpvEngine::setNightMode(bool on)
{
    // "Reduce loud sounds": dynamic range compression keeps dialogue up and
    // explosions down (Apple TV / Prime's Dialogue Boost equivalent).
    if (!m_mpv)
        return;
    mpv_set_option_string(m_mpv, "af",
                          on ? "dynaudnorm=f=200:g=15:p=0.7:m=10" : "");
}

void MpvEngine::setHdrOutput(bool on, double peakNits)
{
    if (!m_mpv)
        return;
    // Properties, not options: the render target flips live mid-file.
    mpv_set_property_string(m_mpv, "target-trc", on ? "pq" : "auto");
    mpv_set_property_string(m_mpv, "target-prim", on ? "bt.2020" : "auto");
    mpv_set_property_string(m_mpv, "target-peak",
                            on ? QByteArray::number(qBound(100.0, peakNits, 10000.0))
                                     .constData()
                               : "auto");
    mpv_set_property_string(m_mpv, "dither-depth", on ? "8" : "auto");
}

void MpvEngine::setForcedTitle(const QString &title)
{
    mpv_set_option_string(m_mpv, "force-media-title",
                          title.toUtf8().constData());
}

void MpvEngine::setAudioLang(const QString &lang)
{
    if (!m_mpv)
        return;
    // Set before loadfile so it applies to the file being opened. alang beats a
    // mislabeled `default` flag; a per-file `aid` (a remembered track) still
    // wins over it, which is what we want.
    mpv_set_option_string(m_mpv, "alang",
                          (lang.isEmpty() ? QStringLiteral("eng") : lang)
                              .toUtf8().constData());
}

void MpvEngine::addSubFile(const QString &pathOrUrl, bool cached, bool select)
{
    // "select" makes the fetched track active immediately. "cached" also selects
    // but REUSES an already-added track with the same filename instead of loading
    // a duplicate — used for the OCR-sub sideload, which can re-fire per reload.
    // "auto" only OFFERS the track (a hub sidecar a satellite's mpv can't see).
    command({QStringLiteral("sub-add"), pathOrUrl,
             !select ? QStringLiteral("auto")
             : cached ? QStringLiteral("cached") : QStringLiteral("select")});
}

void MpvEngine::addOcrSubFile(const QString &url)
{
    // sub-add <url> <flags> <title> <lang>
    command({QStringLiteral("sub-add"), url, QStringLiteral("cached"),
             QStringLiteral("OCR"), m_ocrLang});
}

void MpvEngine::setAudioDevice(const QString &name)
{
    // Never accept a raw-ALSA device — it exclusively grabs the card and goes
    // silent when PipeWire holds it. Anything unsafe collapses to "auto".
    QString dev = name;
    if (dev.isEmpty() || dev.startsWith(QLatin1String("alsa"))
        || dev.startsWith(QLatin1String("jack")) || dev.startsWith(QLatin1String("oss"))
        || dev.startsWith(QLatin1String("sdl")) || dev.startsWith(QLatin1String("sndio"))
        || dev.startsWith(QLatin1String("openal")))
        dev = QStringLiteral("auto");
    setProp("audio-device", dev);
    // If a prior failure disabled audio for the current file, bring the track
    // back so switching devices actually restores sound.
    if (audioId() < 0 && !path().isEmpty())
        mpv_set_property_string(m_mpv, "aid", "auto");
}

void MpvEngine::notifyRenderReady()
{
    if (m_renderReady)
        return;
    m_renderReady = true;
    if (m_pendingLoad) {
        const PendingLoad p = *m_pendingLoad;
        m_pendingLoad.reset();
        load(p.path, p.startPos, p.aid, p.sid, p.speed, p.zoomMode, p.streamUrl);
    }
}

void MpvEngine::setYtCookieSpec(const QString &spec)
{
    // The YouTube worker's word on the login (Settings ▸ YOUTUBE connected or
    // left one) — newer than the start-up probe's, which it replaces.
    if (m_cookieProbe) {
        m_cookieProbe->disconnect(this);
        m_cookieProbe->kill();
        m_cookieProbe->deleteLater();
        m_cookieProbe = nullptr;
    }
    if (!m_mpv)
        return;
    QByteArray raw(kYtdlRaw);
    if (!spec.isEmpty())
        raw += ",cookies-from-browser=" + spec.toUtf8();
    mpv_set_property_string(m_mpv, "ytdl-raw-options", raw.constData());
}

void MpvEngine::load(const QString &path, double startPos, int aid, int sid,
                     double speed, int zoomMode, const QString &streamUrl)
{
    // a YouTube load in the first moments of launch waits for the cookie probe
    if (m_cookieProbe && (path.contains(QLatin1String("youtube.com"))
                          || path.contains(QLatin1String("youtu.be"))))
        m_cookieProbe->waitForFinished(5000);
    if (!m_renderReady) {
        m_pendingLoad = PendingLoad{path, startPos, aid, sid, speed, zoomMode,
                                    streamUrl};
        setPath(path);
        setMediaTitle(QFileInfo(path).completeBaseName());
        return;
    }
    m_pendingSpeed = speed > 0 ? speed : 1.0;
    m_pendingZoom = zoomMode;
    m_expectEof = false;
    // the room's length (setDurationHint) belongs to a party stream only — and
    // a replayed pending load of that same stream must not drop it
    if (!(path.contains(QLatin1String("/p/")) && path.contains(QLatin1String("/hls/"))))
        m_durationHint = 0;
    // Reset position/duration before the new file loads: its real values arrive
    // asynchronously (the time-pos/duration callbacks), and until they do a save
    // fired in the buffering window — a >10s cold start, or a rapid A->B->C —
    // would persist the PREVIOUS title's position onto the new row (keyed by the
    // new path) and could false-complete it. duration=0 trips saveNow's existing
    // duration<=0 guard until the real duration lands.
    setPosition(0);
    setDuration(0);

    QStringList opts;
    if (startPos > 0)
        opts << QStringLiteral("start=%1").arg(startPos, 0, 'f', 3);
    // aid mirrors sid: >0 = that track, 0 = the user explicitly turned audio
    // OFF (survive restarts), <0 = no preference (mpv auto-selects).
    if (aid > 0)
        opts << QStringLiteral("aid=%1").arg(aid);
    else if (aid == 0)
        opts << QStringLiteral("aid=no");
    // sid: >0 = that track, 0 = the user explicitly turned subs OFF (must
    // survive restarts — plain auto would resurrect them), <0 = no preference.
    m_requestedSid = sid;
    if (sid > 0)
        opts << QStringLiteral("sid=%1").arg(sid);
    else if (sid == 0)
        opts << QStringLiteral("sid=no");

    // Open streamUrl when the caller decoupled it (a YouTube livestream played
    // through the hub's restream lane); otherwise open `path` itself. Either way
    // path() reports `path`, so chat/history/cast still see the real identity.
    const QString openUrl = streamUrl.isEmpty() ? path : streamUrl;
    // A LOCAL .m3u8 is a live DVR snapshot (AppController::liveEnterDvr): a
    // playlist file whose segments are https. ffmpeg's hls demuxer inherits
    // the playlist's protocol whitelist (file only) and silently plays just
    // the first segment unless https is allowed. %len% quoting because the
    // value itself contains commas and this option list is comma-joined.
    // A watch party's stream (`…/p/<token>/hls/…`) is stamped in FILM time —
    // its segments start wherever the room's encoder did. mpv's default rebases
    // the first one to 0:00, so 1:29:00 read as 0:54 and every seek to the
    // room's time landed past the end: a black screen (the laptop, 2026-10-10).
    if (openUrl.contains(QLatin1String("/p/")) && openUrl.contains(QLatin1String("/hls/")))
        opts << QStringLiteral("rebase-start-time=no");
    if (openUrl.startsWith(QLatin1Char('/')) && openUrl.endsWith(QLatin1String(".m3u8"))) {
        const QString wl = QStringLiteral("protocol_whitelist=[file,http,https,tls,tcp,crypto,data]");
        opts << QStringLiteral("demuxer-lavf-o=%%1%%2").arg(wl.size()).arg(wl);
    }
    // A satellite's key to its hub rides a hub film's requests — the file,
    // or a lane's playlist AND its segments (lavf passes headers down).
    if (!m_hubKey.isEmpty() && openUrl.startsWith(QLatin1String("http"))
        && m_hubHosts.contains(QUrl(openUrl).host().toLower())) {
        const QString h = QStringLiteral("X-Codec-Key: ") + m_hubKey;
        opts << QStringLiteral("http-header-fields=%%1%%2").arg(h.size()).arg(h);
    }
    QStringList cmd{QStringLiteral("loadfile"), openUrl, QStringLiteral("replace")};
    if (!opts.isEmpty()) {
        // "loadfile url flags index options" — index -1 keeps flags semantics
        // stable across mpv versions that added the index argument.
        cmd << QStringLiteral("-1") << opts.join(QLatin1Char(','));
    }
    command(cmd);
    setPath(path);
    setPaused(false);
}

void MpvEngine::setDurationHint(double s)
{
    m_durationHint = qMax(0.0, s);
    if (m_durationHint > duration())
        setDuration(m_durationHint);
}

void MpvEngine::stop()
{
    m_expectEof = false;
    command({QStringLiteral("stop")});
}

void MpvEngine::togglePause()
{
    command({QStringLiteral("cycle"), QStringLiteral("pause")});
}

void MpvEngine::setPaused(bool paused)
{
    setProp("pause", paused ? QStringLiteral("yes") : QStringLiteral("no"));
}

void MpvEngine::seekRel(double seconds)
{
    command({QStringLiteral("seek"), QString::number(seconds), QStringLiteral("relative")});
}

void MpvEngine::seekAbs(double seconds)
{
    command({QStringLiteral("seek"), QString::number(qMax(0.0, seconds)),
             QStringLiteral("absolute")});
}

void MpvEngine::seekPct(double pct)
{
    command({QStringLiteral("seek"), QString::number(qBound(0.0, pct, 100.0)),
             QStringLiteral("absolute-percent")});
}

void MpvEngine::frameStep(bool back)
{
    command({back ? QStringLiteral("frame-back-step") : QStringLiteral("frame-step")});
}

void MpvEngine::addVolume(double delta)
{
    command({QStringLiteral("add"), QStringLiteral("volume"), QString::number(delta)});
}

void MpvEngine::setVolume(double volume)
{
    command({QStringLiteral("set"), QStringLiteral("volume"),
             QString::number(qBound(0.0, volume, 200.0))});
}

void MpvEngine::toggleMute()
{
    command({QStringLiteral("cycle"), QStringLiteral("mute")});
}

void MpvEngine::multiplySpeed(double factor)
{
    command({QStringLiteral("multiply"), QStringLiteral("speed"), QString::number(factor)});
}

void MpvEngine::resetSpeed()
{
    setProp("speed", 1.0);
}

void MpvEngine::setSpeed(double speed)
{
    speed = qBound(0.25, speed, 4.0);
    // Watch-party sync sets this every couple of seconds and usually lands on
    // the value it already holds; re-sending would churn the audio filter for
    // nothing. mpv pitch-corrects, so a few percent is inaudible.
    if (qAbs(speed - m_speedSent) < 0.001)
        return;
    m_speedSent = speed;
    setProp("speed", speed);
}

void MpvEngine::cycleAudio()
{
    // Announce the resulting track once the property observer catches up.
    m_announceAudio = true;
    command({QStringLiteral("cycle"), QStringLiteral("audio")});
}

// The embedded subtitle ordinal an OCR sideload stands in for (its hub URL is
// /subs?src=…&i=<ordinal>&srt=1), or -1 for any other track.
static int ocrOrdinal(const QVariantMap &t)
{
    if (!t.value(QStringLiteral("external")).toBool())
        return -1;
    const QString f = t.value(QStringLiteral("external-filename")).toString();
    if (!f.contains(QLatin1String("/subs?")) || !f.contains(QLatin1String("srt=1")))
        return -1;
    static const QRegularExpression re(QStringLiteral("[?&]i=(\\d+)"));
    const auto m = re.match(f);
    return m.hasMatch() ? m.captured(1).toInt() : -1;
}

// Sub tracks the viewer can step through, in order: each EMBEDDED track — a
// bitmap one by its OCR'd text when that is loaded — then other external subs
// (sidecars, downloads). An OCR sideload sits at the END of mpv's list, so a
// plain `cycle sub` jumped from it to "off" and back to the first bitmap, which
// swapped straight to its OCR again: the other tracks were unreachable.
QList<int> MpvEngine::subCycleIds(QList<int> *embeddedIds) const
{
    QList<int> emb, ext;
    QHash<int, int> ocrFor;   // ordinal -> OCR sideload id
    for (const QVariant &v : std::as_const(m_trackList)) {
        const QVariantMap t = v.toMap();
        if (t.value(QStringLiteral("type")).toString() != QLatin1String("sub"))
            continue;
        const int id = t.value(QStringLiteral("id")).toInt();
        if (!t.value(QStringLiteral("external")).toBool()) {
            emb << id;
            continue;
        }
        const int k = ocrOrdinal(t);
        if (k >= 0)
            ocrFor.insert(k, id);
        else
            ext << id;
    }
    QList<int> ids;
    for (int k = 0; k < emb.size(); ++k)
        ids << ocrFor.value(k, emb[k]);
    ids << ext;
    if (embeddedIds)
        *embeddedIds = emb;
    return ids;
}

void MpvEngine::cycleSub()
{
    // On a file with no sub tracks, 'cycle sub' never changes sid, so the sid
    // observer never fires and m_announceSub would stay latched to mislabel a
    // later track event. Say there's nothing to cycle and don't arm the latch.
    bool hasSub = false;
    for (const QVariant &v : std::as_const(m_trackList))
        if (v.toMap().value(QStringLiteral("type")).toString() == QLatin1String("sub")) {
            hasSub = true;
            break;
        }
    if (!hasSub) {
        // Nothing to cycle → don't dead-end. Ask the controller to fetch subs
        // online (it shows its own "SEARCHING…"/"NONE FOUND" feedback). Keep the
        // latch disarmed so a later track event isn't mislabelled.
        emit subFetchRequested();
        return;
    }
    m_announceSub = true;
    QList<int> emb;
    const QList<int> ids = subCycleIds(&emb);
    bool ok = false;
    const int cur = m_sid.toInt(&ok);
    int pos = ok ? ids.indexOf(cur) : -1;
    if (ok && pos < 0)
        pos = emb.indexOf(cur);   // a bitmap whose OCR text is already in place
    const int next = pos + 1;     // "off" (pos -1) steps to the first track
    if (next >= ids.size())
        setProp("sid", QStringLiteral("no"));
    else
        setProp("sid", QString::number(ids[next]));
}

void MpvEngine::chapterStep(int dir)
{
    qint64 count = 0;
    if (m_mpv)
        mpv_get_property(m_mpv, "chapter-list/count", MPV_FORMAT_INT64, &count);
    if (count < 1) {
        emit osdMessage(QStringLiteral("NO CHAPTERS"));
        return;
    }
    command({QStringLiteral("add"), QStringLiteral("chapter"), QString::number(dir)});
    // mpv's own OSD renders inside the video frame — title with a fallback.
    command({QStringLiteral("show-text"),
             QStringLiteral("${chapter-metadata/by-key/title:CHAPTER ${chapter}}"),
             QStringLiteral("1800")});
}

void MpvEngine::addSubDelay(double seconds)
{
    command({QStringLiteral("add"), QStringLiteral("sub-delay"), QString::number(seconds)});
}

void MpvEngine::setSubDelay(double seconds)
{
    if (!m_mpv)
        return;
    mpv_set_option_string(m_mpv, "sub-delay", QByteArray::number(seconds, 'f', 3).constData());
}

void MpvEngine::reloadSubs()
{
    // the external file changed on disk (the hub re-timed it): re-read it
    command({QStringLiteral("sub-reload")});
}

void MpvEngine::setSubtitleBox(bool boxed)
{
    if (!m_mpv)
        return;
    mpv_set_option_string(m_mpv, "sub-border-style",
                          boxed ? "opaque-box" : "outline-and-shadow");
    mpv_set_option_string(m_mpv, "sub-back-color", boxed ? "#A6000000" : "#00000000");
}

void MpvEngine::setSubHonourStyle(bool honour)
{
    if (!m_mpv)
        return;
    // "force": codec's font, colour and border on ASS/SSA tracks too (one
    // look); "scale": the file's own styling
    mpv_set_option_string(m_mpv, "sub-ass-override", honour ? "scale" : "force");
}

void MpvEngine::applyZoomProperties(int mode)
{
    switch (mode) {
    case Zoom: // fill the screen, crop overflow — never stretch (Kodi "zoom")
        setProp("keepaspect", QStringLiteral("yes"));
        setProp("panscan", 1.0);
        break;
    case Stretch:
        setProp("keepaspect", QStringLiteral("no"));
        setProp("panscan", 0.0);
        break;
    case Fit:
    default:
        setProp("keepaspect", QStringLiteral("yes"));
        setProp("panscan", 0.0);
        break;
    }
}

void MpvEngine::setZoomMode(int mode)
{
    applyZoomProperties(mode);
    setZoomModeState(mode);
    static const char *names[] = {"FIT", "ZOOM", "STRETCH"};
    if (mode >= 0 && mode <= 2)
        emit osdMessage(QString::fromLatin1(names[mode]));
}

void MpvEngine::cycleZoomMode()
{
    setZoomMode((zoomMode() + 1) % 3);
}

void MpvEngine::processEvents()
{
    if (!m_mpv)
        return;
    while (true) {
        mpv_event *event = mpv_wait_event(m_mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        handleEvent(event);
    }
}

void MpvEngine::handleEvent(mpv_event *event)
{
    switch (event->event_id) {
    case MPV_EVENT_PROPERTY_CHANGE:
        handlePropertyChange(static_cast<mpv_event_property *>(event->data));
        break;
    case MPV_EVENT_FILE_LOADED:
        m_expectEof = true;
        // A cycle on a file with no sub/audio alternatives never fires the
        // aid/sid observer, so its announce latch would leak and mislabel
        // the NEXT track event (often this new file's auto-selection).
        m_announceAudio = m_announceSub = false;
        m_ocrAskedFor = -1;      // re-arm OCR-sub detection for the new file
        m_activeBitmapSub = -1;
        // A saved sub id that names no track in THIS file (an OCR sideload's
        // id, saved before those were mapped back to their bitmap) selected
        // nothing — and nothing then asked for the OCR text: no subs at all.
        // Read mpv's own state now (the file is loaded, its tracks are final)
        // and let it choose as on a first play.
        // (mpv reports a requested-but-missing id as "no", which would then be
        // SAVED as "subs off" — so key on what we asked for, not on sid.)
        if (m_mpv && m_requestedSid > 0) {
            const int want = m_requestedSid;
            mpv_node node;
            if (mpv_get_property(m_mpv, "track-list", MPV_FORMAT_NODE, &node) >= 0) {
                bool found = false, anySub = false;
                for (const QVariant &v : nodeToVariant(&node).toList()) {
                    const QVariantMap t = v.toMap();
                    if (t.value(QStringLiteral("type")).toString() != QLatin1String("sub"))
                        continue;
                    anySub = true;
                    if (t.value(QStringLiteral("id")).toInt() == want)
                        found = true;
                }
                mpv_free_node_contents(&node);
                if (anySub && !found)
                    setProp("sid", QStringLiteral("auto"));
            }
        }
        setIdle(false);
        setProp("speed", m_pendingSpeed);
        applyZoomProperties(m_pendingZoom);
        setZoomModeState(m_pendingZoom);
        emit fileLoaded();
        break;
    case MPV_EVENT_END_FILE: {
        auto *end = static_cast<mpv_event_end_file *>(event->data);
        const QString finished = path();
        setIdle(true);
        if (end->reason == MPV_END_FILE_REASON_EOF && m_expectEof)
            emit endReached(finished);
        else if (end->reason == MPV_END_FILE_REASON_ERROR)
            // e.g. an expired/403 stream URL — never leave a silent black player.
            emit loadFailed(finished,
                            QString::fromUtf8(mpv_error_string(end->error)));
        m_expectEof = false;
        if (m_hdrContent) { // video-params reports nothing once unloaded
            m_hdrContent = false;
            emit hdrContentChanged();
        }
        // #37: clear the video-params badge (resolution/HDR) on unload too, matching
        // the m_hdrContent reset — otherwise the OSD shows the PREVIOUS file's info
        // through idle and the next file's buffering.
        setVideoInfo(QString());
        break;
    }
    case MPV_EVENT_SHUTDOWN:
        emit shutdownRequested();
        break;
    case MPV_EVENT_COMMAND_REPLY:
    case MPV_EVENT_SET_PROPERTY_REPLY:
        // async command()/setProp() sent with reply_userdata 0 used to drop
        // every reply on the floor, so a rejected seek/track-switch/property
        // set failed silently. Surface the error at least in the log.
        if (event->error < 0)
            qWarning("codec mpv: async %s failed: %s",
                     event->event_id == MPV_EVENT_COMMAND_REPLY ? "command"
                                                                : "set_property",
                     mpv_error_string(event->error));
        break;
    default:
        break;
    }
}

void MpvEngine::handlePropertyChange(mpv_event_property *prop)
{
    const QByteArray name(prop->name);
    if (prop->format == MPV_FORMAT_NONE)
        return;

    if (name == "time-pos" && prop->format == MPV_FORMAT_DOUBLE) {
        setPosition(*static_cast<double *>(prop->data));
    } else if (name == "duration" && prop->format == MPV_FORMAT_DOUBLE) {
        setDuration(qMax(*static_cast<double *>(prop->data), m_durationHint));
    } else if (name == "pause" && prop->format == MPV_FORMAT_FLAG) {
        setPausedState(*static_cast<int *>(prop->data) != 0);
    } else if (name == "idle-active" && prop->format == MPV_FORMAT_FLAG) {
        setIdle(*static_cast<int *>(prop->data) != 0);
    } else if (name == "paused-for-cache" && prop->format == MPV_FORMAT_FLAG) {
        setCacheStalledState(*static_cast<int *>(prop->data) != 0);
    } else if (name == "media-title" && prop->format == MPV_FORMAT_STRING) {
        setMediaTitle(QString::fromUtf8(*static_cast<char **>(prop->data)));
    } else if (name == "volume" && prop->format == MPV_FORMAT_DOUBLE) {
        setVolumeState(*static_cast<double *>(prop->data));
    } else if (name == "mute" && prop->format == MPV_FORMAT_FLAG) {
        setMutedState(*static_cast<int *>(prop->data) != 0);
    } else if (name == "speed" && prop->format == MPV_FORMAT_DOUBLE) {
        const double sp = *static_cast<double *>(prop->data);
        m_speedSent = sp;   // track mpv's real speed so setSpeed()'s dedup guard
                            // can't silently no-op a party re-sync after a
                            // multiplySpeed/resetSpeed/FILE_LOADED change (#11)
        setSpeedState(sp);
    } else if (name == "track-list" && prop->format == MPV_FORMAT_NODE) {
        m_trackList = nodeToVariant(static_cast<mpv_node *>(prop->data)).toList();
        updateTrackTexts();
    } else if (name == "chapter-list" && prop->format == MPV_FORMAT_NODE) {
        m_chapters = nodeToVariant(static_cast<mpv_node *>(prop->data)).toList();
        emit chaptersChanged();
    } else if (name == "aid" && prop->format == MPV_FORMAT_STRING) {
        m_aid = QString::fromUtf8(*static_cast<char **>(prop->data));
        updateTrackTexts();
        // Announce here, not in updateTrackTexts(): a cycle fires both a
        // track-list and an aid/sid change, and track-list can land first
        // while m_aid/m_sid still hold the pre-cycle value — the toast would
        // read the stale track ("off" while subs render).
        if (m_announceAudio) {
            m_announceAudio = false;
            emit osdMessage(QStringLiteral("AUDIO ▸ ") + audioText());
        }
    } else if (name == "sid" && prop->format == MPV_FORMAT_STRING) {
        m_sid = QString::fromUtf8(*static_cast<char **>(prop->data));
        updateTrackTexts();
        if (m_announceSub) {
            m_announceSub = false;
            emit osdMessage(QStringLiteral("SUBS ▸ ") + subText());
        }
    } else if (name == "sub-delay" && prop->format == MPV_FORMAT_DOUBLE) {
        setSubDelayState(*static_cast<double *>(prop->data));
    } else if (name == "audio-device-list" && prop->format == MPV_FORMAT_NODE) {
        // Curate: only "auto" + real PipeWire/Pulse sinks. Raw alsa/* devices
        // grab the card exclusively and fail when the sound server holds it;
        // jack/sdl/openal/resampler entries are noise. This keeps the settings
        // picker to devices that actually work.
        const QVariantList raw =
            nodeToVariant(static_cast<mpv_node *>(prop->data)).toList();
        QVariantList curated;
        curated.append(QVariantMap{
            {QStringLiteral("name"), QStringLiteral("auto")},
            {QStringLiteral("description"), QStringLiteral("Default — follow system output")}});
        for (const QVariant &v : raw) {
            const QVariantMap d = v.toMap();
            const QString n = d.value(QStringLiteral("name")).toString();
            // One entry per physical sink: prefer the pipewire/ variant, skip
            // the duplicate pulse/ list and the bare "pipewire"/"auto".
            if (n.startsWith(QLatin1String("pipewire/")))
                curated.append(d);
        }
        m_audioDevices = curated;
        emit audioDevicesChanged();
    } else if (name == "audio-device" && prop->format == MPV_FORMAT_STRING) {
        m_audioDevice = QString::fromUtf8(*static_cast<char **>(prop->data));
        emit audioDevicesChanged();
    } else if (name == "video-params" && prop->format == MPV_FORMAT_NODE) {
        const QVariantMap params = nodeToVariant(static_cast<mpv_node *>(prop->data)).toMap();
        const int w = params.value(QStringLiteral("w")).toInt();
        const int h = params.value(QStringLiteral("h")).toInt();
        if (w > 0 && h > 0) {
            QString info = QStringLiteral("%1×%2").arg(w).arg(h);
            const QString prim = params.value(QStringLiteral("primaries")).toString();
            if (prim == QLatin1String("bt.2020"))
                info += QStringLiteral(" · HDR");
            setVideoInfo(info);
        }
        // The transfer function, not the primaries, is what makes a file HDR
        // (bt.2020 SDR encodes exist; PQ/HLG never lie).
        const QString gamma = params.value(QStringLiteral("gamma")).toString();
        const bool hdr = gamma == QLatin1String("pq") || gamma == QLatin1String("hlg");
        if (hdr != m_hdrContent) {
            m_hdrContent = hdr;
            emit hdrContentChanged();
        }
    }
}

void MpvEngine::updateTrackTexts()
{
    auto describe = [this](const QString &type, const QString &selected) -> QString {
        if (selected == QLatin1String("no") || selected.isEmpty())
            return type == QLatin1String("sub") ? QStringLiteral("off") : QStringLiteral("—");
        int count = 0;
        QString text;
        for (const QVariant &v : std::as_const(m_trackList)) {
            const QVariantMap track = v.toMap();
            if (track.value(QStringLiteral("type")).toString() != type)
                continue;
            ++count;
            if (QString::number(track.value(QStringLiteral("id")).toLongLong()) == selected) {
                const QString lang = track.value(QStringLiteral("lang")).toString();
                QString title = track.value(QStringLiteral("title")).toString();
                // an untitled URL track is named after the URL's tail by mpv
                // ("…mkv&i=0&srt=1") — a query string is never a label
                if (title.contains(QLatin1Char('?')) || title.contains(QLatin1Char('&'))
                    || title.contains(QLatin1String("://")))
                    title.clear();
                text = lang.isEmpty() ? QStringLiteral("#%1").arg(selected) : lang;
                if (!title.isEmpty())
                    text += QStringLiteral(" · ") + title;
            }
        }
        if (text.isEmpty())
            text = QStringLiteral("#%1").arg(selected);
        return count > 1 ? QStringLiteral("%1 (%2/%3)").arg(text, selected).arg(count) : text;
    };

    bool aOk = false, sOk = false;
    const int aid = m_aid.toInt(&aOk);
    const int sid = m_sid.toInt(&sOk);
    const QString audioText = describe(QStringLiteral("audio"), m_aid);
    const QString subText = describe(QStringLiteral("sub"), m_sid);
    // "no" persists as 0 (explicit off); -1 stays "never chose anything". But a
    // subtitle-LESS file also reports sid=="no" — that is "nothing to select",
    // not "user turned subs off". Persisting 0 there forces sid=no next play and
    // defeats auto-loading a sidecar .srt added later, so map to 0 only when sub
    // tracks actually exist; otherwise -1 (no preference).
    bool hasSub = false, hasAudio = false;
    for (const QVariant &v : std::as_const(m_trackList)) {
        const QString t = v.toMap().value(QStringLiteral("type")).toString();
        if (t == QLatin1String("sub")) hasSub = true;
        else if (t == QLatin1String("audio")) hasAudio = true;
    }
    // Audio-off is the exact inverse of the sub case above: cycling audio off
    // reports aid=="no", which toInt can't parse, so it used to save as -1 ("no
    // preference") and the next play auto-picked an audio track — the off-choice
    // was silently lost. Persist it as an explicit 0 (only when audio tracks
    // exist, so a truly audio-less file isn't pinned off).
    // An OCR sideload is saved as the BITMAP track it stands in for: its own id
    // only exists once it is sideloaded, so a saved "5" selected nothing on the
    // next play (and nothing then asked for the OCR) — no subs at all.
    int sidSave = sOk ? sid : -1;
    {
        QList<int> emb;
        subCycleIds(&emb);
        for (const QVariant &v : std::as_const(m_trackList)) {
            const QVariantMap t = v.toMap();
            if (t.value(QStringLiteral("type")).toString() != QLatin1String("sub")
                || t.value(QStringLiteral("id")).toInt() != sid)
                continue;
            const int k = ocrOrdinal(t);
            if (k >= 0 && k < emb.size())
                sidSave = emb[k];
        }
    }
    setTracks(audioText, subText,
              m_aid == QLatin1String("no") ? (hasAudio ? 0 : -1) : (aOk ? aid : -1),
              m_sid == QLatin1String("no") ? (hasSub ? 0 : -1) : sidSave);

    // If the ACTIVE sub is an EMBEDDED bitmap (PGS/dvdsub), this file has no
    // styleable text sub — mpv renders the source's baked-in image, which the
    // MGS caption styling can't touch. Ask the controller to sideload the hub's
    // OCR'd TEXT version and select it instead. Asked each time a bitmap track
    // BECOMES the active one — not once per file: a second PGS track picked
    // later (or the first one picked again) used to stay a plain bitmap.
    m_activeBitmapSub = -1;
    if (sOk && sid > 0) {
        int subIdx = 0;
        bool bitmap = false;
        for (const QVariant &v : std::as_const(m_trackList)) {
            const QVariantMap t = v.toMap();
            if (t.value(QStringLiteral("type")).toString() != QLatin1String("sub")
                || t.value(QStringLiteral("external")).toBool())
                continue;
            if (t.value(QStringLiteral("id")).toInt() == sid) {
                const QString c = t.value(QStringLiteral("codec")).toString();
                bitmap = c.contains(QLatin1String("pgs"))
                      || c.contains(QLatin1String("dvd_sub"))
                      || c.contains(QLatin1String("dvdsub"));
                m_ocrLang = t.value(QStringLiteral("lang")).toString();
                break;
            }
            ++subIdx;
        }
        if (bitmap) {
            m_activeBitmapSub = subIdx;
            if (m_ocrAskedFor != subIdx) {
                m_ocrAskedFor = subIdx;
                emit ocrSubRequested(subIdx);
            }
        }
    }
    if (m_activeBitmapSub < 0)
        m_ocrAskedFor = -1;   // left the bitmap: picking it again asks again
}
