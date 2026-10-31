#include "appcontroller.h"
#include "scriptpath.h"
#include "hubnam.h"
#include "uisound.h"
#include <QWheelEvent>
#include <QInputDevice>
#include "youtubesource.h"

#include "castmanager.h"
#include "logger.h"
#include "library.h"
#include "mpv/mpvengine.h"
#include "playbackengine.h"
#include "queuemodel.h"
#include "resumestore.h"
#include "theme.h"

#include <QCoreApplication>
#include <QSysInfo>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusUnixFileDescriptor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QPointer>
#include <QCryptographicHash>
#include <functional>
#include <QStandardPaths>
#include <QClipboard>
#include <QCursor>
#include <QDateTime>
#include <QtConcurrentRun>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <QTcpSocket>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QUrlQuery>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QColorSpace>
#include <QMouseEvent>
#include <QQuickItem>
#include <QProcess>
#include <QQuickWindow>
#include <QScreen>
#include <QSurfaceFormat>
#include <QImage>
#include <QImageReader>
#include <QDirIterator>
#include <QCollator>
#include <QStorageInfo>
#include <QRegularExpression>
#include <QUrl>
#include <algorithm>

#include <cmath>

// Kodi-style watched threshold: past this point the credits are all that's
// left, so it counts as seen (and resume restarts from the top).
static constexpr double kWatchedPct = 0.90;
// Batch2: keep cast seeks this far off EOF. The old dur-2 lands inside the final
// segment; a receiver seek there can't build a forward buffer and times out ->
// IDLE (found live seeking to the end of a 4K HDR cast). ~20s is several segments
// of runway so playback actually starts.
static constexpr double kCastEofRunwayS = 20.0;

// newest *.png mtime (ms) anywhere under `dir`, recursively — the live-reload poll's
// change signal across ALL mechui subfolders (hero/, speedo/, rows/, backings/, …).
static qint64 newestPngMtime(const QString &dir)
{
    qint64 mx = 0;
    QDirIterator it(dir, QStringList{QStringLiteral("*.png")}, QDir::Files,
                    QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        mx = qMax(mx, it.fileInfo().lastModified().toMSecsSinceEpoch());
    }
    return mx;
}

AppController::AppController(PlaybackEngine *engine, ResumeStore *store,
                             Library *library, QueueModel *queue,
                             CastManager *cast, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
    , m_store(store)
    , m_library(library)
    , m_queue(queue)
    , m_cast(cast)
{
    refreshMonitors();
    // Screens come and go under codec: the remote's POWER and the Pause lock
    // put a screen to sleep by force-disconnecting its connector, and waking
    // it is a hotplug. Let Hyprland finish moving windows, then follow.
    m_screenSettle.setSingleShot(true);
    m_screenSettle.setInterval(1000);
    connect(&m_screenSettle, &QTimer::timeout, this, &AppController::reconcileScreens);
    connect(qGuiApp, &QGuiApplication::screenAdded, this, [this] { m_screenSettle.start(); });
    connect(qGuiApp, &QGuiApplication::screenRemoved, this, [this] { m_screenSettle.start(); });

    // Periodic progress save while playing; also saved on pause/stop/quit.
    m_saveTimer.setInterval(10'000);
    connect(&m_saveTimer, &QTimer::timeout, this, &AppController::saveNow);

    m_remoteHoldTimer.setSingleShot(true);
    m_remoteHoldTimer.setInterval(700); // OFA remote tap-vs-hold threshold (deliberate hold)
    connect(&m_remoteHoldTimer, &QTimer::timeout, this, &AppController::remoteHoldFired);
    m_sleepTimer.setSingleShot(true);
    connect(&m_sleepTimer, &QTimer::timeout, this, [this] {   // timer up → 3·2·1, then stop + dark
        m_sleepCountdown = 3;
        emit toast(QStringLiteral("STOPPING PLAYBACK IN 3…"));
        m_sleepCountTimer.start(1000);
        emit sleepChanged();
    });
    m_sleepCountTimer.setInterval(1000);
    connect(&m_sleepCountTimer, &QTimer::timeout, this, [this] {
        if (--m_sleepCountdown > 0) {
            emit toast(QStringLiteral("STOPPING PLAYBACK IN %1…").arg(m_sleepCountdown));
            return;
        }
        m_sleepCountTimer.stop();
        m_sleepIdx = 0;
        emit sleepChanged();
        stopPlayback();
        if (m_sfx) m_sfx->hush();   // the sleep timer stops it quietly
        sleepDisplays();
    });
    // Roaming far-resume watchdog: if the raw remux hasn't started in 15s, the
    // link is too thin for a cold far seek — switch to the warm-HLS lane.
    m_resumeWatchdog.setSingleShot(true);
    m_resumeWatchdog.setInterval(15'000);
    connect(&m_resumeWatchdog, &QTimer::timeout, this,
            &AppController::tryHlsResumeFallback);
    // The hub link: re-probed off the GUI thread every 30 s so the top strip,
    // Settings and every hub call read a current answer (loadSettings starts it).
    m_linkTimer.setInterval(30'000);
    connect(&m_linkTimer, &QTimer::timeout, this, [this] { probeHubLink(false); });
    // Mid-film starvation on a remote raw file: a thin link away from the LAN
    // can feed the full remux for twenty minutes and then not. The resume
    // watchdog only covers a cold start, so this one watches mpv's cache: 20 s
    // stuck, and playback moves to the adaptive lane at the spot it reached
    // (the title keeps its resume row — playbackIdentity). Once.
    m_stallTimer.setSingleShot(true);
    m_stallTimer.setInterval(20'000);
    connect(m_engine, &PlaybackEngine::cacheStalledChanged, this, [this] {
        if (m_engine->cacheStalled() && !m_hlsFallbackUrl.isEmpty()
            && !m_resumeFellBack && !m_engine->idle())
            m_stallTimer.start();
        else
            m_stallTimer.stop();
    });
    connect(&m_stallTimer, &QTimer::timeout, this, [this] {
        if (!m_engine->cacheStalled() || m_hlsFallbackUrl.isEmpty() || m_resumeFellBack
            || m_engine->idle())
            return;
        const double pos = qMax(0.0, m_engine->position());
        const double dur = m_engine->duration();
        // re-aim the lane at where the film stalled, not the resume point
        const QString aimed = m_fallbackViaRoad
            ? publicUrlFor(m_playIdentity, QStringLiteral("hls/pl"),
                           QStringLiteral("&warm=%1&sdr=1&dur=%2")
                               .arg(int(pos / 4.0)).arg(int(dur)))
            : warmHlsUrl(m_playIdentity, pos, dur);
        if (aimed.isEmpty()) {   // the key expired under us: keep the armed lane as it was
            Logger::log(QStringLiteral("hub"), QStringLiteral("cache starved, no lane to re-aim"));
            return;
        }
        m_hlsFallbackUrl = aimed;
        m_hlsFallbackStart = pos;
        Logger::log(QStringLiteral("hub"),
                    QStringLiteral("cache starved %1 s at %2 s -> adaptive lane")
                        .arg(m_stallTimer.interval() / 1000).arg(int(pos)));
        tryHlsResumeFallback();
    });

    // Keep watch-state in step between devices WHILE the app runs — not only
    // at launch and quit. The queue already polls the hub continuously; watch
    // progress never did, so two machines left open drifted apart until one
    // was relaunched, and Continue Watching looked "out of sync all of a
    // sudden." This is the missing tick. 30s: brisk enough that a film paused
    // on one screen shows up on another before you walk to it, cheap enough
    // to ignore.
    m_syncTimer.setInterval(30'000);
    connect(&m_syncTimer, &QTimer::timeout, this, &AppController::syncState);
    m_syncTimer.start();

    // Hot-reload the user-sprite library when it changes on disk. The Asset
    // Viewer's "open in Aseprite" edits a PNG in an external editor, so watch the
    // sprites dir and re-emit userSpritesChanged (the same signal saveSprite fires)
    // — every sprite-bound element then re-reads the library. Debounced, since an
    // editor's write-temp-then-rename fires a burst; and re-added after each pass
    // because some editors replace the directory entry the watcher was holding.
    m_spritesWatcher.addPath(spritesDir());
    m_spritesReloadTimer.setSingleShot(true);
    m_spritesReloadTimer.setInterval(300);
    connect(&m_spritesWatcher, &QFileSystemWatcher::directoryChanged,
            this, [this] { m_spritesReloadTimer.start(); });
    connect(&m_spritesReloadTimer, &QTimer::timeout, this, [this] {
        if (!m_spritesWatcher.directories().contains(spritesDir()))
            m_spritesWatcher.addPath(spritesDir());
        emit userSpritesChanged();
    });

    // Dev hot-reload for the hero art (nameplate/bezel): watch heroDevDir(), and
    // on any change bump heroDevRev so QML re-reads the file:// override with a
    // fresh cache-bust query. Same debounce + re-add pattern as the sprites watcher.
    m_heroDevWatcher.addPath(heroDevDir());
    m_heroDevReloadTimer.setSingleShot(true);
    m_heroDevReloadTimer.setInterval(200);
    connect(&m_heroDevWatcher, &QFileSystemWatcher::directoryChanged,
            this, [this] { m_heroDevReloadTimer.start(); });
    connect(&m_heroDevReloadTimer, &QTimer::timeout, this, [this] {
        if (!m_heroDevWatcher.directories().contains(heroDevDir()))
            m_heroDevWatcher.addPath(heroDevDir());
        ++m_heroDevRev;
        emit heroDevRevChanged();
    });
    // The dir-watch above misses in-place content writes (many editors, incl.
    // Aseprite's Ctrl-S, rewrite the same file without touching the dir entry),
    // so it only caught relaunches. This mtime poll is the reliable trigger:
    // every 400ms take the newest PNG mtime in the dev dir; if it grew, an asset
    // was saved → bump rev so QML re-reads the ?v= cache-bust. Cheap (a stat per
    // file) and dev-only. Seed the baseline now so launch doesn't false-fire.
    m_heroDevMaxMtime = qMax(m_heroDevMaxMtime, newestPngMtime(heroDevDir()));
    m_heroDevPollTimer.setInterval(400);
    connect(&m_heroDevPollTimer, &QTimer::timeout, this, [this] {
        const qint64 mx = newestPngMtime(heroDevDir());
        if (mx > m_heroDevMaxMtime) {
            m_heroDevMaxMtime = mx;
            ++m_heroDevRev;
            emit heroDevRevChanged();
        }
    });
    // Dev live-reload poll (stat() per PNG 2.5×/s). This used to be gated by stage
    // — run only on stats/home/player/queue — which kept BREAKING: it missed the
    // PiP on browse stages, missed contexts, and worst of all only ever started on
    // a stage/queue SIGNAL, so if the initial stage was set without one the timer
    // never started at all ("not hot reloading, every time"). In a dev build
    // the poll now runs CONTINUOUSLY — the stat cost is trivial on the dev machine,
    // and a release/satellite build (heroDevDir → the empty runtime dev dir, NOT
    // the source tree) has no pngs to scan, so it self-disables.
    auto updateDevPoll = [this] {
        bool devArt = false;
#ifdef CODEC_SOURCE_DIR
        devArt = heroDevDir().startsWith(QStringLiteral(CODEC_SOURCE_DIR));
#endif
        if (devArt && !m_heroDevPollTimer.isActive())
            m_heroDevPollTimer.start();
        else if (!devArt && m_heroDevPollTimer.isActive())
            m_heroDevPollTimer.stop();
    };
    updateDevPoll();   // start NOW — don't wait for a stage/queue signal that may never come
    connect(this, &AppController::stageChanged, this, updateDevPoll);
    connect(this, &AppController::queueOpenChanged, this, updateDevPoll);

    // Opening-title range follows the file. Looked up once per load — the
    // player polls position, not the database.
    connect(m_engine, &PlaybackEngine::pathChanged, this, [this] {
        m_completedPath.clear(); // a new file loaded — completion guard spent
        const QVariantMap next = m_library->introFor(m_engine->path());
        if (next == m_introRange)
            return;
        m_introRange = next;
        Logger::log(QStringLiteral("intro"),
                    next.isEmpty()
                        ? QStringLiteral("none for %1").arg(m_engine->path())
                        : QStringLiteral("%1 → %2 for %3")
                              .arg(next.value(QStringLiteral("start")).toDouble())
                              .arg(next.value(QStringLiteral("end")).toDouble())
                              .arg(m_engine->path()));
        emit introRangeChanged();
    });

    // End credits: armed per load from the library (hub: credits table; laptop:
    // the manifest), checked against the position as it plays.
    connect(m_engine, &PlaybackEngine::pathChanged, this, [this] {
        m_creditsStart = m_library->creditsFor(playbackIdentity(m_engine->path()));
        m_creditsFired = false;
        m_creditsPath.clear();
    });
    // A file can load before the library knows its credits (a CLI/cold launch
    // plays off the warm-start cache; the nightly detector can add rows while
    // codec runs) — re-read on every scan until this load's prompt has fired.
    connect(m_library, &Library::scanned, this, [this] {
        if (!m_creditsFired && !m_engine->path().isEmpty())
            m_creditsStart = m_library->creditsFor(playbackIdentity(m_engine->path()));
    });
    connect(m_engine, &PlaybackEngine::positionChanged, this, &AppController::checkCredits);

    // The OSD's title art follows the file, and a scan (a logo fetched since,
    // a cold launch playing off the warm-start cache before the library is in).
    connect(m_engine, &PlaybackEngine::pathChanged, this, &AppController::updatePlayingLogo);
    connect(m_library, &Library::scanned, this, &AppController::updatePlayingLogo);

    connect(m_engine, &PlaybackEngine::endReached, this, [this](const QString &path) {
        // A live DVR snapshot ran out: that is "caught up", not the end.
        if (m_liveNow && m_liveDvr) {
            goLive();
            return;
        }
        // Live streams never get a completed/resume row — mirror the guard every
        // other watched/resume site uses (saveNow, maybeMarkWatched, leavePlayer).
        // Already banked at the credits (checkCredits) → don't count it twice.
        // Under the warm-HLS fallback the engine's path is the LANE url; the
        // title it stands in for is what gets completed and advanced from.
        const QString key = playbackIdentity(path);
        if (!ephemeralUri(key) && !m_liveNow && m_completedPath != path) {
            m_store->markCompleted(key); // position -> 0, completed=1, count+1
            m_library->refreshResume();
            // advanceAfter -> autoplayGo -> play(next) calls saveNow() BEFORE
            // the next file loads, while m_engine still points at THIS file with
            // position≈duration (setPath only changes on load). That stray save
            // would overwrite the completed row's position=0 with ≈dur, and
            // allWatchAgg would then bill watch_count*dur + dur ≈ 2× the real
            // time. Flag the path so saveNow skips exactly that one write; the
            // next real load clears it (pathChanged).
            m_completedPath = path;
        }
        advanceAfter(key);
    });

    // Cast leg: same bookkeeping + advance path as local playback.
    connect(m_cast, &CastManager::castEnded, this, [this](const QString &uri) {
        // credits shorter than the UP NEXT countdown: the end advances it instead
        castCreditsCancel(/*flash=*/false);
        // #3: a live stream has no real end/position — don't mark it completed.
        // Already banked at its end credits → don't count it twice.
        if ((m_liveUri.isEmpty() || uri != m_liveUri) && uri != m_castCreditsUri)
            m_store->markCompleted(uri);
        m_library->refreshResume();
        advanceAfter(uri);
    });
    connect(m_cast, &CastManager::castError, this, [this](const QString &e) {
        emit toast(QStringLiteral("CAST · %1").arg(e.toUpper()));
    });
    connect(m_cast, &CastManager::castAttached, this, [this](const QString &title) {
        // Another codec's cast adopted — surface the remote, touch nothing.
        emit toast(QStringLiteral("ATTACHED · %1").arg(title.toUpper()));
        setRemoteOpen(true);
    });
    m_castCreditsTimer.setSingleShot(true);
    m_castCreditsTimer.setInterval(10000);
    connect(&m_castCreditsTimer, &QTimer::timeout, this, &AppController::castCreditsGo);
    connect(m_cast, &CastManager::castStatusChanged, this, [this] {
        // Chapter marks for the cast scrub bar — guarded on the uri inside, so this
        // is one request per title, not one per poll.
        fetchCastChapters(m_cast->currentUri());
        checkCastCredits();
        // The TV's position feeds the same resume store (5s poll cadence),
        // so a cast half-watch resumes anywhere.
        //
        // Never bank a zero. An "attached" event (and any BUFFERING status)
        // reports position 0 alongside a *valid* duration, so a re-attach to a
        // session already an hour deep would otherwise overwrite the real
        // resume point with 0 — the watch silently vanishes. Position 0 says
        // nothing anyway: start-from-zero is what an absent row already means.
        const bool posMeaningful = m_cast->castPosition() > 1.0
                                   && m_cast->castState() != QLatin1String("BUFFERING");
        const bool liveCast = !m_liveUri.isEmpty()
                              && m_cast->currentUri() == m_liveUri;
        // (a title banked as watched at its end credits keeps no resume point)
        if (m_cast->active() && !m_cast->currentUri().isEmpty()
            && m_cast->currentUri() != m_castCreditsUri
            && m_cast->castDuration() > 0 && posMeaningful && !liveCast)  // #3: no live resume
            m_store->saveProgress(m_cast->currentUri(), m_cast->castPosition(),
                                  m_cast->castDuration(), -1, -1, -1.0, -1,
                                  m_mode);  // -1 sentinels: keep local track/speed/zoom prefs
        // Batch2 #4: a party-via-cast whose receiver is stuck IDLE while the room
        // clock has moved well past it is WEDGED (Bug B). The room can't self-heal
        // it — the solo-lock blocks a re-cast and §C only stops the 0-pin, leaving
        // the TV frozen. Arm a DEBOUNCED recovery: re-cast only if the IDLE PERSISTS
        // (a normal DV re-warm blips IDLE/BUFFERING and clears inside the window),
        // and stand down the instant it recovers on its own.
        if (m_partyViaCast
            && m_cast->castState() == QLatin1String("IDLE")
            && partyPos() > m_cast->castPosition() + 30.0) {
            if (!m_castRecoverTimer.isActive())
                m_castRecoverTimer.start();
        } else if (m_castRecoverTimer.isActive()) {
            m_castRecoverTimer.stop();   // recovered on its own — stand down
        }
        // Stats tick for cast playback (real elapsed, capped vs. bursts).
        static QElapsedTimer castTick;
        if (m_cast->castState() == QLatin1String("PLAYING")) {
            if (castTick.isValid()) {
                const qint64 ms = castTick.restart();
                if (ms > 500 && ms < 20'000)
                    m_store->addWatchTime(ms / 1000.0);
            } else {
                castTick.start();
            }
        } else {
            castTick.invalidate();
        }
    });
    connect(m_engine, &PlaybackEngine::loadFailed, this,
            [this](const QString &, const QString &error) {
        m_resumeWatchdog.stop();
        // A failed load is the strongest signal the reachability answer went
        // stale (walked out of range / suspend-resume / LAN dropped mid-window)
        // and handed mpv a now-dead URL. Re-probe the link right away so the
        // NEXT play/resume reads a fresh answer instead of the same wrong one.
        m_hubProbeAt = 0;
        probeHubLink(false);
        // A roaming raw-remux load that errors is exactly when the warm-HLS
        // lane helps — fall back to it instead of stranding the user.
        if (!m_hlsFallbackUrl.isEmpty() && !m_resumeFellBack) {
            tryHlsResumeFallback();
            return;
        }
        // a public-door play that the hub refused: the index the manifest gave
        // no longer names this title on the hub (a re-export since the last
        // sync) — say what to do, not "failed"
        if (m_playUrl.contains(QLatin1String("/r/")) && publicRoad())
            emit toast(QStringLiteral("LIBRARY OUT OF SYNC WITH THE HUB · SYNC, THEN RETRY"));
        else
            emit toast(QStringLiteral("PLAYBACK FAILED · %1").arg(error.toUpper()));
        if (m_stage == QLatin1String("player"))
            setStage(m_browseStage); // never strand the user on a black player
    });
    // The watchdog stands down when the raw remux is really PLAYING — the
    // position moving past the resume point. It used to stop on fileLoaded,
    // which mpv reports before a far seek has buffered a frame, so a cold far
    // resume on a thin link never fell back to the warm lane.
    connect(m_engine, &PlaybackEngine::positionChanged, this, [this] {
        if (m_resumeWatchdog.isActive()
            && m_engine->position() > m_hlsFallbackStart + 0.5)
            m_resumeWatchdog.stop();
    });
    connect(m_engine, &PlaybackEngine::pausedChanged, this, [this] {
        if (m_engine->paused())
            saveNow();
    });
    connect(m_engine, &PlaybackEngine::shutdownRequested, this, &AppController::quit);
    connect(m_engine, &PlaybackEngine::osdMessage, this, &AppController::toast);
    // A SUBS press on a file with no sub tracks falls through to an online fetch
    // rather than dead-ending — subs "just grab" on the first press.
    connect(m_engine, &PlaybackEngine::subFetchRequested, this, &AppController::findSubtitles);
    // The subtitle nudge (X/C): a readout, and remembered per film.
    connect(m_engine, &PlaybackEngine::subDelayChanged, this, &AppController::onSubDelayChanged);
    m_subDelaySave.setSingleShot(true);
    m_subDelaySave.setInterval(1200);
    connect(&m_subDelaySave, &QTimer::timeout, this, [this] {
        const QString key = playbackIdentity(m_engine->path());
        if (!key.isEmpty() && m_store)
            m_store->saveSubDelay(key, std::round(m_engine->subDelay() * 100.0) / 100.0);
    });
    m_subSyncTimer.setInterval(5000);
    connect(&m_subSyncTimer, &QTimer::timeout, this, &AppController::pollSubSync);
    // a cast caption change reaches a running cast at once (the worker
    // pushes the style over its sub channel)
    connect(this, &AppController::castCaptionsChanged, this, [this] {
        if (m_cast && castingNow())
            m_cast->pushSubStyle();
    });
    connect(m_engine, &PlaybackEngine::ocrSubRequested, this, &AppController::loadOcrSubtitle);

    // Cross-machine shared queue (0.9.13: always-on, not just while casting):
    // every edit on any device pushes to the hub; every codec polls and
    // adopts newer revisions (LWW) — a queue built on the desktop is already
    // on the laptop when it opens, and vice versa.
    m_nam = new HubNam(this);   // a satellite's hub key rides its requests to the hub
    m_castqPushTimer.setSingleShot(true);
    m_castqPushTimer.setInterval(800);
    connect(&m_castqPushTimer, &QTimer::timeout,
            this, &AppController::castQueuePush);
    m_castqPollTimer.setInterval(5000);
    connect(&m_castqPollTimer, &QTimer::timeout,
            this, &AppController::castQueuePoll);
    m_castqPollTimer.start();
    // Seed from the persisted stamp so a RESTORED queue still wins LWW
    // against a hub revision that predates it (restart used to zero this
    // and let a stale hub copy clobber the saved queue on first poll).
    m_castqLastEdit = m_queue->lastEditMs();
    const auto queueEdited = [this] {
        if (m_adoptingQueue)
            return; // adopting the hub's revision is not a local edit
        m_castqLastEdit = QDateTime::currentMSecsSinceEpoch();
        m_castqPushTimer.start();
    };
    connect(m_queue, &QAbstractItemModel::rowsInserted, this, queueEdited);
    connect(m_queue, &QAbstractItemModel::rowsRemoved, this, queueEdited);
    connect(m_queue, &QAbstractItemModel::rowsMoved, this, queueEdited);
    connect(m_queue, &QAbstractItemModel::dataChanged, this, queueEdited);

    // Watch party (0.9.19). partyPoll runs from launch to quit, whether or not
    // this instance started anything: a session belongs to the house, so every
    // codec that opens should be able to see it and walk into it. partyFollow
    // is the finer loop that keeps local playback on the hub's clock while
    // we're actually in the session. partyPublish is the app-mode leftover —
    // this app's own playback as the clock.
    // A stable handle per machine, NOT per launch: keyed on the pid, quitting
    // and reopening codec left your old self sitting in the room until it aged
    // out, and the roster counted you twice.
    m_partyGuestId = QStringLiteral("codec-") + QSysInfo::machineHostName();
    m_partyPublishTimer.setInterval(1500);
    connect(&m_partyPublishTimer, &QTimer::timeout, this,
            [this] {
                if (m_partyViaCast) partyPublishCast();   // #218: pin room to DV host
                else if (m_partyHosting) partyPublish(false);
            });
    // #218: a scrub-burst on the host would otherwise fire one m_cast->seek() per
    // drag, hammering the DV copy-muxer into a 45s-segment 504 (it lost DV and reset
    // to 0 under a stress test). Coalesce: only the FINAL target after a short quiet
    // window hits the room clock AND the DV lane — one clean re-warm, the way the old
    // follower-chase deadband coalesced a burst for free.
    m_castSeekDebounce.setSingleShot(true);
    m_castSeekDebounce.setInterval(350);
    connect(&m_castSeekDebounce, &QTimer::timeout, this, [this] {
        if (m_pendingSeekPos < 0)
            return;
        const double p = m_pendingSeekPos;
        m_pendingSeekPos = -1;
        if (!(m_partyViaCast && partyHubMode())) {
            // role cleared during the 350ms debounce (party ended/left) — just
            // seek the now-solo cast, no room command or publish-hold. (#25)
            m_cast->seek(p);
            m_castPublishHoldUntil = 0;
            m_castPublishTarget = -1;
            return;
        }
        partyCmd(QStringLiteral("seek"), p);   // room clock -> final target
        m_cast->seek(p);                        // host DV lane -> final target (one re-warm)
        // seek-fight belt: the DV re-warm reports the STALE pre-seek position for
        // ~5s. Hold off pinning the room clock (partyPublishCast) until the cast
        // has actually reached this target, or a safety window elapses — so a stale
        // pin can't overwrite the seek we just sent. Server cooldown is the keystone.
        m_castPublishTarget = p;
        m_castPublishHoldUntil = QDateTime::currentMSecsSinceEpoch() + 6500;
    });
    // Batch2 #4: a PERSISTENT wedge (armed by castStatusChanged) fires this ONCE to
    // rebuild the same party lane on the receiver at the room clock. Single-shot +
    // re-check on fire so a transient IDLE during a normal re-warm never re-casts.
    m_castRecoverTimer.setSingleShot(true);
    m_castRecoverTimer.setInterval(9000);
    connect(&m_castRecoverTimer, &QTimer::timeout, this, [this] {
        if (m_partyViaCast
            && m_cast->castState() == QLatin1String("IDLE")
            && partyPos() > m_cast->castPosition() + 30.0)
            castPartyRecover();
    });
    m_partyPollTimer.setInterval(3000);
    connect(&m_partyPollTimer, &QTimer::timeout, this, &AppController::partyPoll);
    m_partyPollTimer.start();
    QTimer::singleShot(0, this, &AppController::partyPoll);
    m_partyFollowTimer.setInterval(2000);
    connect(&m_partyFollowTimer, &QTimer::timeout, this, &AppController::partyFollow);
    // Presence (0.9.25): announce solo playback so another screen can take it.
    // Same cadence as the party clock — it is the same kind of claim, and it
    // is also how a handoff reaches us, since the stop rides the reply.
    m_nowPublishTimer.setInterval(2000);
    connect(&m_nowPublishTimer, &QTimer::timeout, this, &AppController::nowPublish);
    m_nowPublishTimer.start();
    // Physical-TV-remote control (Phase 2): while a cast is live, drain the hub's
    // per-device /rc queue that the Cast receiver POSTs remote keypresses into,
    // and fire the matching transport method. Fast (300ms) so Audio/Subtitle/
    // Channel/Red/Green feel responsive; the GET is skipped when nothing is cast.
    m_rcPollTimer.setInterval(300);
    connect(&m_rcPollTimer, &QTimer::timeout, this, &AppController::rcPoll);
    m_rcPollTimer.start();
    // A hub watches its own server for a device asking to join (pairing):
    // the prompt must appear while the person is still at the other machine.
    m_pairTimer.setInterval(2000);
    connect(&m_pairTimer, &QTimer::timeout, this, &AppController::pairPoll);
    m_pairTimer.start();
    QTimer::singleShot(1500, this, [this] {
        if (!m_library->remoteMode())
            refreshSharing();
    });
    m_nowSeekTimer.setInterval(250);
    connect(&m_nowSeekTimer, &QTimer::timeout, this, [this] {
        // Place the position once the NEW file is genuinely open. 10s of
        // tries, then give up — better to start a film at the beginning than
        // to seek whatever happens to be playing by then.
        if (++m_nowSeekTries > 40 || m_nowSeekTo < 0) {
            m_nowSeekTimer.stop();
            m_nowSeekTo = -1;
            return;
        }
        if (m_engine->idle() || m_engine->duration() <= 0)
            return;
        m_engine->seekAbs(m_nowSeekTo);
        m_nowSeekTo = -1;
        m_nowSeekTimer.stop();
    });
    connect(m_engine, &PlaybackEngine::pausedChanged, this,
            [this] { if (m_partyHosting) partyPublish(false); });
    connect(m_engine, &PlaybackEngine::fileLoaded, this,
            [this] { if (m_partyHosting) partyPublish(true); });
    // Putting on a different film while hosting moves the whole party to it,
    // rather than leaving everyone else staring at the old one.
    connect(m_engine, &PlaybackEngine::fileLoaded, this, [this] {
        m_partyFileOk = true;   // whatever this screen last opened has opened
        if (!m_partyFollowing || !partyHubMode() || m_engine->path().isEmpty())
            return;
        if (isPartyStream(m_engine->path()))
            return;  // the room's own stream (a screen without the file) IS the room's film
        if (m_store->mediaKey(m_engine->path()) == m_partyKey)
            return;  // same movie, just reopened
        partyLoadMedia();
    });
    // A queue prepared BEFORE casting was never pushed (edits only sync
    // while active) — the first poll then adopted the hub's stale revision
    // and silently cleared it. Connecting with items claims the hub rev.
    connect(m_cast, &CastManager::targetChanged, this, [this] {
        if (m_cast->active() && m_queue->count() > 0) {
            m_castqLastEdit = QDateTime::currentMSecsSinceEpoch();
            castQueuePush();
        }
    });

    // UI sounds are quiet while a film plays here (UiSound::setQuiet).
    connect(m_engine, &PlaybackEngine::pausedChanged, this, &AppController::updateSfxQuiet);
    connect(m_engine, &PlaybackEngine::idleChanged, this, &AppController::updateSfxQuiet);
    // Screen-lock / suspend inhibition follows the play/pause/idle state.
    connect(m_engine, &PlaybackEngine::pausedChanged, this, &AppController::updateIdleInhibit);
    connect(m_engine, &PlaybackEngine::idleChanged, this, &AppController::updateIdleInhibit);
    connect(this, &AppController::stageChanged, this, &AppController::updateIdleInhibit);
    // A live cast must keep THIS machine awake too — the local engine is idle
    // during a cast, so the play/pause signals above never fire. Key the
    // inhibitor off the cast target as well (esp. the laptop upstairs with its
    // lid shut: suspend would kill the session and lose remote control).
    connect(m_cast, &CastManager::targetChanged, this, &AppController::updateIdleInhibit);
    // The screensaver inhibitor (setInhibited) is a single Inhibit call held by
    // cookie. If the org.freedesktop.ScreenSaver owner (hypridle) restarts, that
    // cookie is orphaned and the screen starts idling/locking mid-playback while we
    // still think we're inhibited. Re-acquire a fresh cookie on any owner change.
    auto *ssWatcher = new QDBusServiceWatcher(
        QStringLiteral("org.freedesktop.ScreenSaver"), QDBusConnection::sessionBus(),
        QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(ssWatcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &newOwner) {
        if (!newOwner.isEmpty() && m_inhibited) {
            m_inhibitCookie = 0;          // the previous owner's cookie is dead
            acquireScreensaverInhibit();  // take a fresh one from the new owner
        }
    });

    // In-app HDR: engage tracks content (PQ/HLG), stage (fullscreen player
    // only — PiP browsing drops back to SDR) and cast state.
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        connect(mpv, &MpvEngine::hdrContentChanged,
                this, &AppController::updateHdrEngaged);
    connect(this, &AppController::stageChanged,
            this, &AppController::updateHdrEngaged);
    connect(m_cast, &CastManager::targetChanged,
            this, &AppController::updateHdrEngaged);
    m_hdrDebounce.setSingleShot(true);
    m_hdrDebounce.setInterval(300);
    connect(&m_hdrDebounce, &QTimer::timeout, this,
            [this] { setHdrEngaged(hdrWanted()); });

    // Cursor hides 1s after the last movement.
    m_cursorTimer.setSingleShot(true);
    m_cursorTimer.setInterval(1000);
    connect(&m_cursorTimer, &QTimer::timeout, this, &AppController::hideCursor);
    // Entering the player always parks the pointer — don't wait for the
    // idle timeout (which a stationary mouse can't apply anyway on Wayland).
    connect(this, &AppController::stageChanged, this, [this] {
        if (m_stage == QLatin1String("player")) {
            m_cursorTimer.stop();
            hideCursor();
        }
    });

    m_attractTimer.setSingleShot(true);
    connect(&m_attractTimer, &QTimer::timeout, this, [this] { setAttract(true); });
    // Anything that changes what the screen is doing re-decides whether the
    // idle clock should even be running.
    connect(this, &AppController::stageChanged, this, &AppController::armAttract);
    connect(m_engine, &PlaybackEngine::idleChanged, this, &AppController::armAttract);
    connect(m_engine, &PlaybackEngine::pausedChanged, this, &AppController::armAttract);
    armAttract();

    // Keep the metadata in step with disk without waiting for the nightly job:
    // a scan that finds new files fetches their art, and one that finds deleted
    // files prunes them (so the laptop manifest never shows a ghost).
    connect(m_library, &Library::reconcileNeeded, this, &AppController::reconcileLibrary);
    connect(m_library, &Library::scanned, this, &AppController::onLibraryScanned);

    // Satellites re-pull the hub manifest every half hour so a codec left
    // open overnight still picks up the nightly scrape (no-op on the hub).
    m_libPullTimer.setInterval(30 * 60 * 1000);
    connect(&m_libPullTimer, &QTimer::timeout, this, &AppController::pullLibrary);
    m_libPullTimer.start();

    // While a YouTube video is actually playing, re-ping watchtime every 30s so
    // the account's resume position tracks along (start/stop pings alone often
    // don't persist a resume the phone can pick up).
    // Live DVR clock: watched time, the moving window, and the auto-return to
    // the live lane once a rewind has caught up.
    m_liveTick.setInterval(1000);
    connect(&m_liveTick, &QTimer::timeout, this, [this] {
        if (!m_liveNow) { m_liveTick.stop(); return; }
        const qint64 dt = m_liveWatchClock.restart();
        if (!m_engine->paused() && !m_engine->idle())
            m_liveWatchedMs += dt;
        if (m_liveDvr && !m_engine->paused() && liveBehind() < 8.0
            && m_engine->position() > 1.0)
            goLive();
        emit liveStateChanged();
    });
    m_ytPingTimer.setInterval(30 * 1000);
    connect(&m_ytPingTimer, &QTimer::timeout, this, [this] {
        // Casting a YouTube video counts as watching it, same as local play.
        if (m_cast->active()) {
            if (m_cast->castState() == QLatin1String("PLAYING"))
                ytHistoryPing(m_cast->currentUri(), m_cast->castPosition());
            return;
        }
        if (!m_engine->paused() && !m_engine->idle())
            ytHistoryPing(m_engine->path(), m_engine->position());
    });

    loadSettings();
}

void AppController::setSubtitleLift(bool lifted)
{
    // Slide subtitles clear of the OSD while it is up. Lives here rather than
    // on the engine interface because only the mpv backend has a notion of
    // sub-pos — a cast lane burns or sideloads instead.
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setSubtitleLift(lifted);
}

void AppController::loadSettings()
{
    // The look codec ships with: the garage editor's settings as the author tuned them
    // (assets/look.json, written from his config by scripts/codec_bake_look.py).
    // Any key the person's config doesn't set reads from here. It stays in
    // memory only — saveSetting writes just the key that changed — so a config
    // never fills up with them and a re-baked look reaches everyone who hasn't
    // changed that dial themselves.
    QVariantMap look;
    QFile lf(QStringLiteral(":/look/look.json"));
    if (lf.open(QIODevice::ReadOnly))
        look = QJsonDocument::fromJson(lf.readAll()).object()
                   .value(QStringLiteral("settings")).toObject().toVariantMap();
    QFile f(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
            + QStringLiteral("/codec/config.json"));
    if (!f.open(QIODevice::ReadOnly)) {
        m_settings = look;
        return;
    }
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    m_settings = root.value(QStringLiteral("settings")).toObject().toVariantMap();
    for (auto it = look.cbegin(); it != look.cend(); ++it)
        if (!m_settings.contains(it.key()))
            m_settings.insert(it.key(), it.value());
    // The default audio-language pref lives at top-level audio.language (the
    // contract the cast worker reads), not inside the settings block.
    const QString lang = root.value(QStringLiteral("audio")).toObject()
                             .value(QStringLiteral("language")).toString();
    if (!lang.isEmpty())
        m_audioLanguage = lang.toLower();
    const QString dev = m_settings.value(QStringLiteral("audioDevice")).toString();
    if (!dev.isEmpty()) {
        if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
            mpv->setAudioDevice(dev);
    }
    // The miniplayer's remembered corner (set through setPipLeft/Top, which save).
    m_pipLeft = m_settings.value(QStringLiteral("pipLeft"), false).toBool();
    m_pipTop = m_settings.value(QStringLiteral("pipTop"), false).toBool();
    emit pipCornerChanged();
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setNightMode(nightMode());
    applyLocalCaptions(); // font + colour + size to the engine (persist across loads)
    applyAutoUpdate(); // arm/disarm the live filesystem watcher per the setting
    // The hub's roads, once; then the first link probe (async — the first play
    // gates on a synchronous one only if it comes before this lands).
    loadHubConfig();
    probeHubLink(false);
    m_linkTimer.start();
    syncState(); // pull watch-state from the hub on launch
    pullLibrary(); // satellites: catch up with the hub's library NOW
    pullHubQueue(); // anything queued from another device lands here
}

void AppController::syncState()
{
    // Merge resume/watched state with the hub, and refresh the home lists when
    // the merge brings something new. Never blocks the UI.
    const QString script = codecScript(QStringLiteral("codec_sync_state.py"));

    // Is there a hub to talk to? On the hub ITSELF (no syncUrl) the script is
    // a no-op — but the hub's DB is the file a satellite writes into when it
    // pushes, so this machine still needs to notice those rows and rebuild
    // Continue Watching. Refresh without spawning a process that would only
    // print "no hub configured — skip".
    QString syncUrl;
    QFile cf(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
             + QStringLiteral("/codec/config.json"));
    if (cf.open(QIODevice::ReadOnly))
        syncUrl = QJsonDocument::fromJson(cf.readAll()).object()
                      .value(QStringLiteral("syncUrl")).toString();

    if (syncUrl.isEmpty() || !QFile::exists(script)) {
        Logger::log(QStringLiteral("sync"), QStringLiteral("hub tick (refresh only)"));
        maybeNotifyResume();
        return;
    }
    Logger::log(QStringLiteral("sync"), QStringLiteral("satellite tick -> ") + syncUrl);

    // One at a time. Two of these writing the same SQLite file race on the
    // merge and one loses to "database is locked" — and the 30s timer plus a
    // stop-triggered sync can otherwise overlap.
    if (m_syncProc && m_syncProc->state() != QProcess::NotRunning)
        return;
    if (!m_syncProc) {
        m_syncProc = new QProcess(this);
        connect(m_syncProc,
                QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this](int, QProcess::ExitStatus) {
                    // The merged rows are on disk now — recompute if they moved.
                    m_library->refreshResume();
                    maybeNotifyResume();
                });
    }
    m_syncProc->start(QStringLiteral("/usr/bin/python3"), {script});
}

void AppController::maybeNotifyResume()
{
    // `scanned` is, in practice, "a library-derived list may have changed —
    // recompute the home rows"; Continue Watching is exactly such a list. But
    // firing it every 30s would rebuild the spotlight and reorder rows under
    // an idle user for no reason, so gate on a real change: the row count and
    // the newest last_played together move whenever any watch does.
    if (!m_store)
        return;
    const QString fp = m_store->stateFingerprint();
    if (fp.isEmpty() || fp == m_lastResumeFp)
        return;
    m_lastResumeFp = fp;
    Logger::log(QStringLiteral("sync"), QStringLiteral("watch-state moved, refreshing home"));
    m_library->notifyResumeSynced();
}

double AppController::subtitleScale() const
{
    const double s = m_settings.value(QStringLiteral("subtitleScale"), 1.0).toDouble();
    return s > 0.1 ? s : 1.0;
}

// One step around a preset ring in either direction (Settings' Left/Right):
// negative steps back, anything else (0 included) steps forward.
static int wrapStep(int i, int n, int dir)
{
    const int d = dir < 0 ? -1 : 1;
    return ((i + d) % n + n) % n;
}

void AppController::cycleSubtitleSize(int dir)
{
    // XXXXS -> XXXS -> XXS -> XS -> SMALL -> MEDIUM -> LARGE -> XL -> wrap
    // (applies locally right away; cast streams pick it up on the next stream
    // (re)start). 0.25 is mpv's sub-scale floor (setSubtitleScale clamps there).
    static const double steps[] = {0.3, 0.4, 0.5, 0.65, 0.8, 1.0, 1.25, 1.5};
    static const char *names[] = {"XXXXS", "XXXS", "XXS", "XS",
                                  "SMALL", "MEDIUM", "LARGE", "XL"};
    constexpr int N = 8;
    const double cur = subtitleScale();
    int idx = 5; // MEDIUM if the stored value matches nothing
    for (int i = 0; i < N; ++i)
        if (qAbs(steps[i] - cur) < 0.05)
            idx = i;
    idx = wrapStep(idx, N, dir);
    saveSetting(QStringLiteral("subtitleScale"), steps[idx]);
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setSubtitleScale(steps[idx]);
    emit subtitleScaleChanged();
    emit toast(QStringLiteral("CAPTION SIZE ▸ %1")
                   .arg(QLatin1String(names[idx])));
}

bool AppController::nightMode() const
{
    return m_settings.value(QStringLiteral("nightMode"), false).toBool();
}

void AppController::toggleNightMode()
{
    const bool on = !nightMode();
    saveSetting(QStringLiteral("nightMode"), on);
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setNightMode(on);
    emit nightModeChanged();
    emit toast(on ? QStringLiteral("NIGHT MODE ▸ ON  (dialogue up, booms down)")
                  : QStringLiteral("NIGHT MODE ▸ OFF"));
}

bool AppController::mechPalette() const
{
    return m_settings.value(QStringLiteral("mechPalette"), true).toBool();
}

void AppController::setTheme(Theme *theme)
{
    m_theme = theme;
    if (m_theme)
        m_theme->setMechPalette(mechPalette());   // apply the persisted choice at launch
}

void AppController::toggleMechPalette()
{
    const bool on = !mechPalette();
    saveSetting(QStringLiteral("mechPalette"), on);
    if (m_theme)
        m_theme->setMechPalette(on);
    emit mechPaletteChanged();
    emit toast(on ? QStringLiteral("THEME ▸ MECH  (fixed palette)")
                  : QStringLiteral("THEME ▸ PYWAL  (from wallpaper)"));
}

// The ` garage editor. Off = the views never build the editor layer at all
// (panel, lock reticle, lens, grids) and ` does nothing — a lighter home.
bool AppController::editorEnabled() const
{
    // Off unless turned on (Settings ▸ SYSTEM): the garage editor is the author's
    // workbench for tuning the shipped look, not part of using codec.
    return m_settings.value(QStringLiteral("editorEnabled"), false).toBool();
}

void AppController::toggleEditorEnabled()
{
    const bool on = !editorEnabled();
    saveSetting(QStringLiteral("editorEnabled"), on);
    emit editorEnabledChanged();
    emit toast(on ? QStringLiteral("EDITOR ▸ ON  (` opens the garage)")
                  : QStringLiteral("EDITOR ▸ OFF  (garage unloaded)"));
}

int AppController::attractMinutes() const
{
    // Default ON: a feature that ships switched off is a feature nobody sees.
    // One keypress in Settings turns it off.
    return m_settings.value(QStringLiteral("attractMinutes"), 5).toInt();
}

void AppController::cycleAttractDelay(int dir)
{
    static const int steps[] = {0, 2, 5, 10};
    const int now = attractMinutes();
    int next = 0;
    for (int i = 0; i < 4; ++i)
        if (steps[i] == now) { next = steps[wrapStep(i, 4, dir)]; break; }
    saveSetting(QStringLiteral("attractMinutes"), next);
    emit attractMinutesChanged();
    armAttract();
    emit toast(next == 0 ? QStringLiteral("ATTRACT MODE ▸ OFF")
                         : QStringLiteral("ATTRACT MODE ▸ AFTER %1 MIN").arg(next));
}

int AppController::spotlightSeconds() const
{
    // How long each home backdrop holds. Default is a calm hold, not a churn.
    return m_settings.value(QStringLiteral("spotlightSeconds"), 18).toInt();
}

void AppController::cycleSpotlightSeconds(int dir)
{
    static const int steps[] = {10, 18, 30, 0}; // 0 = hold (manual only)
    const int now = spotlightSeconds();
    int next = 18;
    for (int i = 0; i < 4; ++i)
        if (steps[i] == now) { next = steps[wrapStep(i, 4, dir)]; break; }
    saveSetting(QStringLiteral("spotlightSeconds"), next);
    emit spotlightSecondsChanged();
    emit toast(next == 0 ? QStringLiteral("SPOTLIGHT ▸ HOLD")
                         : QStringLiteral("SPOTLIGHT ▸ %1 S").arg(next));
}

QString AppController::redactionStyle() const
{
    // How the mini-info synopsis resolves: black censor bars (default), light
    // bars, a plain typewriter, or off (shown instantly).
    return m_settings.value(QStringLiteral("redactionStyle"),
                            QStringLiteral("redact")).toString();
}

void AppController::cycleRedactionStyle(int dir)
{
    static const char *steps[] = {"redact", "light", "type", "off"};
    const QString now = redactionStyle();
    QString next = QStringLiteral("redact");
    for (int i = 0; i < 4; ++i)
        if (now == QLatin1String(steps[i])) { next = QLatin1String(steps[wrapStep(i, 4, dir)]); break; }
    saveSetting(QStringLiteral("redactionStyle"), next);
    emit redactionStyleChanged();
    static const QMap<QString, QString> labels{
        {QStringLiteral("redact"), QStringLiteral("REDACTED ▸ BLACK BARS")},
        {QStringLiteral("light"),  QStringLiteral("REDACTED ▸ LIGHT BARS")},
        {QStringLiteral("type"),   QStringLiteral("SYNOPSIS ▸ TYPEWRITER")},
        {QStringLiteral("off"),    QStringLiteral("SYNOPSIS ▸ INSTANT")}};
    emit toast(labels.value(next));
}

double AppController::glassLevel() const
{
    // Opacity of the menu / queue / OSD / picker plate backings: 1.0 = solid,
    // lower = glassier (the backdrop bleeds through). The home wheel buttons are
    // tuned separately and don't read this. Default fairly solid.
    const double v = m_settings.value(QStringLiteral("glassLevel"), 0.85).toDouble();
    return (v >= 0.2 && v <= 1.0) ? v : 0.85;
}

void AppController::cycleGlassLevel(int dir)
{
    static const double steps[] = {1.0, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4};
    const int n = int(sizeof(steps) / sizeof(steps[0]));
    const double now = glassLevel();
    int idx = 0;
    for (int i = 0; i < n; ++i)
        if (qAbs(now - steps[i]) < 0.001) { idx = i; break; }
    const double next = steps[wrapStep(idx, n, dir)];
    saveSetting(QStringLiteral("glassLevel"), next);
    emit glassLevelChanged();
    emit toast(QStringLiteral("GLASS ▸ ") + QString::number(qRound(next * 100))
               + QStringLiteral("% SOLID"));
}

int AppController::seekStep() const
{
    const int s = m_settings.value(QStringLiteral("seekStepS"), 10).toInt();
    return s > 0 ? s : 10;
}

int AppController::castCaptionScale() const
{
    // Percent of the receiver's own size. Cast sizes captions for
    // accessibility, which reads BIG on a television showing a film, so the
    // default is deliberately under 100.
    const int v = m_settings.value(QStringLiteral("castCaptionScale"), 72).toInt();
    return qBound(50, v, 150);
}

bool AppController::castCaptionBg() const
{
    return m_settings.value(QStringLiteral("castCaptionBg"), false).toBool();
}

void AppController::cycleCastCaptionScale(int dir)
{
    static const int steps[] = {60, 72, 85, 100, 125};
    const int now = castCaptionScale();
    int next = 72;
    for (int i = 0; i < 5; ++i)
        if (steps[i] == now) { next = steps[wrapStep(i, 5, dir)]; break; }
    saveSetting(QStringLiteral("castCaptionScale"), next);
    emit castCaptionsChanged();
    emit toast(QStringLiteral("CAST CAPTIONS ▸ %1%").arg(next));
}

void AppController::toggleCastCaptionBg()
{
    const bool on = !castCaptionBg();
    saveSetting(QStringLiteral("castCaptionBg"), on);
    emit castCaptionsChanged();
    emit toast(on ? QStringLiteral("CAST CAPTIONS ▸ BOXED")
                  : QStringLiteral("CAST CAPTIONS ▸ OUTLINED"));
}

// Small labelled key-cycles for the cast-caption font/color and the audio
// language. The stored values (font key, colour hex, ISO code) are exactly what
// the hub receiver (_CAP_FONTS/_caption_color) and cast worker (_pref_audio_lang)
// already read — this only adds a keyboard way to change them.
namespace {
struct Labeled { const char *key; const char *label; };
const Labeled kCapFonts[] = {
    {"mgs", "MGS CODEC"}, {"mgshud", "MGS HUD"}, {"sans", "SANS"},
    {"serif", "SERIF"}, {"mono", "MONO"},
};
const Labeled kCapColors[] = {
    {"#FFFFFF", "WHITE"}, {"#FFD400", "YELLOW"}, {"#FFB000", "AMBER"},
    {"#4FD6EA", "CYAN"}, {"#7CFC7C", "GREEN"},
};
const Labeled kAudioLangs[] = {
    {"eng", "ENGLISH"}, {"jpn", "JAPANESE"}, {"kor", "KOREAN"},
    {"spa", "SPANISH"}, {"fra", "FRENCH"}, {"ind", "INDONESIAN"},
};
template <size_t N>
QString labelFor(const Labeled (&tbl)[N], const QString &key, const QString &fallback)
{
    for (const auto &e : tbl)
        if (key.compare(QLatin1String(e.key), Qt::CaseInsensitive) == 0)
            return QString::fromLatin1(e.label);
    return fallback;
}
template <size_t N>
QString nextKey(const Labeled (&tbl)[N], const QString &key, int dir = 1)
{
    for (size_t i = 0; i < N; ++i)
        if (key.compare(QLatin1String(tbl[i].key), Qt::CaseInsensitive) == 0)
            return QString::fromLatin1(tbl[wrapStep(int(i), int(N), dir)].key);
    return QString::fromLatin1(tbl[0].key);
}
} // namespace

QString AppController::castCaptionFontLabel() const
{
    const QString key = m_settings.value(QStringLiteral("castCaptionFont"),
                                         QStringLiteral("mgs")).toString();
    return labelFor(kCapFonts, key, QStringLiteral("MGS CODEC"));
}

QString AppController::castCaptionColorHex() const
{
    return m_settings.value(QStringLiteral("castCaptionColor"),
                            QStringLiteral("#FFFFFF")).toString();
}

QString AppController::castCaptionColorName() const
{
    return labelFor(kCapColors, castCaptionColorHex(), castCaptionColorHex());
}

void AppController::cycleCastCaptionFont(int dir)
{
    const QString cur = m_settings.value(QStringLiteral("castCaptionFont"),
                                         QStringLiteral("mgs")).toString();
    const QString next = nextKey(kCapFonts, cur, dir);
    saveSetting(QStringLiteral("castCaptionFont"), next);
    emit castCaptionsChanged();
    emit toast(QStringLiteral("CAST CAPTION FONT ▸ ") + labelFor(kCapFonts, next, next));
}

void AppController::cycleCastCaptionColor(int dir)
{
    const QString next = nextKey(kCapColors, castCaptionColorHex(), dir);
    saveSetting(QStringLiteral("castCaptionColor"), next);
    emit castCaptionsChanged();
    emit toast(QStringLiteral("CAST CAPTION COLOR ▸ ") + labelFor(kCapColors, next, next));
}

// ── Local captions (mpv, this screen) — mirror the cast dials, applied live ──
QString AppController::localCaptionFontLabel() const
{
    const QString key = m_settings.value(QStringLiteral("localCaptionFont"),
                                         QStringLiteral("mgs")).toString();
    return labelFor(kCapFonts, key, QStringLiteral("MGS CODEC"));
}

QString AppController::localCaptionFontFamily() const
{
    // font KEY → the family libmpv resolves (MGS faces via sub-fonts-dir; the
    // rest are fontconfig generics).
    const QString key = m_settings.value(QStringLiteral("localCaptionFont"),
                                         QStringLiteral("mgs")).toString();
    if (key == QLatin1String("mgs"))    return QStringLiteral("MGS1 Codec");
    if (key == QLatin1String("mgshud")) return QStringLiteral("MGS1 HUD");
    if (key == QLatin1String("serif"))  return QStringLiteral("serif");
    if (key == QLatin1String("mono"))   return QStringLiteral("monospace");
    return QStringLiteral("sans-serif"); // "sans" + any fallback
}

QString AppController::localCaptionColorHex() const
{
    return m_settings.value(QStringLiteral("localCaptionColor"),
                            QStringLiteral("#FFFFFF")).toString();
}

QString AppController::localCaptionColorName() const
{
    return labelFor(kCapColors, localCaptionColorHex(), localCaptionColorHex());
}

void AppController::applyLocalCaptions()
{
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine)) {
        mpv->setSubtitleFont(localCaptionFontFamily());
        mpv->setSubtitleColor(localCaptionColorHex());
        mpv->setSubtitleScale(subtitleScale());
        mpv->setSubtitleBox(localCaptionBg());
        mpv->setSubHonourStyle(subHonourStyle());
    }
}

bool AppController::localCaptionBg() const
{
    return m_settings.value(QStringLiteral("localCaptionBg"), false).toBool();
}

void AppController::toggleLocalCaptionBg()
{
    const bool on = !localCaptionBg();
    saveSetting(QStringLiteral("localCaptionBg"), on);
    applyLocalCaptions();
    emit localCaptionsChanged();
    emit toast(on ? QStringLiteral("CAPTIONS ▸ BOXED") : QStringLiteral("CAPTIONS ▸ OUTLINED"));
}

bool AppController::subHonourStyle() const
{
    return m_settings.value(QStringLiteral("subHonourStyle"), false).toBool();
}

void AppController::toggleSubHonourStyle()
{
    const bool on = !subHonourStyle();
    saveSetting(QStringLiteral("subHonourStyle"), on);
    applyLocalCaptions();
    emit localCaptionsChanged();
    emit toast(on ? QStringLiteral("SUB FILES ▸ THEIR OWN STYLING")
                  : QStringLiteral("SUB FILES ▸ CODEC'S STYLE"));
}

QString AppController::frameRateMode() const
{
    return m_settings.value(QStringLiteral("frameRate")).toString() == QLatin1String("60")
               ? QStringLiteral("60") : QStringLiteral("display");
}

void AppController::toggleFrameRate()
{
    saveSetting(QStringLiteral("frameRate"),
                frameRateMode() == QLatin1String("60") ? QStringLiteral("display")
                                                       : QStringLiteral("60"));
    emit frameRateChanged();
    emit toast((frameRateMode() == QLatin1String("60")
                    ? QStringLiteral("FRAME RATE ▸ STANDARD 60")
                    : QStringLiteral("FRAME RATE ▸ MATCH DISPLAY"))
               + (frameRatePending() ? QStringLiteral(" · ON RESTART") : QString()));
}

void AppController::noteRenderLoop(const QString &loop)
{
    m_frameRateLive = loop == QLatin1String("threaded") ? QStringLiteral("display")
                                                        : QStringLiteral("60");
    Logger::log(QStringLiteral("display"),
                QStringLiteral("render loop %1 (FRAME RATE %2)")
                    .arg(loop.isEmpty() ? QStringLiteral("qt default") : loop,
                         frameRateMode() == QLatin1String("60") ? QStringLiteral("STANDARD 60")
                                                                : QStringLiteral("MATCH DISPLAY")));
    emit frameRateChanged();
}

bool AppController::osdTitleLogo() const
{
    return m_settings.value(QStringLiteral("osdTitleLogo"), true).toBool();
}

void AppController::toggleOsdTitleLogo()
{
    saveSetting(QStringLiteral("osdTitleLogo"), !osdTitleLogo());
    emit osdTitleLogoChanged();
}

bool AppController::castingNow() const
{
    if (!m_cast)
        return false;
    const QString st = m_cast->castState();
    return !st.isEmpty() && st != QLatin1String("IDLE") && !m_cast->currentUri().isEmpty();
}

void AppController::cycleLocalCaptionFont(int dir)
{
    const QString cur = m_settings.value(QStringLiteral("localCaptionFont"),
                                         QStringLiteral("mgs")).toString();
    const QString next = nextKey(kCapFonts, cur, dir);
    saveSetting(QStringLiteral("localCaptionFont"), next);
    applyLocalCaptions();
    emit localCaptionsChanged();
    emit toast(QStringLiteral("CAPTION FONT ▸ ") + labelFor(kCapFonts, next, next));
}

void AppController::cycleLocalCaptionColor(int dir)
{
    const QString next = nextKey(kCapColors, localCaptionColorHex(), dir);
    saveSetting(QStringLiteral("localCaptionColor"), next);
    applyLocalCaptions();
    emit localCaptionsChanged();
    emit toast(QStringLiteral("CAPTION COLOR ▸ ") + labelFor(kCapColors, next, next));
}

QString AppController::audioLanguageLabel() const
{
    return labelFor(kAudioLangs, m_audioLanguage, m_audioLanguage.toUpper());
}

void AppController::cycleAudioLanguage(int dir)
{
    const QString next = nextKey(kAudioLangs, m_audioLanguage, dir);
    m_audioLanguage = next;
    saveSectionSetting(QStringLiteral("audio"), QStringLiteral("language"), next);
    emit audioLanguageChanged();
    emit toast(QStringLiteral("AUDIO LANGUAGE ▸ ") + labelFor(kAudioLangs, next, next));
}

void AppController::cycleSeekStep(int dir)
{
    static const int steps[] = {5, 10, 15, 30};
    const int now = seekStep();
    int next = 10;
    for (int i = 0; i < 4; ++i)
        if (steps[i] == now) { next = steps[wrapStep(i, 4, dir)]; break; }
    saveSetting(QStringLiteral("seekStepS"), next);
    emit seekStepChanged();
    emit toast(QStringLiteral("SEEK STEP ▸ %1S").arg(next));
}

bool AppController::autoplayNext() const
{
    return m_settings.value(QStringLiteral("autoplayNext"), true).toBool();
}

void AppController::toggleAutoplay()
{
    const bool on = !autoplayNext();
    saveSetting(QStringLiteral("autoplayNext"), on);
    emit autoplayNextChanged();
    emit toast(on ? QStringLiteral("AUTOPLAY NEXT EPISODE ▸ ON")
                  : QStringLiteral("AUTOPLAY NEXT EPISODE ▸ OFF"));
}

QString AppController::hdrPeakLabel() const
{
    const int p = m_settings.value(QStringLiteral("hdrPeakNits"), 0).toInt();
    if (p > 0)
        return QStringLiteral("%1 NITS").arg(p);
    return m_edidPeakNits > 0
        ? QStringLiteral("AUTO (%1 NITS)").arg(m_edidPeakNits)
        : QStringLiteral("AUTO");
}

void AppController::cycleHdrPeak(int dir)
{
    static const int steps[] = {0, 400, 600, 1000};
    const int now = m_settings.value(QStringLiteral("hdrPeakNits"), 0).toInt();
    int next = 0;
    for (int i = 0; i < 4; ++i)
        if (steps[i] == now) { next = steps[wrapStep(i, 4, dir)]; break; }
    saveSetting(QStringLiteral("hdrPeakNits"), next);
    emit hdrPeakChanged();
    emit toast(QStringLiteral("HDR PEAK ▸ ") + hdrPeakLabel());
    // Mid-playback change takes effect live — retarget mpv without a window
    // or monitor transition.
    if (m_hdrEngaged) {
        double peak = next > 0 ? next : (m_edidPeakNits > 0 ? m_edidPeakNits : 400);
        if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
            mpv->setHdrOutput(true, qBound(100.0, peak, 10000.0));
    }
}

void AppController::armAttract()
{
    // Never over the top of the thing you are actually watching: not in the
    // player, not while something plays in the PiP dock, not while casting.
    const bool playing = !m_engine->idle() && !m_engine->paused();
    const bool eligible = attractMinutes() > 0 && m_stage != QLatin1String("player")
                          && m_stage != QLatin1String("chooser")
                          && !playing && m_cast->targetId().isEmpty();
    if (!eligible) {
        m_attractTimer.stop();
        setAttract(false);
        return;
    }
    if (m_attract)
        return;
    // Dev hook (same spirit as CODEC_SHOT): CODEC_ATTRACT_MS shortens the
    // idle wait so the mode can be verified without waiting out real minutes.
    const int devMs = qEnvironmentVariableIntValue("CODEC_ATTRACT_MS");
    m_attractTimer.start(devMs > 0 ? devMs : attractMinutes() * 60'000);
}

void AppController::setAttract(bool on)
{
    if (on == m_attract)
        return;
    m_attract = on;
    emit attractChanged();
}

namespace {
// Advisory lock spanning a whole config.json read-modify-write. The lock file
// is a DEDICATED sidecar (config.json.lock) that is never renamed, so flock
// actually coordinates — the config itself is atomically replaced on every
// write, which would swap the inode out from under anyone locking it. Python
// helpers (codec_speedtest / codec_party_appid) flock the same path, so the app
// and the tooling can't lose each other's updates.
struct ConfigFlock {
    int fd = -1;
    explicit ConfigFlock(const QString &cfgPath) {
        const QByteArray lp = (cfgPath + QStringLiteral(".lock")).toLocal8Bit();
        fd = ::open(lp.constData(), O_CREAT | O_RDWR, 0644);
        if (fd >= 0)
            ::flock(fd, LOCK_EX); // blocks until other writers release
    }
    ~ConfigFlock() {
        if (fd >= 0) { ::flock(fd, LOCK_UN); ::close(fd); }
    }
    ConfigFlock(const ConfigFlock &) = delete;
    ConfigFlock &operator=(const ConfigFlock &) = delete;
};
} // namespace

bool AppController::writeConfigAtomic(const QJsonObject &root)
{
    const QString path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec/config.json");
    QDir().mkpath(QFileInfo(path).absolutePath());
    // QSaveFile writes to a temp file and swaps it in atomically on commit()
    // (with an fsync), so an interrupted write leaves the last-good config
    // intact instead of a truncated file that loadSettings reads as {}.
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    return f.commit();
}

void AppController::saveSetting(const QString &key, const QVariant &value)
{
    m_settings.insert(key, value);
    const QString path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec/config.json");
    // On a fresh machine ~/.config/codec/ may not exist yet — make it before the
    // lock so the .lock file (and the config write) can actually be created.
    QDir().mkpath(QFileInfo(path).absolutePath());
    // Hold the lock across the read AND the write so a concurrent helper/app
    // write can't slip between them and get clobbered by our stale snapshot.
    ConfigFlock lock(path);
    QFile f(path);
    QJsonObject root;
    if (f.open(QIODevice::ReadOnly)) {
        root = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
    }
    // Apply ONLY the changed key onto the settings object as it is on disk,
    // rather than overwriting the whole block with our startup snapshot — so an
    // external edit (a myOS script, or a hand-edit) to any other key made while
    // codec is running survives instead of being clobbered on the next save.
    QJsonObject s = root.value(QStringLiteral("settings")).toObject();
    s.insert(key, QJsonValue::fromVariant(value));
    root.insert(QStringLiteral("settings"), s);
    writeConfigAtomic(root);
}

void AppController::saveSectionSetting(const QString &section, const QString &key,
                                       const QVariant &value)
{
    const QString path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec/config.json");
    QDir().mkpath(QFileInfo(path).absolutePath());
    // Same read-modify-write-under-lock discipline as saveSetting, but the key
    // lands in a top-level section object (audio.language) instead of settings.
    ConfigFlock lock(path);
    QFile f(path);
    QJsonObject root;
    if (f.open(QIODevice::ReadOnly)) {
        root = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
    }
    QJsonObject s = root.value(section).toObject();
    s.insert(key, QJsonValue::fromVariant(value));
    root.insert(section, s);
    writeConfigAtomic(root);
}

void AppController::putSetting(const QString &key, const QVariant &value)
{
    saveSetting(key, value);
}

QVariant AppController::getSetting(const QString &key, const QVariant &def) const
{
    return m_settings.value(key, def);
}

int AppController::queryKbdModifiers() const
{
    return static_cast<int>(QGuiApplication::queryKeyboardModifiers());
}

// ── Pixel Forge sprite I/O ────────────────────────────────────────────────
QString AppController::spritesDir() const
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
        + QStringLiteral("/sprites");
    QDir().mkpath(dir);
    return dir;
}

QString AppController::heroDevDir() const
{
    // Dev builds hot-reload hero art straight from the project's scratch folder
    // (where the art is drawn) — no separate hidden dir. Falls back to the
    // runtime data dir if the source tree isn't present (installed build).
#ifdef CODEC_SOURCE_DIR
    // the LIVE mechui-art ROOT — the same PNGs baked into the qrc, so a dev build
    // reads them live off disk and an external edit shows at once. ANYTHING under
    // assets/mechui/<group>/ (hero, speedo, rows, backings, …) hot-reloads.
    //
    // ONLY the hub (the dev machine where the art is actually drawn) does this.
    // A satellite built in-place at ~/Projects/codec also has assets/mechui/ on
    // disk, so without this guard it would read art live off its own (possibly
    // stale or partially-synced) checkout and NEVER exercise the qrc baked at
    // build time — the exact thing a release ships. remoteMode() == satellite.
    if (!(m_library && m_library->remoteMode())) {
        const QString proj = QStringLiteral(CODEC_SOURCE_DIR) + QStringLiteral("/assets/mechui");
        if (QDir(proj).exists()) return proj;
    }
#endif
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
        + QStringLiteral("/dev");
    QDir().mkpath(dir);
    return dir;
}

QString AppController::heroDevPath(const QString &rel) const
{
    // `rel` is a subfolder-relative asset id (e.g. "speedo/vfd" or "hero/hero-bezel").
    // Sanitise each path segment (alnum/_/- only, drop empties + any ".."), resolve to
    // <mechui>/<rel>.png, and return the file:// URL only if it exists — else "" so the
    // caller falls back to the baked qrc asset.
    if (m_devPathCacheRev != m_heroDevRev) {
        m_devPathCache.clear();
        m_devPathCacheRev = m_heroDevRev;
    }
    if (const auto c = m_devPathCache.constFind(rel); c != m_devPathCache.constEnd())
        return c.value();
    const QString url = heroDevPathUncached(rel);
    m_devPathCache.insert(rel, url);
    return url;
}

QString AppController::heroDevPathUncached(const QString &rel) const
{
    static const QRegularExpression kUnsafe(QStringLiteral("[^A-Za-z0-9_-]"));
    QStringList parts;
    const auto segs = rel.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (QString s : segs) {
        s.replace(kUnsafe, QStringLiteral("_"));
        if (!s.isEmpty())
            parts << s;
    }
    if (parts.isEmpty())
        return QString();
    // 1) exact path — <mechui>/<rel>.png (keeps hero/ and any group-exact reference working)
    const QString full = heroDevDir() + QStringLiteral("/") + parts.join(QLatin1Char('/'))
        + QStringLiteral(".png");
    if (QFileInfo::exists(full))
        return QUrl::fromLocalFile(full).toString();
    // 2) fallback — find <basename>.png ANYWHERE under mechui. This is what lets you drop an
    // asset into a group subfolder (bars/, plates/, …) and have it live-edit by filename, with
    // the flat qrc/qml paths untouched. Index is cached per heroDevRev so a save is one rescan.
    if (m_devFileIndexRev != m_heroDevRev) {
        m_devFileIndex.clear();
        QDirIterator it(heroDevDir(), QStringList{QStringLiteral("*.png")}, QDir::Files,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            const QString fp = it.filePath();
            // Don't let a backup/hidden copy shadow the live plate: the walk
            // descends into .bak/backup dirs and dotfiles, and first-match-wins
            // could pick a stale one over the real asset.
            if (fp.contains(QLatin1String("/.")) || fp.contains(QLatin1String(".bak"))
                || fp.contains(QLatin1String("backup"), Qt::CaseInsensitive))
                continue;
            const QString base = it.fileInfo().completeBaseName();
            // first match wins — a warning fires below only if a real collision is hit
            if (!m_devFileIndex.contains(base))
                m_devFileIndex.insert(base, it.filePath());
        }
        m_devFileIndexRev = m_heroDevRev;
    }
    const auto hit = m_devFileIndex.constFind(parts.last());
    if (hit != m_devFileIndex.constEnd())
        return QUrl::fromLocalFile(hit.value()).toString();
    return QString();
}

bool AppController::saveSprite(const QString &name, int w, int h, const QVariantList &argb)
{
    // a single frame is <=256², but a composed strip (frames*fw) is wide — allow
    // up to 8192 on either axis so the whole animation can be written back out
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return false;
    if (argb.size() != w * h) return false;
    QString base = name.trimmed();
    base.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9_-]")), QStringLiteral("_"));
    if (base.isEmpty()) base = QStringLiteral("sprite");
    QImage img(w, h, QImage::Format_ARGB32);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            img.setPixel(x, y, static_cast<QRgb>(argb.at(y * w + x).toUInt()));
    const QString path = spritesDir() + QStringLiteral("/") + base + QStringLiteral(".png");
    const bool ok = img.save(path, "PNG");
    if (ok) emit userSpritesChanged();
    return ok;
}

QVariantList AppController::userSprites() const
{
    QVariantList out;
    QDir dir(spritesDir());
    const QStringList files = dir.entryList(QStringList{QStringLiteral("*.png")},
                                            QDir::Files, QDir::Time);
    for (const QString &f : files) {
        const QString full = dir.filePath(f);
        const QImage img(full);
        QVariantMap m;
        m.insert(QStringLiteral("name"), QFileInfo(f).completeBaseName());
        m.insert(QStringLiteral("file"), f);
        m.insert(QStringLiteral("path"), full);
        m.insert(QStringLiteral("url"), QUrl::fromLocalFile(full).toString());
        m.insert(QStringLiteral("w"), img.width());
        m.insert(QStringLiteral("h"), img.height());
        out.append(m);
    }
    return out;
}

QVariantMap AppController::loadSprite(const QString &path) const
{
    QVariantMap out;
    QString p = path;
    if (p.startsWith(QStringLiteral("file://"))) p = QUrl(p).toLocalFile();
    else if (p.startsWith(QStringLiteral("qrc:/"))) p = p.mid(3);   // qrc:/a → :/a (resource)
    QImage img(p);
    if (img.isNull()) return out;
    img = img.convertToFormat(QImage::Format_ARGB32);
    const int w = img.width(), h = img.height();
    QVariantList argb;
    argb.reserve(w * h);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            argb.append(static_cast<uint>(img.pixel(x, y)));
    out.insert(QStringLiteral("w"), w);
    out.insert(QStringLiteral("h"), h);
    out.insert(QStringLiteral("argb"), argb);
    return out;
}

// ── Import: raw external asset packs ──────────────────────────────────────
QString AppController::importDir() const
{
    QString d = m_settings.value(QStringLiteral("importDir")).toString();
    if (d.isEmpty())
        d = QStringLiteral(CODEC_SOURCE_DIR "/source-assets");
    return d;
}

QVariantList AppController::importAssets() const
{
    QVariantList out;
    QDir root(importDir());
    if (!root.exists()) return out;
    QDirIterator it(root.absolutePath(), QStringList{QStringLiteral("*.png")},
                    QDir::Files, QDirIterator::Subdirectories);
    int guard = 0;
    while (it.hasNext() && guard < 4000) {
        const QString full = it.next(); ++guard;
        QImageReader r(full);
        const QSize sz = r.size();               // header-only, no full decode
        if (!sz.isValid()) continue;
        const QFileInfo fi(full);
        QString rel = root.relativeFilePath(fi.absolutePath());
        if (rel.isEmpty() || rel == QLatin1String(".")) rel = QStringLiteral("· root");
        QVariantMap m;
        m.insert(QStringLiteral("name"), fi.completeBaseName());
        m.insert(QStringLiteral("file"), fi.fileName());
        m.insert(QStringLiteral("path"), full);
        m.insert(QStringLiteral("url"), QUrl::fromLocalFile(full).toString());
        m.insert(QStringLiteral("pack"), rel);
        m.insert(QStringLiteral("w"), sz.width());
        m.insert(QStringLiteral("h"), sz.height());
        out.append(m);
    }
    std::sort(out.begin(), out.end(), [](const QVariant &a, const QVariant &b) {
        const QVariantMap ma = a.toMap(), mb = b.toMap();
        const QString pa = ma.value(QStringLiteral("pack")).toString();
        const QString pb = mb.value(QStringLiteral("pack")).toString();
        if (pa != pb) return pa < pb;
        return ma.value(QStringLiteral("name")).toString()
             < mb.value(QStringLiteral("name")).toString();
    });
    return out;
}

QVariantMap AppController::loadSpriteFrame(const QString &path, int frames, int index) const
{
    QVariantMap out;
    QString p = path;
    if (p.startsWith(QStringLiteral("file://"))) p = QUrl(p).toLocalFile();
    else if (p.startsWith(QStringLiteral("qrc:/"))) p = p.mid(3);   // qrc:/a → :/a (resource)
    QImage img(p);
    if (img.isNull()) return out;
    img = img.convertToFormat(QImage::Format_ARGB32);
    if (frames < 1) frames = 1;
    const int fw = img.width() / frames;
    const int fh = img.height();
    if (fw < 1) return out;
    const int fx = qBound(0, index, frames - 1) * fw;
    QVariantList argb;
    argb.reserve(fw * fh);
    for (int y = 0; y < fh; ++y)
        for (int x = 0; x < fw; ++x)
            argb.append(static_cast<uint>(img.pixel(fx + x, y)));
    out.insert(QStringLiteral("w"), fw);
    out.insert(QStringLiteral("h"), fh);
    out.insert(QStringLiteral("argb"), argb);
    return out;
}

// ── Asset Viewer — external-editor bridge ─────────────────────────────────
// Aseprite authors; codec curates + integrates. Editing only ever happens on a
// real filesystem file (the user-sprites library) — qrc-baked assets live inside
// the binary and can't be edited in place, so callers fork them to the library
// first. openInAseprite is detached fire-and-forget (mirrors the python workers).
bool AppController::asepriteAvailable() const
{
    return !QStandardPaths::findExecutable(QStringLiteral("aseprite")).isEmpty();
}

bool AppController::openInAseprite(const QString &path) const
{
    QString p = path;
    if (p.startsWith(QStringLiteral("file://"))) p = QUrl(p).toLocalFile();
    // a baked asset has no on-disk file to edit — refuse (caller forks first)
    if (p.startsWith(QStringLiteral("qrc:/")) || p.startsWith(QStringLiteral(":/"))) return false;
    if (p.isEmpty() || !QFileInfo::exists(p)) return false;
    return QProcess::startDetached(QStringLiteral("aseprite"), QStringList{p});
}

QString AppController::forkToLibrary(const QString &path, const QString &nameHint)
{
    // resolve source: file:// path, a bare filesystem path, or a qrc:/ baked asset
    QString src = path;
    if (src.startsWith(QStringLiteral("file://"))) src = QUrl(src).toLocalFile();
    QString qrc = src;
    const bool baked = qrc.startsWith(QStringLiteral("qrc:/")) || qrc.startsWith(QStringLiteral(":/"));
    if (qrc.startsWith(QStringLiteral("qrc:/"))) qrc = qrc.mid(3);   // qrc:/a → :/a
    if (!baked && !QFileInfo::exists(src)) return QString();
    // clean, unique destination name in the editable library
    QString base = (nameHint.isEmpty() ? QFileInfo(src).completeBaseName() : nameHint).trimmed();
    base.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9_-]")), QStringLiteral("_"));
    if (base.isEmpty()) base = QStringLiteral("asset");
    const QString dir = spritesDir();
    QString dest = dir + QStringLiteral("/") + base + QStringLiteral(".png");
    int n = 2;
    while (QFileInfo::exists(dest))
        dest = dir + QStringLiteral("/") + base + QStringLiteral("-")
             + QString::number(n++) + QStringLiteral(".png");
    // filesystem source → byte-exact copy (preserves the user's original art);
    // baked source → decode from the resource and re-encode to disk.
    bool ok = false;
    if (!baked) {
        ok = QFile::copy(src, dest);
    } else {
        QImage img(qrc);
        ok = !img.isNull() && img.save(dest, "PNG");
    }
    if (!ok) return QString();
    emit userSpritesChanged();
    return QUrl::fromLocalFile(dest).toString();
}

QVariantList AppController::mediaRoots() const
{
    QFile f(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
            + QStringLiteral("/codec/config.json"));
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(f.readAll())
        .object().value(QStringLiteral("roots")).toArray().toVariantList();
}

void AppController::saveMediaRoots(const QVariantList &roots)
{
    const QString path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec/config.json");
    QDir().mkpath(QFileInfo(path).absolutePath()); // fresh machine: dir may not exist yet
    ConfigFlock lock(path); // read-through-write under the shared config lock
    QFile f(path);
    QJsonObject rootObj;
    if (f.open(QIODevice::ReadOnly)) {
        rootObj = QJsonDocument::fromJson(f.readAll()).object();
        f.close();
    }
    rootObj.insert(QStringLiteral("roots"), QJsonArray::fromVariantList(roots));
    writeConfigAtomic(rootObj);
    emit mediaRootsChanged();
    m_library->rescan();
}

void AppController::addMediaRoot(const QString &path, const QString &kind)
{
    QString p = path.trimmed();
    if (p.startsWith(QLatin1String("~/")))
        p = QDir::home().filePath(p.mid(2));
    if (p.isEmpty())
        return;
    if (!QDir(p).exists()) {
        emit toast(QStringLiteral("NO SUCH DIRECTORY · %1").arg(p));
        return;
    }
    QVariantList roots = mediaRoots();
    for (const QVariant &r : std::as_const(roots)) {
        if (r.toMap().value(QStringLiteral("path")).toString() == p) {
            emit toast(QStringLiteral("ALREADY A MEDIA PATH"));
            return;
        }
    }
    roots.append(QVariantMap{{QStringLiteral("path"), p},
                             {QStringLiteral("kind"), kind == QLatin1String("tv")
                                                          ? QStringLiteral("tv")
                                                          : QStringLiteral("movies")}});
    saveMediaRoots(roots);
    emit toast(QStringLiteral("MEDIA PATH ADDED · %1").arg(p));
}

void AppController::removeMediaRoot(int index)
{
    QVariantList roots = mediaRoots();
    if (index < 0 || index >= roots.size())
        return;
    const QString p = roots[index].toMap().value(QStringLiteral("path")).toString();
    roots.removeAt(index);
    saveMediaRoots(roots);
    emit toast(QStringLiteral("MEDIA PATH REMOVED · %1").arg(p));
}

void AppController::toggleMediaRootKind(int index)
{
    QVariantList roots = mediaRoots();
    if (index < 0 || index >= roots.size())
        return;
    QVariantMap r = roots[index].toMap();
    const bool tv = r.value(QStringLiteral("kind")).toString() == QLatin1String("tv");
    r.insert(QStringLiteral("kind"), tv ? QStringLiteral("movies") : QStringLiteral("tv"));
    roots[index] = r;
    saveMediaRoots(roots);
    emit toast(QStringLiteral("%1 → %2").arg(r.value(QStringLiteral("path")).toString(),
                                             r.value(QStringLiteral("kind")).toString().toUpper()));
}

namespace {

QString humanBytes(qint64 b)
{
    const double gb = double(b) / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 1000.0)
        return QString::number(gb / 1024.0, 'f', 1) + QStringLiteral(" TB");
    return QString::number(qRound(gb)) + QStringLiteral(" GB");
}

// Where a folder browse starts: home, the Videos folder, every mounted drive a
// person keeps films on, then the whole filesystem. Not the system's own mounts
// (a btrfs root carries a dozen subvolumes: /var/log, /srv, /root …).
QVariantList folderPlacesNow(const QString &home)
{
    QVariantList out;
    QStringList seen;
    const auto pretty = [&home](const QString &p) {
        return p == home ? QStringLiteral("~")
             : p.startsWith(home + QLatin1Char('/')) ? QStringLiteral("~") + p.mid(home.size()) : p;
    };
    const auto add = [&](const QString &label, const QString &path, const QString &sub) {
        const QString p = QDir::cleanPath(path);
        if (p.isEmpty() || seen.contains(p) || !QFileInfo(p).isDir())
            return;
        seen << p;
        out << QVariantMap{{QStringLiteral("label"), label}, {QStringLiteral("path"), p},
                           {QStringLiteral("sub"), sub}};
    };
    add(QStringLiteral("HOME"), home, pretty(home));
    const QString videos = QStandardPaths::writableLocation(QStandardPaths::MoviesLocation);
    if (!videos.isEmpty() && videos != home)
        add(QStringLiteral("VIDEOS"), videos, pretty(videos));

    static const QStringList kSystem = {
        QStringLiteral("/boot"), QStringLiteral("/efi"), QStringLiteral("/var"),
        QStringLiteral("/usr"), QStringLiteral("/opt"), QStringLiteral("/srv"),
        QStringLiteral("/root"), QStringLiteral("/tmp"), QStringLiteral("/proc"),
        QStringLiteral("/sys"), QStringLiteral("/dev"), QStringLiteral("/snap"),
        QStringLiteral("/nix"), QStringLiteral("/run"), QStringLiteral("/home"),
    };
    static const QList<QByteArray> kSkipFs = {
        "tmpfs", "devtmpfs", "overlay", "squashfs", "efivarfs", "ramfs", "proc",
        "sysfs", "cgroup2", "autofs", "fuse.portal", "fuse.gvfsd-fuse",
    };
    QList<QStorageInfo> vols = QStorageInfo::mountedVolumes();
    std::sort(vols.begin(), vols.end(), [](const QStorageInfo &a, const QStorageInfo &b) {
        return a.rootPath() < b.rootPath();
    });
    for (const QStorageInfo &v : std::as_const(vols)) {
        if (!v.isValid() || !v.isReady())
            continue;
        const QString root = v.rootPath();
        if (root == QLatin1String("/") || kSkipFs.contains(v.fileSystemType()))
            continue;
        const bool userMedia = root.startsWith(QLatin1String("/run/media/"))
            || root.startsWith(QLatin1String("/media/")) || root.startsWith(QLatin1String("/mnt/"));
        bool system = false;
        for (const QString &sys : kSystem)
            system = system || root == sys || root.startsWith(sys + QLatin1Char('/'));
        if (system && !userMedia)
            continue;
        if (!userMedia && v.bytesTotal() < (qint64(8) << 30))
            continue;
        QString name = v.name();
        if (name.isEmpty())
            name = QFileInfo(root).fileName();
        add(name.toUpper(), root,
            pretty(root) + QStringLiteral(" · ") + humanBytes(v.bytesAvailable())
                + QStringLiteral(" FREE OF ") + humanBytes(v.bytesTotal()));
    }
    add(QStringLiteral("COMPUTER"), QStringLiteral("/"), QStringLiteral("the whole filesystem"));
    return out;
}

// A folder's subfolders, sorted as a person reads them ("Season 2" before
// "Season 10"), without the hidden ones or a Windows drive's own furniture.
QVariantList subfoldersNow(const QString &path)
{
    static const QStringList kFurniture = {
        QStringLiteral("$RECYCLE.BIN"), QStringLiteral("System Volume Information"),
        QStringLiteral("lost+found"), QStringLiteral("$Recycle.Bin"),
    };
    QFileInfoList dirs = QDir(path).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable);
    QCollator col;
    col.setNumericMode(true);
    col.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(dirs.begin(), dirs.end(), [&col](const QFileInfo &a, const QFileInfo &b) {
        return col.compare(a.fileName(), b.fileName()) < 0;
    });
    QVariantList out;
    for (const QFileInfo &d : std::as_const(dirs)) {
        if (kFurniture.contains(d.fileName()))
            continue;
        out << QVariantMap{{QStringLiteral("label"), d.fileName()},
                           {QStringLiteral("path"), d.absoluteFilePath()},
                           {QStringLiteral("sub"), QString()}};
        if (out.size() >= 3000)
            break;
    }
    return out;
}

} // namespace

void AppController::browseFolder(const QString &path)
{
    QPointer<AppController> self(this);
    const QString home = QDir::homePath();
    (void)QtConcurrent::run([self, path, home]() {
        const QVariantList list = path.isEmpty() ? folderPlacesNow(home) : subfoldersNow(path);
        if (!self)
            return;
        QMetaObject::invokeMethod(self, [self, path, list]() {
            if (self)
                emit self->folderListed(path, list);
        }, Qt::QueuedConnection);
    });
}

QString AppController::parentFolder(const QString &path) const
{
    // "" = the places list (above / and above each drive a person browsed into)
    if (path.isEmpty() || path == QLatin1String("/"))
        return QString();
    return QDir::cleanPath(path + QStringLiteral("/.."));
}

QString AppController::prettyPath(const QString &path) const
{
    const QString home = QDir::homePath();
    if (path == home)
        return QStringLiteral("~");
    if (path.startsWith(home + QLatin1Char('/')))
        return QStringLiteral("~") + path.mid(home.size());
    return path;
}

void AppController::probeFolder(const QString &path)
{
    // How much video is in here, and does it read as TV? A bounded walk (five
    // folders deep, 40 000 entries, 4 s) — a whole drive answers "2000+" rather
    // than holding the count up for minutes.
    QPointer<AppController> self(this);
    (void)QtConcurrent::run([self, path]() {
        const QRegularExpression epRe(
            QStringLiteral(R"((?:^|[^a-z0-9])(?:s\d{1,2}[ ._-]?e\d{1,3}|\d{1,2}x\d{2,3})(?:[^a-z0-9]|$))"),
            QRegularExpression::CaseInsensitiveOption);
        const QRegularExpression seasonRe(
            QStringLiteral(R"(^(?:season|series|staffel|saison|temporada)[ ._-]*\d+$|^s\d{1,2}$|^specials$)"),
            QRegularExpression::CaseInsensitiveOption);
        int videos = 0, episodes = 0, seasons = 0, entries = 0;
        bool capped = false;
        QElapsedTimer clock;
        clock.start();
        QList<QPair<QString, int>> queue{{path, 0}};
        while (!queue.isEmpty() && !capped) {
            const auto [dir, depth] = queue.takeFirst();
            QDirIterator it(dir, QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot);
            while (it.hasNext()) {
                it.next();
                if (++entries > 40000 || clock.elapsed() > 4000) {
                    capped = true;
                    break;
                }
                const QFileInfo fi = it.fileInfo();
                if (fi.isDir()) {
                    if (seasonRe.match(fi.fileName()).hasMatch())
                        ++seasons;
                    if (depth < 5)
                        queue.append({fi.absoluteFilePath(), depth + 1});
                } else if (Library::isVideoSuffix(fi.suffix())
                           && !fi.completeBaseName().contains(QLatin1String("sample"), Qt::CaseInsensitive)) {
                    ++videos;
                    if (epRe.match(fi.fileName()).hasMatch())
                        ++episodes;
                }
            }
        }
        if (!self)
            return;
        QMetaObject::invokeMethod(self, [self, path, videos, episodes, seasons, capped]() {
            if (self)
                emit self->folderProbed(path, videos, episodes, seasons, capped);
        }, Qt::QueuedConnection);
    });
}

QVariantMap AppController::artKeys() const
{
    // The keys are the art scripts' (they do the fetching); read the two
    // constants rather than run Python from the GUI thread.
    QFile f(codecScript(QStringLiteral("codec_keys.py")));
    QString src;
    if (f.open(QIODevice::ReadOnly))
        src = QString::fromUtf8(f.readAll());
    const auto carried = [&src](const char *name) {
        const QRegularExpression re(QStringLiteral("^%1 = \"([^\"]+)\"").arg(QLatin1String(name)),
                                    QRegularExpression::MultilineOption);
        return re.match(src).hasMatch();
    };
    return {{QStringLiteral("codecTmdb"), carried("CODEC_TMDB_KEY")},
            {QStringLiteral("codecFanart"), carried("CODEC_FANART_KEY")}};
}

// ── device pairing (the hub's side) ─────────────────────────────────────────
// A device asks codec-serve to join (POST /pair/request); this hub's screen
// shows the first one waiting ("<NAME> WANTS TO JOIN · ⏎ ALLOW"); the answer
// goes back over loopback, which is the only place /pair/answer is taken.
// See scripts/codec_pairing.py.
static const char kHubSelf[] = "http://127.0.0.1:8200";

void AppController::pairPoll()
{
    if (m_library->remoteMode() || m_sharing == QLatin1String("off")
        || m_sharing == QLatin1String("unknown"))
        return;                        // a satellite, or a hub that isn't sharing, has no one to let in
    QNetworkRequest req(QUrl(QLatin1String(kHubSelf) + QStringLiteral("/pair/pending")));
    req.setTransferTimeout(1500);
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError)
            return;                    // no server here (yet)
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        const QJsonArray pend = o.value(QStringLiteral("pending")).toArray();
        const QVariantMap first = pend.isEmpty() ? QVariantMap()
                                                 : pend.first().toObject().toVariantMap();
        if (first.value(QStringLiteral("rid")) != m_pairRequest.value(QStringLiteral("rid"))) {
            m_pairRequest = first;
            emit pairRequestChanged();
        }
    });
}

void AppController::answerPair(bool allow)
{
    const QString rid = m_pairRequest.value(QStringLiteral("rid")).toString();
    const QString name = m_pairRequest.value(QStringLiteral("name")).toString();
    if (rid.isEmpty())
        return;
    m_pairRequest.clear();
    emit pairRequestChanged();
    QNetworkRequest req(QUrl(QLatin1String(kHubSelf) + QStringLiteral("/pair/answer")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(3000);
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("request"), rid}, {QStringLiteral("allow"), allow}}).toJson());
    connect(r, &QNetworkReply::finished, this, [this, r, allow, name] {
        r->deleteLater();
        const bool ok = QJsonDocument::fromJson(r->readAll()).object()
                            .value(QStringLiteral("ok")).toBool();
        emit toast(!ok ? QStringLiteral("THAT REQUEST HAD EXPIRED")
                   : allow ? QStringLiteral("%1 JOINED").arg(name.toUpper())
                           : QStringLiteral("%1 TURNED AWAY").arg(name.toUpper()));
        refreshPaired();
    });
}

void AppController::refreshPaired()
{
    QNetworkRequest req(QUrl(QLatin1String(kHubSelf) + QStringLiteral("/pair/devices")));
    req.setTransferTimeout(1500);
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError)
            return;
        m_pairedDevices = QJsonDocument::fromJson(r->readAll()).object()
                              .value(QStringLiteral("devices")).toArray().toVariantList();
        emit pairedDevicesChanged();
    });
}

void AppController::removePaired(const QString &id)
{
    QNetworkRequest req(QUrl(QLatin1String(kHubSelf) + QStringLiteral("/pair/remove")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(3000);
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("id"), id}}).toJson());
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        emit toast(QStringLiteral("DEVICE REMOVED · ITS KEY NO LONGER WORKS"));
        refreshPaired();
    });
}

bool AppController::lanOpen() const
{
    return m_settings.value(QStringLiteral("lanOpen"), false).toBool();
}

void AppController::toggleLanOpen()
{
    saveSetting(QStringLiteral("lanOpen"), !lanOpen());   // codec-serve re-reads it within 5 s
    emit lanOpenChanged();
}

// ── SHARE THIS LIBRARY ─────────────────────────────────────────────────────
// The hub's server (codec-serve) runs as a systemd user service, so the TV,
// a laptop and a phone keep their hub while codec itself is closed. Turning
// sharing on writes that service — unless one is already there that codec
// didn't write (the author's own codec-serve.service, which carries his --dir and
// is never overwritten) — enables and starts it; off stops and disables it.
static const char kServeUnit[] = "codec-serve.service";
static const char kServeMarker[] = "# written by codec: Settings > Library > Share this library";

void AppController::setSharing(const QString &s)
{
    if (s == m_sharing)
        return;
    m_sharing = s;
    emit sharingChanged();
}

void AppController::refreshSharing()
{
    auto *p = new QProcess(this);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
        p->deleteLater();
        setSharing(QStringLiteral("unsupported"));      // no systemctl here
    });
    connect(p, &QProcess::finished, this, [this, p](int, QProcess::ExitStatus) {
        const QString st = QString::fromUtf8(p->readAllStandardOutput()).trimmed();
        p->deleteLater();
        setSharing(st == QLatin1String("active") || st == QLatin1String("activating")
                       ? QStringLiteral("on") : QStringLiteral("off"));
    });
    p->start(QStringLiteral("systemctl"),
             {QStringLiteral("--user"), QStringLiteral("is-active"), QLatin1String(kServeUnit)});
}

void AppController::toggleSharing()
{
    if (m_sharing == QLatin1String("busy") || m_sharing == QLatin1String("unsupported"))
        return;
    const bool turnOn = m_sharing != QLatin1String("on");
    QStringList steps;
    if (turnOn) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation)
                            + QStringLiteral("/systemd/user");
        const QString unit = dir + QLatin1Char('/') + QLatin1String(kServeUnit);
        QFile cur(unit);
        const bool ours = !cur.exists()
            || (cur.open(QIODevice::ReadOnly) && cur.readAll().contains(kServeMarker));
        cur.close();
        if (ours) {
            QDir().mkpath(dir);
            QString py = QStandardPaths::findExecutable(QStringLiteral("python3"));
            if (py.isEmpty())
                py = QStringLiteral("/usr/bin/python3");
            QSaveFile f(unit);
            if (f.open(QIODevice::WriteOnly)) {
                f.write(QStringLiteral(
                    "%1\n"
                    "[Unit]\n"
                    "Description=codec - shares this library with the house's other screens\n"
                    "After=network.target\n"
                    "StartLimitIntervalSec=300\n"
                    "StartLimitBurst=20\n\n"
                    "[Service]\n"
                    "ExecStart=%2 %3 --port 8200 --bind 0.0.0.0\n"
                    "Restart=always\n"
                    "RestartSec=5\n\n"
                    "[Install]\n"
                    "WantedBy=default.target\n")
                    .arg(QLatin1String(kServeMarker), py,
                         codecScript(QStringLiteral("codec_serve.py"))).toUtf8());
                f.commit();
            }
            steps << QStringLiteral("daemon-reload");
        }
        steps << QStringLiteral("enable --now");
    } else {
        steps << QStringLiteral("disable --now");
    }
    setSharing(QStringLiteral("busy"));
    // run the steps one after another, then read the real state back
    auto run = std::make_shared<std::function<void(int)>>();
    *run = [this, steps, run, turnOn](int i) {
        if (i >= steps.size()) {
            refreshSharing();
            emit toast(turnOn ? QStringLiteral("SHARING THIS LIBRARY")
                              : QStringLiteral("NOT SHARING · THE TV, LAPTOPS AND PHONES LOSE THIS HUB"));
            return;
        }
        auto *p = new QProcess(this);
        connect(p, &QProcess::finished, this, [p, run, i](int, QProcess::ExitStatus) {
            p->deleteLater();
            (*run)(i + 1);
        });
        connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
            p->deleteLater();
            setSharing(QStringLiteral("unsupported"));
        });
        QStringList args{QStringLiteral("--user")};
        args << steps[i].split(QLatin1Char(' ')) << QLatin1String(kServeUnit);
        if (steps[i] == QLatin1String("daemon-reload"))
            args = {QStringLiteral("--user"), QStringLiteral("daemon-reload")};
        p->start(QStringLiteral("systemctl"), args);
    };
    (*run)(0);
}

// ── joining a hub (the satellite's side of device pairing) ──────────────────
void AppController::loadHubKey()
{
    // hub-key.json: the key a hub gave this machine when its owner pressed
    // ALLOW (codec_hubs.py --join keeps it, owner-only)
    QFile f(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
            + QStringLiteral("/hub-key.json"));
    QByteArray key;
    if (f.open(QIODevice::ReadOnly))
        key = QJsonDocument::fromJson(f.readAll()).object()
                  .value(QStringLiteral("key")).toString().toUtf8();
    QSet<QString> hosts;
    for (const QString &u : {m_cfgSyncUrl, m_cfgTailnet}) {
        const QString h = QUrl(u).host().toLower();
        if (!h.isEmpty())
            hosts.insert(h);
    }
    HubNam::setAuth(hosts, key);
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setHubAuth(QStringList(hosts.begin(), hosts.end()), QString::fromUtf8(key));
}

void AppController::findHubs()
{
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p](int, QProcess::ExitStatus) {
        const QVariantList hubs = QJsonDocument::fromJson(p->readAllStandardOutput())
                                      .array().toVariantList();
        p->deleteLater();
        emit hubsFound(hubs);
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
        p->deleteLater();
        emit hubsFound({});
    });
    p->start(QStringLiteral("python3"),
             {codecScript(QStringLiteral("codec_hubs.py")), QStringLiteral("--find"),
              QStringLiteral("3")});
}

void AppController::joinHub(const QString &url)
{
    const QString base = url.trimmed().endsWith(QLatin1Char('/')) ? url.trimmed().chopped(1)
                                                                   : url.trimmed();
    // a laptop if this machine has a battery, else a desktop — what the hub's
    // owner reads in "<NAME> WANTS TO JOIN"
    const bool battery = !QDir(QStringLiteral("/sys/class/power_supply"))
                              .entryList({QStringLiteral("BAT*")}, QDir::AllEntries).isEmpty();
    auto *p = new QProcess(this);
    auto buf = std::make_shared<QByteArray>();
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p, buf, base] {
        buf->append(p->readAllStandardOutput());
        int nl;
        while ((nl = buf->indexOf('\n')) >= 0) {
            const QJsonObject o = QJsonDocument::fromJson(buf->left(nl)).object();
            buf->remove(0, nl + 1);
            const QString st = o.value(QStringLiteral("state")).toString();
            const QString hub = o.value(QStringLiteral("hub")).toString();
            emit joinProgress(st, hub, o.value(QStringLiteral("why")).toString());
            if (st == QLatin1String("allowed"))
                becomeSatellite(base, hub);
        }
    });
    connect(p, &QProcess::finished, p, &QObject::deleteLater);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
        p->deleteLater();
        emit joinProgress(QStringLiteral("error"), QString(), QStringLiteral("python3 is missing"));
    });
    p->start(QStringLiteral("python3"),
             {codecScript(QStringLiteral("codec_hubs.py")), QStringLiteral("--join"), base,
              QStringLiteral("--name"), QSysInfo::machineHostName(),
              QStringLiteral("--kind"), battery ? QStringLiteral("laptop") : QStringLiteral("desktop")});
}

void AppController::becomeSatellite(const QString &base, const QString &hub)
{
    // This machine now browses that hub: its address (syncUrl), where its
    // library list lands (remoteLibrary), and the first-run page settled.
    const QString path = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec/config.json");
    {
        QDir().mkpath(QFileInfo(path).absolutePath());
        ConfigFlock lock(path);
        QFile f(path);
        QJsonObject root;
        if (f.open(QIODevice::ReadOnly)) {
            root = QJsonDocument::fromJson(f.readAll()).object();
            f.close();
        }
        root.insert(QStringLiteral("syncUrl"), base);
        root.insert(QStringLiteral("remoteLibrary"),
                    QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                        + QStringLiteral("/remote-library.json"));
        QJsonObject s = root.value(QStringLiteral("settings")).toObject();
        s.insert(QStringLiteral("mediaPathsDone"), true);
        root.insert(QStringLiteral("settings"), s);
        writeConfigAtomic(root);
    }
    m_settings.insert(QStringLiteral("mediaPathsDone"), true);
    loadHubConfig();                       // the key now rides every hub request
    emit joinProgress(QStringLiteral("pulling"), hub, QString());
    // bring the hub's library list and art over, then start again as a satellite
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p, hub](int, QProcess::ExitStatus) {
        p->deleteLater();
        emit joinProgress(QStringLiteral("restarting"), hub, QString());
        QTimer::singleShot(900, this, [this] { restartSelf(); });
    });
    p->start(QStringLiteral("python3"), {codecScript(QStringLiteral("codec_pull_library.py"))});
}

void AppController::restartSelf()
{
    // codec runs as one instance: start the new one only once this one has
    // gone, on the same screen (no display chooser)
    QStringList args;
    if (!m_display.isEmpty())
        args << QStringLiteral("--display") << m_display;
    QStringList sh{QStringLiteral("-c"), QStringLiteral("sleep 1.5; exec \"$0\" \"$@\""),
                   QCoreApplication::applicationFilePath()};
    sh << args;
    QProcess::startDetached(QStringLiteral("/bin/sh"), sh);
    quit();
}

bool AppController::needsMediaPaths() const
{
    // A satellite browses its hub's library; anyone with paths already set (or
    // who finished / skipped the page once) is never asked again.
    return !m_library->remoteMode() && mediaRoots().isEmpty()
        && !m_settings.value(QStringLiteral("mediaPathsDone")).toBool();
}

void AppController::finishMediaPaths()
{
    saveSetting(QStringLiteral("mediaPathsDone"), true);
    m_library->rescan();
    setStage(QStringLiteral("home"));
}

void AppController::checkHub()
{
    // "Recheck hub" now actually SYNCS (it used to only report status —
    // pressing it changed nothing, which read as broken): pull the manifest
    // + art, and the status below reports what we have afterwards.
    pullLibrary();
    emit deviceRoleChanged(); // the manifest mode may have changed under us
    probeHubNow();            // a fresh link answer for the strip + Settings
    // Network sources were invisible plumbing — surface them: where the hub
    // is, whether it answers, and how fresh the streamed library manifest is.
    QFile cf(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
             + QStringLiteral("/codec/config.json"));
    QString manifest;
    if (cf.open(QIODevice::ReadOnly)) {
        const QJsonObject cfg = QJsonDocument::fromJson(cf.readAll()).object();
        manifest = cfg.value(QStringLiteral("remoteLibrary")).toString();
    }
    // Ask the road we'd actually use (the tailnet when the LAN is out of reach,
    // the public door with our token when no private road answers) — the
    // status used to HEAD syncUrl alone, so a working tailnet read OFFLINE.
    const bool isHub = m_cfgSyncUrl.isEmpty();
    const QString url = (publicRoad() && !m_hubToken.isEmpty()) ? publicBase() : hubBase();
    const QString askUrl = (publicRoad() && !m_hubToken.isEmpty())
        ? url + QStringLiteral("/r/") + m_hubToken + QStringLiteral("/lib")
        : url + QStringLiteral("/");

    QString libInfo;
    if (!manifest.isEmpty()) {
        const QString mp = manifest.startsWith(QLatin1Char('~'))
            ? QDir::home().filePath(manifest.mid(2)) : manifest;
        QFile mf(mp);
        if (mf.open(QIODevice::ReadOnly)) {
            const int entries = QJsonDocument::fromJson(mf.readAll())
                .object().value(QStringLiteral("entries")).toArray().size();
            const qint64 hours = QFileInfo(mp).lastModified()
                .secsTo(QDateTime::currentDateTime()) / 3600;
            libInfo = QStringLiteral(" · %1 titles · manifest %2")
                          .arg(entries)
                          .arg(hours < 1 ? QStringLiteral("fresh")
                               : hours < 48 ? QStringLiteral("%1h old").arg(hours)
                                            : QStringLiteral("%1d old").arg(hours / 24));
        } else {
            libInfo = QStringLiteral(" · manifest MISSING");
        }
    }

    m_hubStatus = QStringLiteral("%1 · checking…").arg(url);
    emit hubStatusChanged();

    static HubNam nam;   // carries a satellite's hub key, like m_nam
    QNetworkRequest req{QUrl(askUrl)};
    req.setTransferTimeout(4000);
    QElapsedTimer *timer = new QElapsedTimer;
    timer->start();
    QNetworkReply *reply = nam.head(req);
    connect(reply, &QNetworkReply::finished, this,
            [this, reply, timer, url, isHub, libInfo] {
        const bool ok = reply->error() == QNetworkReply::NoError;
        const QString who = isHub
            ? QStringLiteral("THIS MACHINE IS THE HUB · codec-serve %1").arg(url)
            : QStringLiteral("HUB %1 · %2").arg(url, m_hubLink.toUpper());
        m_hubStatus = QStringLiteral("%1 · %2%3")
            .arg(who,
                 ok ? QStringLiteral("ONLINE %1ms").arg(timer->elapsed())
                    : QStringLiteral("OFFLINE (%1)").arg(reply->errorString()),
                 libInfo);
        emit hubStatusChanged();
        delete timer;
        reply->deleteLater();
    });
}

QString AppController::hubUrl() const
{
    return hubBase();   // one answer, link-aware (this was a second config read)
}

static QNetworkAccessManager *hubNam()
{
    static HubNam nam;   // carries a satellite's hub key, like m_nam
    return &nam;
}

void AppController::postHubItems(const QVariantList &items, const QString &toastText)
{
    QNetworkRequest req(QUrl(hubUrl() + QStringLiteral("/_queue")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(5000);
    QNetworkReply *reply = hubNam()->post(
        req, QJsonDocument(QJsonObject{
                 {QStringLiteral("items"), QJsonArray::fromVariantList(items)}})
                 .toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [this, reply, toastText] {
        emit toast(reply->error() == QNetworkReply::NoError
                       ? toastText
                       : QStringLiteral("HUB UNREACHABLE — NOT SENT"));
        reply->deleteLater();
    });
}

void AppController::sendToHubQueue(const QVariantMap &item)
{
    if (item.value(QStringLiteral("uri")).toString().isEmpty())
        return;
    postHubItems({item}, QStringLiteral("→ HUB QUEUE · %1")
                             .arg(item.value(QStringLiteral("title")).toString()));
}

void AppController::sendQueueToHub()
{
    QVariantList items;
    for (int i = 0; i < m_queue->count(); ++i)
        items.append(m_queue->itemAt(i));
    if (items.isEmpty()) {
        emit toast(QStringLiteral("QUEUE EMPTY"));
        return;
    }
    m_queue->clear();
    postHubItems(items, QStringLiteral("→ HUB QUEUE · %1 ITEMS").arg(items.size()));
}

void AppController::pullHubQueue()
{
    QNetworkRequest req(QUrl(hubUrl() + QStringLiteral("/_queue?take=1")));
    req.setTransferTimeout(5000);
    QNetworkReply *reply = hubNam()->get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        if (reply->error() == QNetworkReply::NoError) {
            const QJsonArray arr = QJsonDocument::fromJson(reply->readAll())
                                       .object().value(QStringLiteral("items")).toArray();
            for (const QJsonValue &v : arr)
                m_queue->add(localizedQueueItem(v.toObject().toVariantMap()));
            if (!arr.isEmpty())
                emit toast(QStringLiteral("%1 FROM HUB QUEUE").arg(arr.size()));
        }
        reply->deleteLater();
    });
}

void AppController::setAudioDevice(const QString &name)
{
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setAudioDevice(name);
    saveSetting(QStringLiteral("audioDevice"), name);
    emit toast(QStringLiteral("AUDIO → %1").arg(name));
}

void AppController::openSection(const QString &section)
{
    if (section == QLatin1String("paths")) {   // CHOOSE MEDIA PATHS (a shot / a revisit)
        setStage(QStringLiteral("paths"));
        return;
    }
    if (section == QLatin1String("settings")
        || section.startsWith(QLatin1String("settings:"))) {
        m_settingsJump = section.mid(9);
        setStage(QStringLiteral("settings"));
        emit settingsJumpRequested();   // an already-open Settings follows too
        return;
    }
    if (section == QLatin1String("youtube")) {
        m_browseStage = QStringLiteral("youtube");
        setStage(QStringLiteral("youtube"));
        return;
    }
    if (section == QLatin1String("stats")) {
        setStage(QStringLiteral("stats"));
        return;
    }
    m_library->setSection(section);
    m_browseStage = QStringLiteral("library");
    setStage(QStringLiteral("library"));
}

void AppController::goHome()
{
    setStage(QStringLiteral("home"));
}

void AppController::toPlayer()
{
    // While casting, "the player" is the TV — p opens the remote instead. Also
    // in party-from-cast, where the TV is a party follower we drive.
    if (m_partyViaCast || (m_cast->active() && !m_cast->currentUri().isEmpty())) {
        setRemoteOpen(true);
        return;
    }
    if (!m_engine->path().isEmpty() && !m_engine->idle())
        setStage(QStringLiteral("player"));
}

void AppController::castSeekRel(double delta)
{
    // Party-from-cast: the TV follows the hub clock, so a seek must move the
    // ROOM (every screen) — not just this receiver, which would then be dragged
    // back by the clock it is chasing.
    if (m_partyViaCast && partyHubMode()) {
        // #218: coalesce a burst of skips (held arrow key = key-repeat) — accumulate
        // deltas onto the pending target (or the live position if none pending) and
        // debounce to one room-clock update + one DV re-warm. Absolute film-time.
        const double base = (m_pendingSeekPos >= 0) ? m_pendingSeekPos
                                                    : m_cast->castPosition();
        castSeekDebounced(base + delta);
        return;
    }
    Logger::log(QStringLiteral("seek"),
                QStringLiteral("castSeekRel %1 from %2")
                    .arg(delta).arg(m_cast->castPosition()));
    double pos = m_cast->castPosition() + delta;
    if (m_cast->castDuration() > 0)
        pos = qMin(pos, m_cast->castDuration() - kCastEofRunwayS);
    m_cast->seek(qMax(0.0, pos));
}

void AppController::castTogglePause()
{
    // Same reason as castSeekRel: in party-from-cast the pause belongs to the
    // whole room. Elsewhere it is an ordinary solo-cast toggle.
    if (m_partyViaCast && partyHubMode()) {
        // #218: author the room clock AND move the host's own DV lane (it no longer
        // chases the clock the way a reloaded follower did). Key off the room's known
        // pause state (m_partyPaused), not the possibly-lagged live cast state.
        if (m_partyPaused) { partyCmd(QStringLiteral("play"));  m_cast->resume(); }
        else               { partyCmd(QStringLiteral("pause")); m_cast->pause();  }
        return;
    }
    m_cast->togglePause();
}

void AppController::castSeekTo(double pos)
{
    // #218: the absolute seek bar (CastRemote.qml) routes here so a scrub reaches the
    // ROOM, not just this receiver. In a from-cast party: author the room clock AND
    // move the host's own DV lane. For a plain solo cast it's an ordinary seek.
    if (m_partyViaCast && partyHubMode()) {
        castSeekDebounced(pos);   // #218: coalesce a scrub-burst into one DV re-warm
        return;
    }
    // Batch2 #2: clamp the SOLO-cast seek the same way the party paths already do,
    // so a seek past EOF can't drive the receiver to IDLE (belt for worker #1).
    if (m_cast->castDuration() > 0)
        pos = qMin(pos, m_cast->castDuration() - kCastEofRunwayS);
    m_cast->seek(qMax(0.0, pos));
}

void AppController::castSeekDebounced(double pos)
{
    // #218: stash the FINAL target and (re)start the quiet-window timer; a burst of
    // seeks collapses to a single room-clock update + one DV re-warm when it fires
    // (see the m_castSeekDebounce lambda). Clamp like the immediate seek paths do.
    if (m_cast->castDuration() > 0)
        pos = qMin(pos, m_cast->castDuration() - kCastEofRunwayS);
    m_pendingSeekPos = qMax(0.0, pos);
    m_castSeekDebounce.start();
}

// One-line description of a track map for the cycle toasts ("eng · Commentary").
static QString trackLabel(const QVariantMap &t)
{
    const QString lang = t.value(QStringLiteral("lang")).toString();
    const QString title = t.value(QStringLiteral("title")).toString();
    QString s = lang.isEmpty()
        ? QStringLiteral("#%1").arg(t.value(QStringLiteral("i")).toInt() + 1)
        : lang;
    if (!title.isEmpty())
        s += QStringLiteral(" · ") + title;
    return s;
}

void AppController::castCycleSub()
{
    const QVariantList subs = m_cast->castSubTracks();
    if (subs.isEmpty()) {
        if (m_cast->castIsYoutube())
            emit toast(m_cast->castSubsFinal()
                           ? QStringLiteral("CC ▸ THIS VIDEO HAS NO CAPTIONS")
                           : QStringLiteral("CC ▸ FETCHING CAPTION LIST… TRY AGAIN SOON"));
        else
            findSubtitles();    // none in the file: the subs button fetches
        return;
    }
    // off -> track 0 -> track 1 -> ... -> off (same shape as mpv's cycle).
    const int next = m_cast->castSubIndex() + 1 >= subs.size()
        ? -1 : m_cast->castSubIndex() + 1;
    m_cast->setSubTrack(next);
    if (next < 0) {
        emit toast(QStringLiteral("SUBS ▸ off"));
        return;
    }
    const QVariantMap t = subs[next].toMap();
    if (m_cast->castIsYoutube())
        emit toast(QStringLiteral("CC ▸ %1 (stream restarts)").arg(trackLabel(t)));
    else
        // every track hand-renders on the receiver's overlay now — text at
        // once, a bitmap as its OCR text (a party's tracks carry no `text`
        // flag at all, and read "burned in" here for a year)
        emit toast(QStringLiteral("SUBS ▸ %1").arg(trackLabel(t)));
}

void AppController::castToggleSub()
{
    // Physical-remote Subtitle key: a plain English on/off, NOT a cycle through
    // every track (a film can carry 30+, so cycling never reaches "off"). Off ->
    // the primary English TEXT sub (falls back to an English bitmap track, then
    // track 0); on -> off. Cycling other languages lives on a number key
    // (castCycleSub), kept out of the everyday path.
    if (m_cast->castSubIndex() >= 0) {
        m_cast->setSubTrack(-1);
        emit toast(QStringLiteral("SUBS ▸ off"));
        return;
    }
    const QVariantList subs = m_cast->castSubTracks();
    if (subs.isEmpty()) {
        if (m_cast->castIsYoutube())
            emit toast(m_cast->castSubsFinal()
                           ? QStringLiteral("CC ▸ THIS VIDEO HAS NO CAPTIONS")
                           : QStringLiteral("CC ▸ FETCHING CAPTION LIST… TRY AGAIN SOON"));
        else
            findSubtitles();    // none in the file: the subs button fetches
        return;
    }
    int pick = -1, engAny = -1;
    for (int i = 0; i < subs.size(); ++i) {
        const QVariantMap t = subs[i].toMap();
        if (t.value(QStringLiteral("lang")).toString().toLower()
                .startsWith(QLatin1String("en"))) {
            if (engAny < 0)
                engAny = i;
            if (t.value(QStringLiteral("text")).toBool()) {
                pick = i;
                break;
            }
        }
    }
    if (pick < 0)
        pick = (engAny >= 0 ? engAny : 0);
    m_cast->setSubTrack(pick);
    emit toast(QStringLiteral("SUBS ▸ %1").arg(trackLabel(subs[pick].toMap())));
}

void AppController::castCycleAudio()
{
    if (m_cast->castIsYoutube()) {
        emit toast(QStringLiteral("AUDIO ▸ YOUTUBE PICKS ITS OWN"));
        return;
    }
    const QVariantList tracks = m_cast->castAudioTracks();
    if (tracks.size() < 2) {
        emit toast(QStringLiteral("AUDIO ▸ ONLY ONE TRACK"));
        return;
    }
    const int next = (m_cast->castAudioIndex() + 1) % tracks.size();
    m_cast->setAudioTrack(next);
    emit toast(QStringLiteral("AUDIO ▸ %1 (stream restarts)")
                   .arg(trackLabel(tracks[next].toMap())));
}

void AppController::castCycleScreenMode()
{
    if (m_cast->castIsYoutube()) {
        emit toast(QStringLiteral("SCREEN ▸ NATIVE YOUTUBE FILLS ITSELF"));
        return;
    }
    // A strict fit↔zoom toggle. "stretch" was dropped (#235): the worker and the
    // receiver only ever understood fit|zoom, so a third "stretch" press was a
    // silent no-op that just desynced the remote label to STRETCH while the
    // picture didn't change.
    const QString cur = m_cast->castScreenMode();
    const QString next = cur == QLatin1String("zoom") ? QStringLiteral("fit")
                                                      : QStringLiteral("zoom");
    m_cast->setScreenMode(next);
    emit toast(QStringLiteral("SCREEN ▸ %1").arg(next.toUpper()));
}

void AppController::castStepRate(int dir)
{
    static const double presets[] = {0.75, 1.0, 1.25, 1.5, 2.0};
    constexpr int n = 5;
    double next = 1.0;
    if (dir != 0) {
        int cur = 1; // nearest preset to the live rate
        for (int i = 0; i < n; ++i)
            if (qAbs(presets[i] - m_cast->castRate())
                < qAbs(presets[cur] - m_cast->castRate()))
                cur = i;
        next = presets[qBound(0, cur + dir, n - 1)];
    }
    if (m_partyViaCast && partyHubMode())   // #218: author the room's rate too
        partyCmd(QStringLiteral("rate"), next);
    m_cast->setRate(next);   // moves the host's own DV lane
    emit toast(QStringLiteral("SPEED ▸ %1×").arg(next));
}

void AppController::castNext()
{
    const QString uri = m_cast->currentUri();
    if (uri.isEmpty())
        return;
    castCreditsCancel(/*flash=*/false);
    // Skipping counts like stopping early: the 90% rule decides watched
    // (unless the credits already banked it).
    if (uri != m_castCreditsUri && m_cast->castDuration() > 0
        && m_cast->castPosition() / m_cast->castDuration() >= kWatchedPct) {
        m_store->markCompleted(uri);
        m_library->refreshResume();
    }
    // No stopCast() here: quitting the receiver flashes the TV's home screen
    // between items. advanceAfter loads the next item straight onto the live
    // receiver (a media swap, like natural end-of-film auto-advance); if there's
    // nothing next, the current item simply keeps playing instead of dropping out.
    advanceAfter(uri);
}

QString AppController::deviceRole() const
{
    return m_library->remoteMode() ? QStringLiteral("SATELLITE")
                                   : QStringLiteral("HUB");
}

QString AppController::hubBase() const
{
    if (m_cfgSyncUrl.isEmpty())
        return QStringLiteral("http://127.0.0.1:8200");   // this machine is the hub
    // Away from the LAN but on the tailnet: every hub call rides the tailnet.
    // (It used to be play() alone; watch-state sync, the manifest, the cast
    // queue, subs and chapters all kept asking the dead LAN address.)
    if (m_hubLink == QLatin1String("tailnet") && !m_cfgTailnet.isEmpty())
        return m_cfgTailnet;
    return m_cfgSyncUrl;
}

void AppController::loadHubConfig()
{
    QFile cf(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
             + QStringLiteral("/codec/config.json"));
    QJsonObject root;
    if (cf.open(QIODevice::ReadOnly))
        root = QJsonDocument::fromJson(cf.readAll()).object();
    m_cfgSyncUrl = root.value(QStringLiteral("syncUrl")).toString().trimmed();
    m_cfgTailnet = root.value(QStringLiteral("hubTailnet")).toString().trimmed();
    m_cfgFunnel  = root.value(QStringLiteral("hubFunnel")).toString().trimmed();
    // the hub's fast road: a satellite names it as hubDirect; the hub itself
    // carries it as party.directBase
    m_cfgDirect  = root.value(QStringLiteral("hubDirect")).toString().trimmed();
    if (m_cfgDirect.isEmpty())
        m_cfgDirect = root.value(QStringLiteral("party")).toObject()
                          .value(QStringLiteral("directBase")).toString().trimmed();
    while (m_cfgSyncUrl.endsWith(QLatin1Char('/'))) m_cfgSyncUrl.chop(1);
    while (m_cfgTailnet.endsWith(QLatin1Char('/'))) m_cfgTailnet.chop(1);
    while (m_cfgFunnel.endsWith(QLatin1Char('/'))) m_cfgFunnel.chop(1);
    while (m_cfgDirect.endsWith(QLatin1Char('/'))) m_cfgDirect.chop(1);
    loadHubToken();
    loadHubKey();
    // No hubTailnet but a Funnel name: the hub's MagicDNS name resolves on the
    // tailnet too, and :8200 answers there — derive the private road from the
    // public one rather than leaving the satellite with no fallback at all.
    if (m_cfgTailnet.isEmpty() && !m_cfgFunnel.isEmpty()) {
        const QString host = QUrl(m_cfgFunnel).host();
        if (!host.isEmpty())
            m_cfgTailnet = QStringLiteral("http://") + host + QStringLiteral(":8200");
    }
}

static bool probeTcp(const QString &url, int ms)
{
    const QUrl u(url);
    if (u.host().isEmpty())
        return false;
    QTcpSocket s;
    s.connectToHost(u.host(), quint16(u.port(8200)));
    return s.waitForConnected(ms);
}

void AppController::probeHubLink(bool sync)
{
    if (m_cfgSyncUrl.isEmpty()) {         // the hub itself: always "home"
        applyHubLink(true, true);
        return;
    }
    const QString lan = m_cfgSyncUrl, tnet = m_cfgTailnet;
    // The tailnet gets a longer wait — the higher-latency road. A blackhole LAN
    // burns the full connect with no RST, so every probe but a first-play gate
    // runs OFF the GUI thread (it used to freeze input once per 8 s).
    if (sync) {
        const bool l = probeTcp(lan, 600);
        const bool t = !tnet.isEmpty() && probeTcp(tnet, 1200);
        if (l || t) {
            applyHubLink(l, t);
        } else {
            // no private road: the public door is an http(s) question, asked
            // asynchronously — until it answers the link reads as it was
            probePublicRoad();
        }
        return;
    }
    if (m_hubProbing)
        return;
    m_hubProbing = true;
    // A guarded pointer: the pool thread can still be inside a blackhole
    // connect when the app quits (the controller lives on main()'s stack).
    QPointer<AppController> self(this);
    (void)QtConcurrent::run([self, lan, tnet]() {
        const bool l = probeTcp(lan, 600);
        const bool t = !tnet.isEmpty() && probeTcp(tnet, 1200);
        if (!self)
            return;
        QMetaObject::invokeMethod(self, [self, l, t]() {
            if (!self)
                return;
            if (l || t) {
                self->m_hubProbing = false;
                self->applyHubLink(l, t);
            } else {
                // the flags keep their last answer until the public door
                // has spoken (a play in that window reads the old verdict,
                // not a premature "nothing answers")
                self->probePublicRoad();   // clears m_hubProbing when it lands
            }
        }, Qt::QueuedConnection);
    });
}

// No private road: does the hub's public door answer the browse token this
// machine holds? The fast road first (the house's own edge — the whole upload),
// then the Funnel. A HEAD on the token surface's listing: 200 = the token is
// live and the door is open; anything else = that road is closed.
void AppController::probePublicRoad()
{
    if (m_hubToken.isEmpty() || (m_cfgDirect.isEmpty() && m_cfgFunnel.isEmpty())) {
        m_hubProbing = false;
        applyHubLink(false, false, 0);
        return;
    }
    m_hubProbing = true;
    auto ask = [this](const QString &base, std::function<void(bool)> done) {
        QNetworkRequest req(QUrl(base + QStringLiteral("/r/") + m_hubToken + QStringLiteral("/lib")));
        req.setTransferTimeout(4000);
        QNetworkReply *r = m_nam->head(req);
        connect(r, &QNetworkReply::finished, this, [r, done] {
            const int code = r->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            done(r->error() == QNetworkReply::NoError && code == 200);
            r->deleteLater();
        });
    };
    const QString direct = m_cfgDirect, funnel = m_cfgFunnel;
    auto finish = [this](int pub) {
        m_hubProbing = false;
        applyHubLink(false, false, pub);
    };
    if (!direct.isEmpty()) {
        ask(direct, [this, ask, funnel, finish](bool ok) {
            if (ok) { finish(1); return; }
            if (funnel.isEmpty()) { finish(0); return; }
            ask(funnel, [finish](bool ok2) { finish(ok2 ? 2 : 0); });
        });
    } else {
        ask(funnel, [finish](bool ok2) { finish(ok2 ? 2 : 0); });
    }
}

void AppController::applyHubLink(bool lan, bool tnet, int pub)
{
    m_hubLanOk = lan;
    m_hubTnetOk = tnet;
    m_publicDirectOk = (pub == 1);
    m_hubProbeAt = QDateTime::currentMSecsSinceEpoch();
    const QString link = m_cfgSyncUrl.isEmpty() ? QStringLiteral("hub")
                       : lan ? QStringLiteral("lan")
                       : tnet ? QStringLiteral("tailnet")
                       : pub == 1 ? QStringLiteral("fastroad")
                       : pub == 2 ? QStringLiteral("funnel") : QStringLiteral("away");
    // A private road is the moment to keep the token alive for the days without one.
    if (lan || tnet)
        mintHubToken();
    if (link == m_hubLink)
        return;
    const QString was = m_hubLink;
    m_hubLink = link;
    emit hubLinkChanged();
    Logger::log(QStringLiteral("hub"), QStringLiteral("link %1 -> %2").arg(was, link));
    // Say it when it matters: the first answer when it isn't the LAN, and every
    // change after. Home on launch is the quiet normal.
    if (link == QLatin1String("hub") || (was.isEmpty() && link == QLatin1String("lan")))
        return;
    emit toast(link == QLatin1String("lan")      ? QStringLiteral("HUB · BACK ON THE LAN")
             : link == QLatin1String("tailnet")  ? QStringLiteral("HUB · OVER THE TAILNET")
             : link == QLatin1String("fastroad") ? QStringLiteral("HUB · OVER THE FAST ROAD")
             : link == QLatin1String("funnel")   ? QStringLiteral("HUB · OVER THE FUNNEL (SLOW)")
             : QStringLiteral("HUB AWAY · LIBRARY FROM THE CACHE"));
}

static QString hubTokenPath()
{
    return QDir::homePath() + QStringLiteral("/.cache/codec/hub-token.json");
}

void AppController::loadHubToken()
{
    m_hubToken.clear();
    m_hubTokenExp = 0;
    QFile f(hubTokenPath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    const double exp = o.value(QStringLiteral("expires")).toDouble();
    if (exp > QDateTime::currentSecsSinceEpoch() + 60) {
        m_hubToken = o.value(QStringLiteral("token")).toString();
        m_hubTokenExp = exp;
    }
    // the roads the hub told us about, when config doesn't name them
    if (m_cfgDirect.isEmpty())
        m_cfgDirect = o.value(QStringLiteral("direct")).toString();
    if (m_cfgFunnel.isEmpty())
        m_cfgFunnel = o.value(QStringLiteral("funnel")).toString();
}

void AppController::mintHubToken()
{
    // Satellites only, at most hourly. `home: true` asks for the sliding
    // 60-days-idle token (the phone-app link's kind); `new: false` keeps the
    // live one so nobody's bookmark rotates. The hub never shortens it.
    if (m_cfgSyncUrl.isEmpty())
        return;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_hubTokenMintAt < 3600 * 1000)
        return;
    m_hubTokenMintAt = now;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/browse/start")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    req.setTransferTimeout(8000);
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("home"), true}, {QStringLiteral("new"), false},
        {QStringLiteral("hours"), 24 * 60}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError)
            return;
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        const QString tok = o.value(QStringLiteral("token")).toString();
        if (tok.isEmpty())
            return;
        const int days = o.value(QStringLiteral("home_idle_days")).toInt();
        const int hours = o.value(QStringLiteral("hours")).toInt();
        // the hub's own expiry when it says it (a kept token never shortens)
        double exp = o.value(QStringLiteral("expires")).toDouble();
        if (exp <= double(QDateTime::currentSecsSinceEpoch()))
            exp = double(QDateTime::currentSecsSinceEpoch())
                + (days > 0 ? days * 86400.0 : hours > 0 ? hours * 3600.0 : 30 * 86400.0);
        m_hubToken = tok;
        m_hubTokenExp = exp;
        saveHubTokenFile();
        Logger::log(QStringLiteral("hub"), QStringLiteral("browse token kept (%1 d)").arg(days));
    });
    // Learn the fast road from the hub when config doesn't name it — and keep
    // it in the token file: it used to live only in memory, and the next
    // config re-read (Settings, a chip tap) forgot it, so a roaming satellite
    // quietly rode the Funnel relay instead of the house's own edge.
    if (m_cfgDirect.isEmpty()) {
        QNetworkRequest rq(QUrl(hubBase() + QStringLiteral("/roads")));
        rq.setTransferTimeout(5000);
        QNetworkReply *rr = m_nam->get(rq);
        connect(rr, &QNetworkReply::finished, this, [this, rr] {
            rr->deleteLater();
            if (rr->error() != QNetworkReply::NoError)
                return;
            const QJsonObject o = QJsonDocument::fromJson(rr->readAll()).object();
            const QString d = o.value(QStringLiteral("direct")).toString();
            if (!d.isEmpty())
                m_cfgDirect = d;
            if (m_cfgFunnel.isEmpty())
                m_cfgFunnel = o.value(QStringLiteral("funnel")).toString();
            if (!m_hubToken.isEmpty())
                saveHubTokenFile();
        });
    }
}

// The token file: the key, when it lapses, and the doors it opens — merged
// over what is there (the cast worker writes the same file), owner-only.
void AppController::saveHubTokenFile()
{
    if (m_hubToken.isEmpty())
        return;
    QJsonObject out;
    QFile in(hubTokenPath());
    if (in.open(QIODevice::ReadOnly))
        out = QJsonDocument::fromJson(in.readAll()).object();
    // the same key never gets shorter here (the hub keeps a home token on a
    // 60-day slide; the worker's 12 h ask must not overwrite that)
    double exp = m_hubTokenExp;
    if (out.value(QStringLiteral("token")).toString() == m_hubToken)
        exp = qMax(exp, out.value(QStringLiteral("expires")).toDouble());
    out.insert(QStringLiteral("token"), m_hubToken);
    out.insert(QStringLiteral("expires"), exp);
    if (!m_cfgDirect.isEmpty()) out.insert(QStringLiteral("direct"), m_cfgDirect);
    if (!m_cfgFunnel.isEmpty()) out.insert(QStringLiteral("funnel"), m_cfgFunnel);
    QDir().mkpath(QFileInfo(hubTokenPath()).absolutePath());
    QSaveFile f(hubTokenPath());
    if (f.open(QIODevice::WriteOnly)) {
        f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        f.write(QJsonDocument(out).toJson(QJsonDocument::Compact));
        f.commit();
    }
}

QString AppController::publicBase() const
{
    if (m_publicDirectOk && !m_cfgDirect.isEmpty())
        return m_cfgDirect;
    return m_cfgFunnel;
}

QString AppController::publicUrlFor(const QString &hubUrl, const QString &leaf,
                                    const QString &extra) const
{
    // A hub title's url → the same title on the public door, by manifest INDEX
    // (the token surface never takes a path). "" when the title isn't in the
    // manifest or there is no token.
    if (m_hubToken.isEmpty() || !m_library)
        return QString();
    const int idx = m_library->manifestIndexOf(hubUrl);
    if (idx < 0)
        return QString();
    // k = the title's own path, hashed: the hub refuses the index when it no
    // longer names this title (a re-export since the satellite last synced
    // shifts every index after the new row — the wrong film would play,
    // silently, under this title's name)
    const QByteArray k = QCryptographicHash::hash(
        Library::manifestKey(hubUrl).toUtf8(), QCryptographicHash::Sha1).toHex().left(12);
    return publicBase() + QStringLiteral("/r/") + m_hubToken + QLatin1Char('/') + leaf
         + QStringLiteral("?i=") + QString::number(idx)
         + QStringLiteral("&k=") + QString::fromLatin1(k) + extra;
}

void AppController::probeHubNow()
{
    loadHubConfig();
    probeHubLink(false);
}

static bool privateHost(const QString &h)
{
    // RFC 1918 + loopback + Tailscale's CGNAT range: an address that can only
    // be the hub's own road (a manifest from an older export can bake a LAN ip
    // that differs from syncUrl). Anything else — YouTube, a CDN — is public
    // and reachable as it is.
    if (h == QLatin1String("localhost") || h.startsWith(QLatin1String("127.")))
        return true;
    if (h.startsWith(QLatin1String("10.")) || h.startsWith(QLatin1String("192.168."))
        || h.startsWith(QLatin1String("100.")))
        return true;
    if (h.startsWith(QLatin1String("172."))) {
        const int second = h.section(QLatin1Char('.'), 1, 1).toInt();
        return second >= 16 && second <= 31;
    }
    return false;
}

QString AppController::reachableHub(const QString &uri) const
{
    // Only a satellite's hub http(s) URLs need this; local paths, YouTube and
    // any other public host are already reachable. (Native YouTube used to be
    // rewritten to the hub's tailnet address when roaming — a video that plays
    // from anywhere became "HUB UNREACHABLE".)
    if (!m_library || !m_library->remoteMode()
        || !uri.startsWith(QLatin1String("http")))
        return uri;
    const QUrl u(uri);
    const QString lanHost = QUrl(m_cfgSyncUrl).host();
    if (u.host() != lanHost && !privateHost(u.host()))
        return uri;
    if (m_cfgTailnet.isEmpty())
        return uri; // nothing to fall back to — leave it as the hub gave it
    // The link: probed every 30 s off the GUI thread. The very first play of a
    // session can land before that first answer — then one synchronous probe,
    // so the reachability gate is right rather than fast.
    auto *self = const_cast<AppController *>(this);
    if (m_hubLink.isEmpty())
        self->probeHubLink(true);
    else if (QDateTime::currentMSecsSinceEpoch() - m_hubProbeAt > 30'000)
        self->probeHubLink(false);
    if (m_hubLanOk)
        return uri; // on the hub's LAN: stream direct as before
    // Roaming: rewrite only the origin (scheme/host/port) to the tailnet,
    // keeping the path so the resume key and manifest match are unchanged.
    const QUrl base(m_cfgTailnet);
    QUrl out(uri);
    out.setScheme(base.scheme());
    out.setHost(base.host());
    out.setPort(base.port(8200));
    return out.toString();
}

QString AppController::playbackIdentity(const QString &enginePath) const
{
    if (enginePath.isEmpty() || m_playIdentity.isEmpty())
        return enginePath;
    // the url mpv opened for this play (a tailnet rewrite, the public door's
    // /raw — which carries a token that rotates — or the warm lane): the title
    if (enginePath == m_playUrl
        || (m_resumeFellBack && enginePath == m_hlsFallbackUrl))
        return m_playIdentity;
    return enginePath;
}

QString AppController::warmHlsUrl(const QString &httpUrl, double startSec,
                                 double durSec) const
{
    // The seekable transcoded lane: mpv opens an HLS master that begins near
    // the resume point (warm = segment index, SEG=4s) and rides the ladder down
    // on a thin link, instead of buffering the whole raw remux from a byte
    // offset. SDR (tone-mapped) — the tradeoff for an instant far seek. Native
    // mpv decodes any width, so no decoder width cap is needed here.
    QUrl u(reachableHub(httpUrl));
    const QString rel = u.path();   // /Movies/.../file.mkv (leading slash OK)
    if (rel.isEmpty())
        return QString();
    // The query is built fully percent-encoded by hand: QUrlQuery leaves a
    // literal `+` in the value, and the hub's parse_qs reads `+` as a SPACE —
    // every "HDR10+" title (50 of them) asked for a file that doesn't exist.
    u.setPath(QString());
    u.setQuery(QString());
    QString out = u.toString() + QStringLiteral("/hls/pl.m3u8?src=")
        + QString::fromUtf8(QUrl::toPercentEncoding(rel))
        + QStringLiteral("&warm=") + QString::number(int(startSec / 4.0))
        + QStringLiteral("&sdr=1");
    if (durSec > 0)
        out += QStringLiteral("&dur=") + QString::number(int(durSec));
    return out;
}

void AppController::tryHlsResumeFallback()
{
    if (m_hlsFallbackUrl.isEmpty() || m_resumeFellBack)
        return;
    m_resumeFellBack = true;
    m_resumeWatchdog.stop();
    emit toast(QStringLiteral("SLOW LINK · SWITCHING TO ADAPTIVE STREAM"));
    m_engine->load(m_hlsFallbackUrl, m_hlsFallbackStart, m_hlsFallbackAid,
                   m_hlsFallbackSid, m_hlsFallbackSpeed, m_hlsFallbackZoom);
}

void AppController::fetchCastChapters(const QString &uri)
{
    // Called from every cast status poll, so the uri guard is what stops this being
    // a request per second. A title's chapter marks cannot move while it plays.
    if (uri == m_chapterUri)
        return;
    m_chapterUri = uri;
    if (!m_castChapters.isEmpty()) {
        m_castChapters.clear();
        emit castChaptersChanged();     // clear the old film's marks immediately
    }
    if (uri.isEmpty() || hubBase().isEmpty())
        return;
    // The hub folds a src that is one of ITS OWN urls, so a local /mnt path has to
    // be expressed that way first — the same rule the rest of the app uses: the
    // file when it is here, the hub's name for it when it is not.
    QString src = uri;
    if (!src.startsWith(QLatin1String("http"))) {
        // the hub's server names a file by its path under settings.serveRoot
        // (the author's /mnt; a new install's "/", where the address IS the path)
        QString root = m_settings.value(QStringLiteral("serveRoot"), QStringLiteral("/"))
                           .toString();
        while (root.size() > 1 && root.endsWith(QLatin1Char('/')))
            root.chop(1);
        QString rel;
        if (root == QLatin1String("/"))
            rel = src.startsWith(QLatin1Char('/')) ? src.mid(1) : QString();
        else if (src.startsWith(root + QLatin1Char('/')))
            rel = src.mid(root.size() + 1);
        if (rel.isEmpty())
            return;                     // not library media (YouTube, a raw stream)
        src = hubBase() + QLatin1Char('/')
              + QString::fromUtf8(QUrl::toPercentEncoding(rel, "/"));
    }
    const QString url = hubBase() + QStringLiteral("/chapters?src=")
                        + QString::fromUtf8(QUrl::toPercentEncoding(src));
    QNetworkReply *r = m_nam->get(QNetworkRequest(QUrl(url)));
    connect(r, &QNetworkReply::finished, this, [this, r, uri] {
        r->deleteLater();
        if (uri != m_chapterUri)
            return;                     // the cast moved on while we were asking
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        QVariantList out;
        const QJsonArray arr = o.value(QStringLiteral("chapters")).toArray();
        for (const QJsonValue &v : arr) {
            const QJsonObject ch = v.toObject();
            out.append(QVariantMap{
                {QStringLiteral("time"), ch.value(QStringLiteral("time")).toDouble()},
                {QStringLiteral("title"), ch.value(QStringLiteral("title")).toString()}});
        }
        m_castChapters = out;
        emit castChaptersChanged();
    });
}

void AppController::castQueuePush()
{
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/castqueue")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    Logger::log(QStringLiteral("queue"),
                QStringLiteral("push %1 items to hub").arg(m_queue->count()));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("items"),
         QJsonArray::fromVariantList(m_queue->allItems())}
    }).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        if (o.contains(QStringLiteral("rev")))
            m_castqRev = o.value(QStringLiteral("rev")).toInt();
        r->deleteLater();
        emit queuePushed(); // quit() waits on this to flush the last edits
    });
}

// ── watch party (0.9.19) ─────────────────────────────────────────────────────
void AppController::setPartyOpen(bool on)
{
    if (on == m_partyOpen)
        return;
    m_partyOpen = on;
    emit partyOpenChanged();
}

// "…youtube.com/watch?v=ID…" or "…youtu.be/ID…" -> ID, else "".
QString AppController::youtubeIdOf(const QString &uri)
{
    static const QRegularExpression re(
        QStringLiteral("(?:youtube\\.com/watch\\?(?:.*&)?v=|youtu\\.be/"
                       "|youtube\\.com/(?:shorts|live|embed)/)"
                       "([A-Za-z0-9_-]{6,20})"));
    const auto m = re.match(uri);
    return m.hasMatch() ? m.captured(1) : QString();
}

// Shorts, /live/ and /embed/ links, m./music. hosts, youtu.be share links ->
// the one canonical watch URL. Everything downstream (history pings, resume
// keys, the cast lanes, titles) only knows watch?v=, so normalising at the
// door makes a Short play and track exactly like any other video.
static QString canonicalYouTube(const QString &uri)
{
    if (!uri.contains(QLatin1String("youtu")))
        return uri;
    if (uri.contains(QLatin1String("youtube.com/watch")) && !uri.contains(QLatin1String("m.youtube"))
        && !uri.contains(QLatin1String("music.youtube")))
        return uri;
    static const QRegularExpression idRe(
        QStringLiteral("(?:youtube\\.com/watch\\?(?:.*&)?v=|youtu\\.be/"
                       "|youtube\\.com/(?:shorts|live|embed)/)"
                       "([A-Za-z0-9_-]{6,20})"));
    const auto im = idRe.match(uri);
    const QString id = im.hasMatch() ? im.captured(1) : QString();
    if (id.isEmpty())
        return uri;
    QString out = QStringLiteral("https://www.youtube.com/watch?v=") + id;
    static const QRegularExpression t(QStringLiteral("[?&]t=([0-9hms]+)"));
    const auto m = t.match(uri);
    if (m.hasMatch())
        out += QStringLiteral("&t=") + m.captured(1);
    return out;
}

QString AppController::resolvePartyPath(const QString &uri) const
{
    // A from-cast party derives its "path" from the live cast URI. In the common
    // case that's a bare file path or a hub FILE url (`…/<key>`) and mediaKey()
    // resolves it fine. But a RECOVERY/adopt re-cast can hand us a hub HLS/cast
    // LANE url (`…/hls/pl.m3u8?src=<rel>&…`) — mediaKey() can't see inside a query,
    // so the key came back garbage → null art + dur 0 (Bug D), and dur 0 is Bug B's
    // wedge precondition. Pull the real media out of ?src= when it's there.
    const QString src = QUrlQuery(QUrl(uri).query())
                            .queryItemValue(QStringLiteral("src"), QUrl::FullyDecoded);
    if (src.isEmpty())
        return uri;   // bare path or hub file url — mediaKey() already handles both
    // `src` is the file path relative to the hub root, WITH a leading slash
    // (built from QUrl::path() in warmHlsUrl). Prefer the real local file so the
    // hub resolves art + ffprobes dur (§D); else hand back the clean canonical
    // key (no leading slash) so mediaKey() passes it straight through.
    const QString root = m_store->serveRoot();
    const QString local = root + src;
    if (QFileInfo::exists(local))
        return local;
    return src.startsWith(QLatin1Char('/')) ? src.mid(1) : src;
}

QJsonObject AppController::partyMediaJson() const
{
    return partyMediaJson(m_engine->path(), m_engine->duration(),
                          m_engine->mediaTitle());
}

QJsonObject AppController::partyMediaJson(const QString &path, double durationS,
                                         const QString &title) const
{
    // ── a YouTube video is not a file, and saying it is breaks the party ────
    // This always claimed kind:"file" with a mediaKey() of whatever the engine
    // was playing. For a YouTube watch URL that key resolves to nothing on the
    // hub, so hosting a party while watching YouTube published a media doc the
    // lane could not build — the host watched happily and every guest got
    // nothing. The hub has understood kind:"yt" all along; it just was never
    // told.
    const QString ytId = youtubeIdOf(path);
    if (!ytId.isEmpty()) {
        return QJsonObject{
            {QStringLiteral("kind"), QStringLiteral("yt")},
            {QStringLiteral("vid"), ytId},
            {QStringLiteral("dur"), durationS},
            {QStringLiteral("title"), title},
        };
    }
    QJsonObject m{
        {QStringLiteral("kind"), QStringLiteral("file")},
        {QStringLiteral("key"), m_store->mediaKey(path)},
        {QStringLiteral("dur"), durationS},
        {QStringLiteral("title"), title},
    };
    const QVariantMap d = m_library->detail(path);
    if (d.isEmpty())
        return m;
    // Art basenames only — the hub's /p/<token>/art resolves them in its art
    // cache (same TMDB-hashed filenames on every codec).
    const auto put = [&](const char *dst, const char *src) {
        const QString v = d.value(QLatin1String(src)).toString();
        if (!v.isEmpty())
            m[QLatin1String(dst)] = v;
    };
    const QString poster = d.value(QStringLiteral("poster")).toString();
    if (!poster.isEmpty())
        m[QStringLiteral("poster")] = QFileInfo(poster).fileName();
    const QString fanart = d.value(QStringLiteral("fanart")).toString();
    if (!fanart.isEmpty())
        m[QStringLiteral("backdrop")] = QFileInfo(fanart).fileName();
    put("title", "title");
    put("plot", "plot");
    put("genres", "genres");
    put("director", "director");
    put("year", "year");
    const double rating = d.value(QStringLiteral("rating")).toDouble();
    if (rating > 0)
        m[QStringLiteral("rating")] = rating;
    const int runtime = d.value(QStringLiteral("runtimeMin")).toInt();
    if (runtime > 0)
        m[QStringLiteral("runtime")] = runtime;
    return m;
}

void AppController::startWatchParty()
{
    // Two ways to seed the room: the movie is playing HERE (local), or it is
    // already on the TV as a solo cast (party-FROM-cast). The second is the
    // case that used to dead-end on "PLAY A MOVIE FIRST" while a film was
    // plainly on the television.
    const bool engineIdle = m_engine->idle() || m_engine->path().isEmpty();
    const bool fromCast = engineIdle && m_cast->active()
                          && !m_cast->currentUri().isEmpty();
    if (engineIdle && !fromCast) {
        emit toast(QStringLiteral("PLAY A MOVIE FIRST"));
        return;
    }
    const QString path  = fromCast ? resolvePartyPath(m_cast->currentUri())
                                    : m_engine->path();
    const double  pos   = fromCast ? m_cast->castPosition() : m_engine->position();
    const double  durS  = fromCast ? m_cast->castDuration() : m_engine->duration();
    const QString title = fromCast ? m_cast->castTitle()    : m_engine->mediaTitle();
    const bool  paused  = fromCast ? (m_cast->castState() != QLatin1String("PLAYING"))
                                   : m_engine->paused();
    const double rate   = fromCast ? m_cast->castRate()     : m_engine->speed();
    // A live stream has no fixed timeline to hand around, so there is no clock
    // for a room to share — that stays out. YouTube, on the other hand, parties
    // now: the hub serves a kind=yt lane exactly like a local file (verified),
    // and partyMediaJson() below emits the {kind:"yt", vid} doc the lane builds
    // from. This used to refuse every YouTube uri ("LOCAL MOVIES ONLY") — an
    // obsolete restriction from before the yt lane existed.
    if (!fromCast && m_liveNow) {
        emit toast(QStringLiteral("WATCH PARTY · LIVE TV CAN'T PARTY YET"));
        return;
    }
    const QJsonObject media = partyMediaJson(path, durS, title);
    // Self-protecting: only seed a party from something the hub can actually
    // build a lane for — a real YouTube video id, or a resolvable file key. A
    // uri that resolves to neither (an odd from-cast source, say) gets a clear
    // toast instead of a room that shows every guest a black frame.
    const QString mkind = media.value(QStringLiteral("kind")).toString();
    const bool shareable =
        (mkind == QLatin1String("yt")
         && !media.value(QStringLiteral("vid")).toString().isEmpty())
        || (mkind == QLatin1String("file")
            && !media.value(QStringLiteral("key")).toString().isEmpty());
    if (!shareable) {
        emit toast(QStringLiteral("WATCH PARTY · CAN'T SHARE THIS ONE"));
        return;
    }
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/start")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    Logger::log(QStringLiteral("party"),
                QStringLiteral("start requested (%1)")
                    .arg(fromCast ? QStringLiteral("from cast")
                                  : QStringLiteral("local")));
    // Hub-owned from the start. When this app was the clock, "my TV AND his at
    // once" was impossible and the host could never be a viewer — the movie
    // had to be projected from here. Now the hub holds the clock and this
    // screen joins its own party like everybody else.
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("mode"), QStringLiteral("hub")},
        {QStringLiteral("media"), media},
        {QStringLiteral("pos"), pos},
        {QStringLiteral("paused"), paused},
        {QStringLiteral("rate"), rate},
    }).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this,
            [this, r, fromCast] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (!o.value(QStringLiteral("ok")).toBool()) {
            emit toast(QStringLiteral("WATCH PARTY · HUB UNREACHABLE"));
            Logger::log(QStringLiteral("party"),
                        QStringLiteral("start failed — hub unreachable"));
            return;
        }
        m_partyToken = o.value(QStringLiteral("token")).toString();
        m_partyInviteUrl = o.value(QStringLiteral("inviteUrl")).toString();
        m_partyReceiverUrl = o.value(QStringLiteral("receiverUrl")).toString();
        m_partyLive = true;
        m_partyMode = QStringLiteral("hub");
        m_partyPeers = 0;
        if (fromCast) {
            // #218: the host watches DOLBY VISION on the TV — and we DELIBERATELY do
            // NOT reload the receiver onto the shared SDR party lane anymore. That
            // reload (the old m_cast->castLoad with a partyToken) was the one and
            // only thing that cost the host its DV. Instead the host keeps its DV
            // solo cast and becomes the room's clock AUTHORITY: partyDriving() routes
            // its transport to /party/cmd for instant follower response, the cast-
            // remote methods now MIRROR each action onto the host's own DV lane
            // (castTogglePause/castSeekRel/castStepRate/castSeekTo), and the 1.5s
            // publish timer pins the room clock to the host's REAL DV position
            // (partyPublishCast) so SDR followers stay synced to DV reality. The host
            // receiver is never handed a stateUrl, so it stays SOLO (not room-
            // controlled) and its DV seek re-warm keeps working.
            m_partyViaCast = true;
            m_partyFollowing = false;
            m_partyViaStream = false;
            m_partyPublishTimer.start();   // pin the room clock to the host's DV lane
            emit partyChanged();
            Logger::log(QStringLiteral("party"),
                        QStringLiteral("live from cast (host keeps DV); invite=%1").arg(
                            m_partyInviteUrl.isEmpty() ? QStringLiteral("(no funnel)")
                                                       : m_partyInviteUrl));
            emit toast(m_partyInviteUrl.isEmpty()
                           ? QStringLiteral("WATCH PARTY ON · TV JOINED · SET UP FUNNEL FOR THE LINK · DV KEPT")
                           : QStringLiteral("WATCH PARTY ON · TV JOINED · DV KEPT"));
            return;
        }
        // The right file is already open at the right spot, so joining is just
        // handing the clock over — no reload, no black frame.
        m_partyViaCast = false;
        m_partyFollowing = true;
        m_partyViaStream = false;   // we're playing the file we started from
        m_partyFollowTimer.start();
        emit partyChanged();
        Logger::log(QStringLiteral("party"),
                    QStringLiteral("live; invite=%1").arg(
                        m_partyInviteUrl.isEmpty() ? QStringLiteral("(no funnel)")
                                                   : m_partyInviteUrl));
        emit toast(m_partyInviteUrl.isEmpty()
                       ? QStringLiteral("WATCH PARTY ON · SET UP FUNNEL FOR THE LINK")
                       : QStringLiteral("WATCH PARTY ON"));
    });
}

void AppController::joinWatchParty()
{
    if (!m_partyLive || m_partyToken.isEmpty()) {
        emit toast(QStringLiteral("NOTHING PLAYING RIGHT NOW"));
        return;
    }
    if (m_partyFollowing || m_partyViaCast)
        return;
    // "Watch here" watches on whatever the OUTPUT points at. If the output is a
    // cast device, join the party ON THE TV (cast it as a follower) instead of
    // playing locally — otherwise choosing the TV as output and then joining
    // put the film in the local miniplayer while the TV drifted on its own, and
    // the app lost its control link to the TV. This is the same follower the
    // party-from-cast path uses; the worker builds the party lane from the
    // token, so a bare item (token + title) is enough.
    if (!m_cast->targetId().isEmpty()) {
        QVariantMap item;
        item.insert(QStringLiteral("partyToken"), m_partyToken);
        item.insert(QStringLiteral("title"), m_partyTitle);
        if (m_partyDur > 0)
            item.insert(QStringLiteral("durationS"), m_partyDur);
        m_cast->castLoad(item, partyPos());
        m_partyViaCast = true;
        m_partyFollowing = false;
        setPartyOpen(false);
        emit partyChanged();
        Logger::log(QStringLiteral("party"),
                    QStringLiteral("joined on cast %1").arg(m_cast->targetName()));
        emit toast(QStringLiteral("WATCH PARTY · ON ")
                   + m_cast->targetName().toUpper());
        return;
    }
    // Play the file off the shelf whenever we have it: full quality, no
    // transcode, and nothing but the clock crosses the network. Streaming our
    // own HLS back to ourselves would be a worse copy of a file we own.
    const QString local = partyLocalFile();
    bool viaStream = false;
    const QString src = partyFilmSource(&viaStream);
    if (src.isEmpty()) {
        emit toast(QStringLiteral("CAN'T FIND WHAT THE PARTY IS PLAYING"));
        return;
    }
    m_partyFollowing = true;
    m_partyViaStream = viaStream;
    m_partyLastSeek = 0;
    // The party's film by its library name and year, like any other play — the
    // join loads the file directly, so mpv fell back to "Children Of Men
    // 2006.mkv" on the OSD. Streaming (no local copy): the party's own title.
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine)) {
        QString t = local.isEmpty() ? QString() : osdTitleFor(local);
        if (t.isEmpty())
            t = m_partyTitle;
        mpv->setForcedTitle(t);
    }
    if (m_engine->path() != src) {
        m_engine->load(src, partyPos());
        m_partyReloadAt = QDateTime::currentMSecsSinceEpoch();   // (the "opening" window)
        partyStreamLoaded();
    }
    // Get out of the way — you asked to watch, so show the film. Leaving the
    // panel up also stranded it: moving to the player stage takes the keyboard
    // back, and the overlay sat there with `w` no longer able to close it.
    setPartyOpen(false);
    setStage(QStringLiteral("player"));
    m_partyFollowTimer.start();
    emit partyChanged();
    Logger::log(QStringLiteral("party"),
                QStringLiteral("joined %1 (%2)").arg(
                    m_partyTitle, local.isEmpty() ? QStringLiteral("stream")
                                                  : QStringLiteral("local file")));
    emit toast(local.isEmpty() ? QStringLiteral("JOINED · STREAMING")
                               : QStringLiteral("JOINED THE PARTY"));
}

void AppController::leaveWatchParty()
{
    leaveWatchPartyAs(QStringLiteral("LEFT THE PARTY · STILL PLAYING HERE"));
}

void AppController::leaveWatchPartyAs(const QString &why)
{
    if (!m_partyFollowing && !m_partyHosting && !m_partyViaCast)
        return;
    m_partyFollowTimer.stop();
    m_partyPublishTimer.stop();
    m_partyFollowing = false;
    m_partyHosting = false;
    m_partyViaCast = false;
    m_partyStartPending = false;  // #59: don't let a stale pending arm block a re-join
    m_engine->resetSpeed();
    emit partyChanged();
    Logger::log(QStringLiteral("party"), QStringLiteral("left the session"));
    if (!why.isEmpty())
        emit toast(why);
}

void AppController::partySay(const QString &text)
{
    partySayImpl(text, QString());
}

void AppController::partyReact(const QString &key)
{
    partySayImpl(QString(), key);
}

void AppController::partySayImpl(const QString &text, const QString &react)
{
    // The host speaks over the LAN write surface, which is the one that has
    // never been reachable from outside the house. A guest's line rides their
    // clock poll instead — same ring, different door, and only one of the two
    // doors is on the internet.
    if (m_partyToken.isEmpty() || (text.trimmed().isEmpty() && react.isEmpty()))
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/say")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QJsonObject body{{QStringLiteral("token"), m_partyToken},
                     {QStringLiteral("who"), partyMyName()}};
    if (!react.isEmpty())
        body.insert(QStringLiteral("react"), react);
    else
        body.insert(QStringLiteral("text"), text.trimmed().left(180));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body)
                                        .toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, r, &QNetworkReply::deleteLater);
}

void AppController::partyVoteRewind()
{
    // In hub mode the vote is the mechanism; the app is a screen like any
    // other and gets no shortcut. What it CAN do is say so out loud, which is
    // what a guest's vote does too — and if the room agrees, the hub moves.
    if (m_partyToken.isEmpty())
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/cmd")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("op"), QStringLiteral("skip")},
        {QStringLiteral("arg"), -30.0}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, r, &QNetworkReply::deleteLater);
    partySayImpl(QStringLiteral("rewound 30s"), QString());
}

// The host's say over who is in the room (LAN writes; the hub's "Seats").
// DROP takes a screen out — its TV with it — for good; LOCK lets nobody new in.
void AppController::partyDrop(const QString &id)
{
    if (id.isEmpty() || !m_partyLive)
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/drop")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("id"), id}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        partyPoll();   // the roster updates now, not on the next 3 s tick
    });
}

void AppController::partyUndrop(const QString &id)
{
    if (id.isEmpty() || !m_partyLive)
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/undrop")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("id"), id}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        partyPoll();
    });
}

void AppController::partyLock(bool on)
{
    if (!m_partyLive)
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/lock")));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("on"), on}}).toJson(QJsonDocument::Compact));
    m_partyLocked = on;          // show it now; the next poll confirms
    emit partyChanged();
    connect(r, &QNetworkReply::finished, this, [this, r] {
        r->deleteLater();
        partyPoll();
    });
}

void AppController::endWatchParty()
{
    // Any codec on the LAN can end it — it learned the token from the hub, and
    // the LAN is already the trust boundary. Ending over Funnel stays
    // impossible: /party/stop is a write and writes never leave the house.
    const QString token = m_partyToken;
    m_partyFollowTimer.stop();
    m_partyPublishTimer.stop();
    if (!token.isEmpty()) {
        QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/stop")));
        req.setHeader(QNetworkRequest::ContentTypeHeader,
                      QStringLiteral("application/json"));
        QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
            {QStringLiteral("token"), token}}).toJson(QJsonDocument::Compact));
        connect(r, &QNetworkReply::finished, r, &QNetworkReply::deleteLater);
    }
    const bool was = m_partyLive;
    m_partyLive = m_partyHosting = m_partyFollowing = m_partyViaCast = false;
    m_partyStartPending = false;  // #59: clear the scheduled-start arm on end too
    m_partyToken.clear();
    m_partyInviteUrl.clear();
    m_partyReceiverUrl.clear();
    m_partyTitle.clear();
    m_partyKey.clear();
    m_partyWho.clear();
    m_partyPeers = 0;
    m_engine->resetSpeed();
    emit partyChanged();
    if (was) {
        Logger::log(QStringLiteral("party"), QStringLiteral("ended"));
        emit toast(QStringLiteral("WATCH PARTY OFF"));
    }
}

void AppController::stopWatchParty()
{
    // `x` in the overlay: end it if it's ours, otherwise just step out. A
    // party-from-cast is ours — we started the hub room — so it ends.
    if (m_partyHosting || m_partyViaCast
        || (m_partyFollowing && partyHubMode()))
        endWatchParty();
    else
        leaveWatchParty();
}

// ── transport: are we driving this screen, or the whole party? ───────────────
//
// party-via-cast (host casting DV to the TV in a party) is the subtle case: the
// keyboard transport must move the HOST'S CAST LANE, not only the room clock.
// Routing to a bare partyCmd moved the clock but left the cast where it was, so
// partyPublishCast then pinned the cast's stale position and reverted the seek
// (the "seek fighting"). Delegate to the cast-aware methods — castTogglePause /
// castSeekRel / castSeekTo — which author the room clock AND move the DV lane
// AND arm the publish-hold, exactly like the cast remote already does.
void AppController::playPause()
{
    if (m_partyViaCast && partyHubMode()) { castTogglePause(); return; }
    if (partyDriving())
        partyCmd(m_partyPaused ? QStringLiteral("play") : QStringLiteral("pause"));
    else
        m_engine->togglePause();
}

void AppController::seekBy(double seconds)
{
    if (m_partyViaCast && partyHubMode()) { castSeekRel(seconds); return; }
    if (m_liveNow && !m_cast->active() && !partyDriving()) { liveSeekBy(seconds); return; }
    if (partyDriving())
        partyCmd(QStringLiteral("skip"), seconds);
    else
        m_engine->seekRel(seconds);
}

void AppController::seekTo(double seconds)
{
    if (m_partyViaCast && partyHubMode()) { castSeekTo(seconds); return; }
    if (partyDriving())
        partyCmd(QStringLiteral("seek"), seconds);
    else
        m_engine->seekAbs(seconds);
}

// The scrub bar used to call Engine.seekPct() directly, which moved only THIS
// screen's mpv and never told the room clock — so partyFollow seekAbs'd us back
// (the seek "fighting"). In party-via-cast it becomes a cast seek; in a normal
// hub party a room command. pct is 0-100 (as PlayerView passes).
void AppController::seekPct(double pct)
{
    if (m_liveNow && !m_cast->active() && !partyDriving()) {
        liveSeekFrac(qBound(0.0, pct / 100.0, 1.0));
        return;
    }
    if (m_partyViaCast && partyHubMode()) {
        if (m_cast->castDuration() > 0)
            castSeekTo(qBound(0.0, pct / 100.0, 1.0) * m_cast->castDuration());
        return;
    }
    if (partyDriving()) {
        if (m_partyDur > 0)   // known room duration → author the room clock
            partyCmd(QStringLiteral("seek"), qBound(0.0, pct / 100.0, 1.0) * m_partyDur);
        // else: unknown room duration — ignore rather than seek only THIS screen
        // (the old fallthrough to m_engine->seekPct re-armed the fight, #26/#27)
        return;
    }
    m_engine->seekPct(pct);
}

// Put a different film on for the whole party. Only the screen driving the
// session does this; a follower changing what IT watches just leaves.
void AppController::partyLoadMedia()
{
    if (m_partyToken.isEmpty() || m_engine->path().isEmpty())
        return;
    // Never "move" a room onto a party stream: a laptop joining by stream once
    // sent the room its own URL as the new film, at 0:00 (2026-10-10).
    if (isPartyStream(m_engine->path()))
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/cmd")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("op"), QStringLiteral("media")},
        {QStringLiteral("media"), partyMediaJson()},
        {QStringLiteral("arg"), m_engine->position()},
        {QStringLiteral("paused"), m_engine->paused()},
    }).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (!o.value(QStringLiteral("ok")).toBool()) {
            // the hub can't play it for the room (not in the library, a
            // trailer): this screen goes its own way rather than being pulled
            // back to the room's film half a minute later
            if (m_partyFollowing && partyHubMode())
                leaveWatchPartyAs(QStringLiteral("THE PARTY CAN'T PLAY THAT · LEFT THE PARTY"));
            return;
        }
        m_partyLastSeek = 0;
        Logger::log(QStringLiteral("party"),
                    QStringLiteral("party moved to %1").arg(m_engine->mediaTitle()));
        emit toast(QStringLiteral("PARTY NOW WATCHING · ")
                   + m_engine->mediaTitle().toUpper());
        partyPoll();
    });
}

void AppController::partyAdvanceCast(const QVariantMap &nextItem)
{
    // The DV-cast host drives the room by casting to its OWN TV (it keeps its
    // solo DV lane — #218 — and authors the room clock), so advancing the queue
    // is TWO actions at once: move the whole room to the next item (op:media, so
    // followers on the shared lane re-warm to it) AND re-cast the host's TV to it
    // (a fresh lane for whatever format it is — DV stays DV, a YouTube item casts
    // its yt lane). castPlay() refuses while m_partyViaCast (a solo cast would
    // yank the TV off the room), so this does the cast directly, paired with the
    // party media change. partyMediaJson() handles kind=file AND kind=yt, so a
    // mixed DV/HDR/SDR/YouTube queue advances straight through.
    const QString uri = nextItem.value(QStringLiteral("uri")).toString();
    if (uri.isEmpty() || m_partyToken.isEmpty())
        return;
    QVariantMap item = nextItem;
    const QVariantMap info = m_library->entryInfo(uri);
    if (item.value(QStringLiteral("title")).toString().isEmpty())
        item.insert(QStringLiteral("title"),
                    info.value(QStringLiteral("title"), Library::prettyTitle(uri)));
    if (item.value(QStringLiteral("artUrl")).toString().isEmpty()) {
        const QString poster = info.value(QStringLiteral("poster")).toString();
        if (!poster.isEmpty())
            item.insert(QStringLiteral("artUrl"), poster);
    }
    const double dur = m_store->state(uri)
                           .value(QStringLiteral("duration")).toDouble();
    if (item.value(QStringLiteral("durationS")).toDouble() <= 0 && dur > 0)
        item.insert(QStringLiteral("durationS"), dur);
    item.insert(QStringLiteral("subsize"), castCaptionScale() / 100.0);   // a burn wears the CAST size
    const QString title = item.value(QStringLiteral("title")).toString();
    // 1) Move the room. The hub backfills a yt/file media doc's real duration, so
    //    a dur we don't know yet (a YouTube item) is fine to send as 0.
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/cmd")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("op"), QStringLiteral("media")},
        {QStringLiteral("media"), partyMediaJson(uri, dur, title)},
        {QStringLiteral("arg"), 0.0},
        {QStringLiteral("paused"), false},
    }).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r, item, title] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (!o.value(QStringLiteral("ok")).toBool()) {
            // Room didn't move (hub unreachable) — do NOT solo-cast the next
            // film onto the TV, or it desyncs from the room. Leave the TV on the
            // finished film's end and let the host retry.
            emit toast(QStringLiteral("PARTY · COULDN'T ADVANCE"));
            return;
        }
        // 2) Room moved — now re-cast the host's own TV to the same item.
        m_partyLastSeek = 0;
        m_autoplayChain = 0;
        rememberLive(item);
        m_cast->castLoad(item, 0);
        Logger::log(QStringLiteral("party"),
                    QStringLiteral("cast-host advanced room to %1").arg(title));
        emit toast(QStringLiteral("PARTY NEXT · ") + title.toUpper());
    });
}

void AppController::partyCmd(const QString &op, double arg)
{
    if (m_partyToken.isEmpty())
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/cmd")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    const quint64 myseq = ++m_partyCmdSeq;   // #24/#29: newest cmd wins its reply
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("op"), op},
        {QStringLiteral("arg"), arg}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r, myseq] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (!o.value(QStringLiteral("ok")).toBool())
            return;
        // #24/#29: a late/out-of-order reply must not stomp a fresher clock — a
        // rapid seek burst fires several partyCmds and their replies can land in
        // any order. Apply only the LATEST cmd's reply; older ones are stale.
        if (myseq != m_partyCmdSeq)
            return;
        // Take the hub's answer immediately rather than waiting for the next
        // poll, so the OSD moves the instant you press the key.
        m_partyClockPos = o.value(QStringLiteral("pos")).toDouble();
        m_partyPaused = o.value(QStringLiteral("paused")).toBool();
        m_partyRate = o.value(QStringLiteral("rate")).toDouble(1.0);
        m_partyEpochMs = QDateTime::currentMSecsSinceEpoch() + m_partySkewMs;
        emit partyChanged();
        partyFollow();
    });
}

// Who this screen shows up as in the room. Same source the hub uses for the
// invite text, so "Alex wants to watch X with you" and the roster agree.
QString AppController::partyMyName() const
{
    const QString n = m_settings.value(QStringLiteral("partyName")).toString().trimmed();
    if (!n.isEmpty())
        return n.left(24);
    QFile cf(QDir::homePath() + QStringLiteral("/.config/codec/config.json"));
    if (cf.open(QIODevice::ReadOnly)) {
        const QString h = QJsonDocument::fromJson(cf.readAll()).object()
                              .value(QStringLiteral("party")).toObject()
                              .value(QStringLiteral("hostName")).toString().trimmed();
        if (!h.isEmpty())
            return h.left(24);
    }
    return QSysInfo::machineHostName();
}

// Land this screen on the room's frame. A local file just seeks. A party
// stream is a LIVE playlist (it ends at the room's playhead) and ffmpeg's HLS
// reader can't seek in one: mpv can only move inside what it has cached, and
// past that it walks every segment in between — after a room jump the laptop
// crawled ~400 missing segments for two minutes (2026-10-10). Reopening lands
// at the live edge, which IS the room's frame. At most every 10 s.
void AppController::partySeekTo(double t)
{
    if (!m_partyViaStream || qAbs(t - m_engine->position()) <= 8.0) {
        m_engine->seekAbs(t);
        return;
    }
    if (!m_partyFileOk)
        return;   // still opening: its position isn't real yet
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_partyReloadAt < 10000)
        return;
    m_partyReloadAt = now;
    Logger::log(QStringLiteral("party"),
                QStringLiteral("room is %1 s away — reopening the stream at its frame")
                    .arg(qRound(t - m_engine->position())));
    m_engine->load(hubBase() + QStringLiteral("/p/") + m_partyToken + QStringLiteral("/hls/pl"), t);
    partyStreamLoaded();
}

// After loading the room's film: remember which film that was (a stream's URL
// doesn't change between films), and give a stream the film's real length —
// mpv only sees the window the room's encoder has made.
void AppController::partyStreamLoaded()
{
    m_partyFileOk = false;   // until mpv says FILE_LOADED (see the fileLoaded hook)
    m_partyLoadedKey = m_partyKey;
    if (m_partyViaStream && m_partyDur > 0)
        if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
            mpv->setDurationHint(m_partyDur);
}

// Any party's HLS stream (`…/p/<token>/hls/…`) — what a screen without the
// film plays. It is never "a different film".
bool AppController::isPartyStream(const QString &path) const
{
    return path.contains(QLatin1String("/p/")) && path.contains(QLatin1String("/hls/"));
}

// Where this screen gets the room's film: the file off its own shelf; a
// YouTube room straight from YouTube (full quality, seekable — every screen
// fetches its own); otherwise the room's stream from the hub. Empty = the
// room has nothing this screen can play.
QString AppController::partyFilmSource(bool *viaStream) const
{
    if (viaStream)
        *viaStream = false;
    const QString local = partyLocalFile();
    if (!local.isEmpty())
        return local;
    if (m_partyKey.startsWith(QLatin1String("yt:")) && m_partyKey.size() > 3)
        return QStringLiteral("https://www.youtube.com/watch?v=") + m_partyKey.mid(3);
    if (m_partyKey.isEmpty())
        return QString();
    if (viaStream)
        *viaStream = true;
    return hubBase() + QStringLiteral("/p/") + m_partyToken + QStringLiteral("/hls/pl");
}

QString AppController::partyLocalFile() const
{
    if (m_partyKey.isEmpty() || m_partyKey.startsWith(QLatin1String("yt:")))
        return QString();
    const QString root = m_store->serveRoot();
    if (root.isEmpty())
        return QString();
    const QString p = root + QLatin1Char('/') + m_partyKey;
    return QFileInfo::exists(p) ? p : QString();
}

double AppController::partyPos() const
{
    if (!m_partyLive)
        return 0;
    if (m_partyPaused)
        return m_partyClockPos;
    const qint64 hubNow = QDateTime::currentMSecsSinceEpoch() + m_partySkewMs;
    // a scheduled start still ahead: the clock holds there (the hub's max(0,…))
    if (hubNow < m_partyEpochMs)
        return m_partyClockPos;
    double p = m_partyClockPos + (hubNow - m_partyEpochMs) / 1000.0 * m_partyRate;
    if (m_partyDur > 0)
        p = qMin(p, m_partyDur);
    return qMax(0.0, p);
}

// One sync tick: where should this screen be, and how do we get there without
// making it worse? Speed nudging, not seeking — a seek throws away everything
// buffered and (on a thin link) starves the very gap it was trying to close.
// A local file has no such buffer, so the deadband can be tight.
void AppController::partyFollow()
{
    if (!m_partyFollowing || m_partyToken.isEmpty())
        return;
    // Poll the follower surface, not /party/status: it carries our id, which
    // is what marks us present in the room and keeps the hub's auto-pause from
    // deciding everybody left.
    // The name rides the poll, which is what puts us in the room's roster —
    // without it the others saw a party of two with one name in it.
    QString u = hubBase() + QStringLiteral("/p/") + m_partyToken
        + QStringLiteral("/state?g=") + m_partyGuestId
        + QStringLiteral("&n=")
        + QString::fromUtf8(QUrl::toPercentEncoding(partyMyName()));
    // Our round trip from the PREVIOUS poll. Only the client can time it, and
    // it's what colours this screen's dot in everyone else's roster.
    if (m_partyRttMs >= 0)
        u += QStringLiteral("&rtt=") + QString::number(m_partyRttMs);
    // The cushion this screen needs, which the hub takes the worst of across
    // the room. Unlike a phone we can answer this analytically: playing our own
    // file off the shelf there is nothing at all to wait for, and streaming
    // there is one segment.
    u += QStringLiteral("&cu=")
        + QString::number(m_partyViaStream ? 1.0 : 0.05, 'f', 2);
    // Where we are: the hub seats a screen that is watching in step (and this
    // one, on the LAN, the moment it is). Not when nothing is playing here —
    // a screen in the house that says nothing is simply trusted.
    if (!m_engine->idle())
        u += QStringLiteral("&p=") + QString::number(m_engine->position(), 'f', 2);
    // The room changed film and holds everyone on its first frame until every
    // screen has it: say so once ours is loaded and parked at the room's spot.
    if (m_partyLoadSeq >= 0 && m_partyFileOk && !m_engine->idle() && m_engine->duration() > 0
            && (m_partyLoadedKey == m_partyKey
                || (!m_partyKey.isEmpty() && m_store->mediaKey(m_engine->path()) == m_partyKey))
            && qAbs(m_engine->position() - m_partyClockPos) < 2.5)
        u += QStringLiteral("&rdy=") + QString::number(m_partyLoadSeq);
    QNetworkRequest req{QUrl(u)};
    req.setTransferTimeout(4000);
    const qint64 sentAt = QDateTime::currentMSecsSinceEpoch();
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r, sentAt] {
        const bool bad = r->error() != QNetworkReply::NoError;
        if (!bad) {
            const int rtt = int(QDateTime::currentMSecsSinceEpoch() - sentAt);
            // Smoothed the same way the hub smooths a guest's, so one slow
            // reply doesn't make the dot jump.
            m_partyRttMs = m_partyRttMs < 0 ? rtt
                                            : int(m_partyRttMs * 0.6 + rtt * 0.4);
        }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        // The host DROPPED this screen (or locked it out): it used to treat
        // that as one bad reply and keep "watching" forever, drifting, and
        // couldn't rejoin either. Leave, and say why.
        if (!bad && (o.value(QStringLiteral("removed")).toBool()
                     || o.value(QStringLiteral("locked")).toBool())) {
            const bool removed = o.value(QStringLiteral("removed")).toBool();
            leaveWatchParty();
            emit toast(removed ? QStringLiteral("REMOVED FROM THE PARTY")
                               : QStringLiteral("THE PARTY IS LOCKED"));
            return;
        }
        if (bad || !o.value(QStringLiteral("active")).toBool())
            return;
        const qint64 serverNow = qint64(o.value(QStringLiteral("server_now_ms")).toDouble());
        const qint64 epoch = qint64(o.value(QStringLiteral("epoch_ms")).toDouble());
        m_partySkewMs = serverNow - QDateTime::currentMSecsSinceEpoch();
        m_partyClockPos = o.value(QStringLiteral("pos")).toDouble();
        m_partyLoadSeq = o.value(QStringLiteral("loading")).toBool()
            ? o.value(QStringLiteral("load_seq")).toInt() : -1;
        if (m_partyLoadSeq >= 0 && m_partyLoadSeq != m_partyLoadToast) {
            m_partyLoadToast = m_partyLoadSeq;
            emit toast(QStringLiteral("LOADING FOR EVERYONE"));
        }
        // The clock poll heard of a film change before the status poll (the
        // one that carries the film's key) did: acting on the OLD key here
        // reopened the stream for the wrong film, or reported ready from the
        // old film. Fetch the status now and act on the next tick.
        if (m_partyLoadSeq >= 0 && m_partyLoadSeq > m_partyStatusSeq) {
            partyPoll();
            emit partyChanged();
            return;
        }
        m_partyPaused = o.value(QStringLiteral("paused")).toBool();
        m_partyRate = o.value(QStringLiteral("rate")).toDouble(1.0);
        m_partyEpochMs = epoch;
        // One cushion for the whole room, decided by the hub from the worst
        // screen in it. We used to keep our own — and being right about our own
        // needs is exactly how this machine ended up sitting dead on the clock
        // while a phone sat half a second back. Nobody watches the clock; they
        // watch each other. So we take the room's number even when it means
        // deliberately running late.
        const int roomLagMs = o.value(QStringLiteral("room_lag_ms")).toInt(-1);
        if (roomLagMs >= 0)
            m_partyRoomLagMs = roomLagMs;
        m_partyLagWho = o.value(QStringLiteral("lag_who")).toString();
        m_partyWaitingFor.clear();
        for (const QJsonValue &w : o.value(QStringLiteral("waiting_for")).toArray())
            m_partyWaitingFor << w.toString();
        // This screen follows the ROOM's film: after it ran off the end and
        // the room went on (a seek back), or after a queue advance (a new
        // file), it sat idle — or on the old film — while the room counted it
        // as watching (2026-10-10: joined at the very end, left the player at
        // EOF 0.8 s later, never came back when the room was sent to 1:15).
        // Reload the room's film at the room's spot; not at the film's end,
        // and at most every 10 s so a file that won't load can't loop.
        if (m_partyFollowing) {
            const QString local = partyLocalFile();
            bool viaStream = false;
            const QString want = partyFilmSource(&viaStream);
            // the room's position NOW (the reply's pos is where the last
            // command left it): at a film's end the queue moves on — reloading
            // the finished film there raced the advance
            const bool atEnd = m_partyDur > 0 && partyPos() >= m_partyDur - 3;
            const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
            // Already on the room's film: its file, the room's stream loaded
            // for THIS film (a stream keeps its URL across films), or anything
            // with the room's key — the host playing a YouTube video directly
            // must not be swapped onto the hub's restream of it.
            const QString here = m_engine->path();
            // a load still opening (a YouTube resolve, a cold stream) is ON it —
            // restarting it every 10 s meant it might never finish
            const bool opening = !m_partyFileOk && here == want
                && nowMs - m_partyReloadAt < 45000;
            const bool onRoomFilm = (!m_engine->idle() || opening) && !here.isEmpty()
                && ((!local.isEmpty() && here == local)
                    || (isPartyStream(here) && viaStream && m_partyLoadedKey == m_partyKey)
                    || (!m_partyKey.isEmpty() && m_store->mediaKey(here) == m_partyKey));
            if (!want.isEmpty() && !atEnd && !onRoomFilm
                    && nowMs - m_partyReloadAt > 10000) {
                m_partyReloadAt = nowMs;
                m_partyViaStream = viaStream;
                if (auto *mpv = qobject_cast<MpvEngine *>(m_engine)) {
                    QString t = local.isEmpty() ? QString() : osdTitleFor(local);
                    mpv->setForcedTitle(t.isEmpty() ? m_partyTitle : t);
                }
                Logger::log(QStringLiteral("party"),
                            QStringLiteral("reloading the room's film (%1)")
                                .arg(m_engine->idle() ? QStringLiteral("player was idle")
                                                      : QStringLiteral("room changed film")));
                m_engine->load(want, partyPos());
                partyStreamLoaded();
                return;
            }
        }
        if (m_engine->idle())
            return;
        const double lag = m_partyRoomLagMs >= 0
            ? m_partyRoomLagMs / 1000.0
            : (m_partyViaStream ? 1.0 : 0.0);
        // A scheduled start: the hub has named a position AND the instant to
        // move at, and that instant hasn't come. Hold the frame and arm one
        // timer. `lead` is the gap between two of the hub's own timestamps, so
        // it's a duration and our clock being wrong can't spoil it; we take off
        // half a round trip because the news is that stale by the time it gets
        // here. This is what stops an unpause or a join from beginning at a
        // different moment on every screen.
        const double lead = double(epoch - serverNow);
        if (!m_partyPaused && lead > 0) {
            if (!m_engine->paused())
                m_engine->setPaused(true);
            m_engine->setSpeed(m_partyRate);
            if (qAbs(m_partyClockPos - m_engine->position()) > 0.3)
                partySeekTo(m_partyClockPos);
            if (!m_partyStartPending) {
                m_partyStartPending = true;
                const int wait = int(qMax(0.0, lead
                    - (m_partyRttMs > 0 ? m_partyRttMs / 2.0 : 0.0)));
                QTimer::singleShot(wait, this, [this] {
                    m_partyStartPending = false;
                    if (m_partyFollowing && !m_partyPaused && !m_engine->idle()) {
                        // #59: a reply during the wait can have moved the clock —
                        // land on the CURRENT expected room frame before unpausing so
                        // every screen still starts on the same frame together.
                        const double want = partyPos();
                        if (want >= 0 && qAbs(want - m_engine->position()) > 0.3)
                            partySeekTo(want);
                        m_engine->setPaused(false);
                    }
                });
            }
            emit partyChanged();
            return;
        }
        // `- lag` belongs to the PLAYING branch only. room_lag is the cushion a
        // moving clock needs so this screen isn't chasing a position that has
        // already advanced; a PAUSED clock isn't moving, so subtracting lag just
        // parks the codec app room_lag seconds behind every web/phone follower
        // (which target st.pos with no lag) — up to 12s when a Cast TV raises
        // the room cushion. Paused → land exactly on clockPos, same as the web.
        const double expected = m_partyPaused
            ? m_partyClockPos
            : (m_partyClockPos
                + qMax(0.0, double(serverNow - epoch)) / 1000.0 * m_partyRate - lag);
        const double here = m_engine->position();
        if (m_partyPaused) {
            if (!m_engine->paused())
                m_engine->setPaused(true);
            m_engine->setSpeed(m_partyRate);
            // Follow a seek made while paused, too: the host scrubbing back to
            // a scene has to move this screen, not leave it on the old frame.
            // Tight, because a seek while paused costs nothing to look at, and
            // mpv coasts a frame or so past the hub when it stops.
            if (qAbs(expected - here) > 0.5)
                partySeekTo(expected);
            emit partyChanged();
            return;
        }
        if (m_engine->paused())
            m_engine->setPaused(false);
        const double drift = expected - here;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (qAbs(drift) > 8.0) {
            if (now - m_partyLastSeek > 10000) {
                m_partyLastSeek = now;
                partySeekTo(expected);
                m_engine->setSpeed(m_partyRate);
            }
        } else {
            // Graded, so it settles into a tight band instead of giving up the
            // moment it's "close enough". One gear with a 0.35s dead zone each
            // way meant two screens could sit two thirds of a second apart and
            // the code called that correct — and 0.35s is plenty to hear a
            // laugh land early. The gentlest gear is half a percent: inaudible
            // (mpv pitch-corrects), and it holds the last few hundredths.
            const double ad = qAbs(drift), dir = drift > 0 ? 1.0 : -1.0;
            const double adj = ad > 1.0 ? 0.05
                             : ad > 0.4 ? 0.03
                             : ad > 0.12 ? 0.015
                             : ad > 0.05 ? 0.005 : 0.0;
            m_engine->setSpeed(m_partyRate * (1.0 + dir * adj));
        }
        emit partyChanged();
    });
}

// ── presence ────────────────────────────────────────────────────────────────
// Announce what this screen has open so the others can offer to take it. Both
// halves of taking it already worked before this existed: resume positions
// cross machines through codec_sync_state.py, and the queue is shared and
// always-on. Only the announcement was missing.
void AppController::nowPublish()
{
    // A party already announces itself, in more detail and with a join that
    // means something different. Two chips for one film would be a lie about
    // there being two things going on.
    if (m_partyLive || m_partyHosting || m_partyFollowing)
        return;
    if (m_engine->idle() || m_engine->path().isEmpty()) {
        if (m_nowPublished) {
            m_nowPublished = false;
            nowBye();
        }
        return;
    }
    const QJsonObject body{
        {QStringLiteral("device"), m_partyGuestId},
        {QStringLiteral("name"), partyMyName()},
        {QStringLiteral("title"), m_engine->mediaTitle()},
        {QStringLiteral("pos"), m_engine->position()},
        {QStringLiteral("dur"), m_engine->duration()},
        {QStringLiteral("rate"), m_engine->speed()},
        {QStringLiteral("paused"), m_engine->paused()},
        {QStringLiteral("media"), partyMediaJson()},
        {QStringLiteral("stopAck"), m_nowStopAck},
    };
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/now")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    req.setTransferTimeout(4000);
    m_nowPublished = true;
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const bool bad = r->error() != QNetworkReply::NoError;
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (bad)
            return;
        // We've been handed off. The stop rides the reply to a request we
        // were making anyway, so it lands within one beat instead of waiting
        // on a poll — the film is already running on the other screen.
        const int stop = o.value(QStringLiteral("stop")).toInt();
        if (stop > m_nowStopAck) {
            m_nowStopAck = stop;
            Logger::log(QStringLiteral("now"),
                        QStringLiteral("handed off — stopping here"));
            m_engine->stop();
            leavePlayer();
            emit toast(QStringLiteral("RESUMED ON ANOTHER SCREEN"));
        }
    });
}

void AppController::nowBye()
{
    const QJsonObject body{{QStringLiteral("device"), m_partyGuestId}};
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/now/bye")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    req.setTransferTimeout(2000);
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, r, &QNetworkReply::deleteLater);
}

void AppController::nowApply(const QJsonArray &arr)
{
    // One chip, so one screen: the freshest, which the hub already sorted to
    // the front. More than two codecs playing different things at once is not
    // a real evening.
    const QJsonObject d = arr.isEmpty() ? QJsonObject() : arr.at(0).toObject();
    const QJsonObject m = d.value(QStringLiteral("media")).toObject();
    const bool was = m_nowElsewhere;
    const QString wasDev = m_nowDevice;
    m_nowElsewhere = !d.isEmpty();
    m_nowDevice = d.value(QStringLiteral("device")).toString();
    m_nowName = d.value(QStringLiteral("name")).toString();
    m_nowTitle = d.value(QStringLiteral("title")).toString();
    if (m_nowTitle.isEmpty())
        m_nowTitle = m.value(QStringLiteral("title")).toString();
    m_nowPos = d.value(QStringLiteral("pos")).toDouble();
    m_nowDur = d.value(QStringLiteral("dur")).toDouble();
    m_nowPaused = d.value(QStringLiteral("paused")).toBool();
    m_nowKey = m.value(QStringLiteral("key")).toString();
    m_nowVid = m.value(QStringLiteral("vid")).toString();
    if (was != m_nowElsewhere || wasDev != m_nowDevice || m_nowElsewhere)
        emit nowChanged();
}

// mpv opens a file asynchronously, so a seek issued next to play() lands on
// the outgoing file or on nothing at all. Wait for the new one to actually be
// open, then place it — and give up rather than seek something unrelated.
void AppController::nowSeekWhenLoaded(double pos)
{
    m_nowSeekTo = pos;
    m_nowSeekTries = 0;
    m_nowSeekTimer.start();
}

void AppController::resumeHere()
{
    if (!m_nowElsewhere || m_nowDevice.isEmpty())
        return;
    const QJsonObject body{{QStringLiteral("device"), m_partyGuestId},
                           {QStringLiteral("from"), m_nowDevice}};
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/now/resume")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    req.setTransferTimeout(5000);
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (!o.value(QStringLiteral("ok")).toBool()) {
            // Aged out, or another screen got there first. The hub is the
            // authority on that, and it says no.
            Logger::log(QStringLiteral("now"),
                        QStringLiteral("resume refused: ")
                            + o.value(QStringLiteral("error")).toString());
            emit toast(QStringLiteral("THAT SCREEN STOPPED FIRST"));
            m_nowElsewhere = false;
            emit nowChanged();
            return;
        }
        const QJsonObject m = o.value(QStringLiteral("media")).toObject();
        const double pos = o.value(QStringLiteral("pos")).toDouble();
        const QString vid = m.value(QStringLiteral("vid")).toString();
        QString uri;
        if (!vid.isEmpty()) {
            uri = QStringLiteral("https://www.youtube.com/watch?v=") + vid;
        } else {
            // The same canonical key the resume sync uses, resolved against
            // THIS machine's root — which is the whole reason a key travels
            // and a path never does.
            const QString key = m.value(QStringLiteral("key")).toString();
            const QString root = m_store->serveRoot();
            if (!key.isEmpty() && !root.isEmpty()) {
                const QString p = root + QLatin1Char('/') + key;
                if (QFileInfo::exists(p))
                    uri = p;
            }
            // ⚠ Not having the file is the NORMAL case, not a failure. A
            // laptop never has the media — it streams every library title
            // from the hub, and the X-Files live on a USB drive that is only
            // ever plugged into the desktop. Refusing there made the one
            // machine this feature exists for the one machine it didn't work
            // on. Same rule the rest of the app already uses: the local file
            // when it's there, the hub stream when it isn't.
            if (uri.isEmpty() && !key.isEmpty() && !hubBase().isEmpty())
                uri = hubBase() + QLatin1Char('/')
                      + QString::fromUtf8(QUrl::toPercentEncoding(key, "/"));
            if (uri.isEmpty()) {
                emit toast(QStringLiteral("CAN'T REACH THAT FILE OR THE HUB"));
                return;
            }
        }
        m_nowElsewhere = false;
        emit nowChanged();
        emit toast(QStringLiteral("RESUMED FROM ") + m_nowName.toUpper());
        Logger::log(QStringLiteral("now"),
                    QStringLiteral("resume %1 at %2")
                        .arg(uri).arg(pos, 0, 'f', 1));
        play(uri);
        if (pos > 1.0)
            nowSeekWhenLoaded(pos);
    });
}

void AppController::partyPublish(bool withMedia)
{
    if (!m_partyHosting || m_partyToken.isEmpty())
        return;
    QJsonObject body{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("pos"), m_engine->position()},
        {QStringLiteral("paused"), m_engine->paused()},
        {QStringLiteral("rate"), m_engine->speed()},
    };
    if (withMedia && !m_engine->idle() && !m_engine->path().isEmpty())
        body.insert(QStringLiteral("media"), partyMediaJson());
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/update")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        // Hub forgot us (its restart, or the stale-party reap after we crashed):
        // reflect reality so the overlay doesn't claim a dead party.
        if (m_partyHosting && o.contains(QStringLiteral("ok"))
            && !o.value(QStringLiteral("ok")).toBool()) {
            Logger::log(QStringLiteral("party"),
                        QStringLiteral("hub dropped the party — stopping"));
            endWatchParty();
        }
    });
}

void AppController::partyPublishCast()
{
    // #218: the DV host keeps its own DV cast and can't chase the room like a
    // reloaded follower, so it PINS the room clock to its REAL cast position on the
    // publish timer. This is the load-bearing sync piece: it pulls the room back to
    // the host's true frame after a seek's DV re-warm, and it keeps the room "warm"
    // (bumps `updated`) before any follower has joined. Hub-mode /party/update
    // accepts this token-authenticated position pin; media stays hub/cmd-owned.
    if (!m_partyViaCast || m_partyToken.isEmpty())
        return;
    // Batch2 #3: a wedged/recovering receiver reports state IDLE at position ~0.
    // Publishing that as the room clock pins everyone to 0 (Bug B's last link).
    // The receiver has no authoritative position while IDLE — don't pin. (The hub
    // §C guard also drops a <2s pin when the room is >30s; refusing here stops the
    // doomed POST at the source and covers the room-clock-<30s window too.)
    if (m_cast->castState() == QLatin1String("IDLE"))
        return;
    // seek-fight belt: during the post-seek DV re-warm, castPosition() is the stale
    // pre-seek value. Don't pin it — wait until the cast has crossed the seeked
    // target (within 2s) or the hold window elapses, then resume pinning.
    if (m_castPublishHoldUntil > 0) {
        const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
        const bool reached = m_castPublishTarget < 0
            || qAbs(m_cast->castPosition() - m_castPublishTarget) < 2.0;
        if (nowMs < m_castPublishHoldUntil && !reached)
            return;
        if (!reached) {
            // Hold expired but the DV re-warm still hasn't reached the target:
            // castPosition() is STILL the stale pre-seek frame. NEVER pin that —
            // keep suppressing (castRecoverTimer rebuilds a truly-wedged lane). (#5)
            m_castPublishHoldUntil = nowMs + 2000;
            return;
        }
        m_castPublishHoldUntil = 0;
        m_castPublishTarget = -1;
    }
    QJsonObject body{
        {QStringLiteral("token"), m_partyToken},
        {QStringLiteral("pos"), m_cast->castPosition()},
        {QStringLiteral("paused"), m_cast->castState() != QLatin1String("PLAYING")},
        {QStringLiteral("rate"), m_cast->castRate()},
    };
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/update")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        // Hub forgot us (restart / stale-party reap): stop claiming a dead party.
        if (m_partyViaCast && o.contains(QStringLiteral("ok"))
            && !o.value(QStringLiteral("ok")).toBool()) {
            Logger::log(QStringLiteral("party"),
                        QStringLiteral("hub dropped the party — stopping"));
            endWatchParty();
        }
    });
}

// Ask the hub what's running — always, not only when we started it. This is
// what makes opening codec anywhere show the movie already playing in the
// living room, and what lets any screen join or end it.
void AppController::partyPoll()
{
    // "…?cs=N" — hand back only the talk we haven't seen. A screen that has
    // been open all night carries none of it on the wire.
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/party/status?cs=")
                             + QString::number(m_partyChatSeq)
                             + QStringLiteral("&dev=") + m_partyGuestId));
    req.setTransferTimeout(4000);
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        const bool bad = r->error() != QNetworkReply::NoError;
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        if (bad)
            return;  // hub asleep or restarting; keep the last known picture
        partyApplyStatus(o);
    });
}

void AppController::partyApplyStatus(const QJsonObject &o)
{
    const bool live = o.value(QStringLiteral("active")).toBool();
    m_partyStatusSeq = o.value(QStringLiteral("seq")).toInt(-1);
    const QString token = o.value(QStringLiteral("token")).toString();
    const bool wasIn = m_partyHosting || m_partyFollowing || m_partyViaCast;
    // A different token means our session ended and another began — we are not
    // in that one, whatever we used to think.
    if (wasIn && (!live || (!m_partyToken.isEmpty() && token != m_partyToken))) {
        m_partyHosting = m_partyFollowing = m_partyViaCast = false;
        m_partyFollowTimer.stop();
        m_partyPublishTimer.stop();
        m_engine->resetSpeed();
        Logger::log(QStringLiteral("party"), QStringLiteral("session gone"));
        emit toast(QStringLiteral("WATCH PARTY ENDED"));
    }
    m_partyLive = live;
    // ⚠ BEFORE the no-party return below, not after the party parsing. This
    // sits in the same reply as the party, but it is needed in exactly the
    // case the party code gives up on — no session running. Applied at the
    // bottom of this function it rendered nothing, ever, with no error.
    nowApply(o.value(QStringLiteral("now")).toArray());
    if (!live) {
        m_partyToken.clear();
        m_partyTitle.clear();
        m_partyKey.clear();
        m_partyWho.clear();
        m_partyPeers = 0;
        // A new room starts a new conversation. Keeping the old transcript
        // would put last night's talk under tonight's film.
        if (!m_partyChat.isEmpty()) {
            m_partyChat.clear();
            emit partyChatChanged();
        }
        m_partyChatSeq = 0;
        emit partyChanged();
        return;
    }
    m_partyToken = token;
    m_partyTitle = o.value(QStringLiteral("title")).toString();
    m_partyMode = o.value(QStringLiteral("mode")).toString();
    m_partyKey = o.value(QStringLiteral("key")).toString();
    m_partyDur = o.value(QStringLiteral("dur")).toDouble();
    m_partyPeers = o.value(QStringLiteral("peers")).toInt();
    m_partyInviteUrl = o.value(QStringLiteral("inviteUrl")).toString();
    m_partyReceiverUrl = o.value(QStringLiteral("receiverUrl")).toString();
    m_partyWho.clear();
    const QJsonArray who = o.value(QStringLiteral("who")).toArray();
    for (const QJsonValue &v : who)
        m_partyWho << v.toString();
    // The same roster the web player shows: a row per viewer with the round
    // trip they reported, so the overlay can colour a dot instead of printing
    // a comma-separated list that says nothing about who's struggling.
    // Talk first: a line that arrived in the same poll as the session ending
    // should still be shown, and the roster below can clear it out.
    const QJsonArray chat = o.value(QStringLiteral("chat")).toArray();
    if (!chat.isEmpty()) {
        for (const QJsonValue &v : chat) {
            const QJsonObject e = v.toObject();
            // once each: two overlapping polls with the same `cs` both carry a
            // new line, and it was appended (and toasted) twice
            const int ei = e.value(QStringLiteral("i")).toInt(0);
            if (ei > 0 && ei <= m_partyChatSeq)
                continue;
            const QString who = e.value(QStringLiteral("who")).toString();
            const QString text = e.value(QStringLiteral("text")).toString();
            const QString kind = e.value(QStringLiteral("kind")).toString();
            m_partyChat.append(QVariantMap{
                {QStringLiteral("who"), who},
                {QStringLiteral("text"), text},
                {QStringLiteral("kind"), kind},
                {QStringLiteral("t"), e.value(QStringLiteral("t")).toDouble()}});
            emit partyChatLine(who, text, kind);
        }
        while (m_partyChat.size() > 60)
            m_partyChat.removeFirst();
        emit partyChatChanged();
    }
    if (o.contains(QStringLiteral("chatSeq")))
        m_partyChatSeq = o.value(QStringLiteral("chatSeq")).toInt();
    const QJsonObject vote = o.value(QStringLiteral("vote")).toObject();
    m_partyVotes = vote.value(QStringLiteral("n")).toInt();
    m_partyVotesNeed = qMax(1, vote.value(QStringLiteral("need")).toInt(1));

    m_partyAsks.clear();
    for (const QJsonValue &v : o.value(QStringLiteral("asks")).toArray()) {
        const QJsonObject a = v.toObject();
        m_partyAsks.append(QVariantMap{
            {QStringLiteral("id"), a.value(QStringLiteral("id")).toString()},
            {QStringLiteral("name"), a.value(QStringLiteral("name")).toString()}});
    }
    m_partyRoom.clear();
    const QJsonArray room = o.value(QStringLiteral("room")).toArray();
    for (const QJsonValue &v : room) {
        const QJsonObject e = v.toObject();
        // The hub marks our own row ("me"); ids are opaque tags now, so the
        // id match only serves a hub from before that change.
        const bool mine = e.value(QStringLiteral("me")).toBool()
                          || e.value(QStringLiteral("id")).toString() == m_partyGuestId;
        m_partyRoom.append(QVariantMap{
            {QStringLiteral("name"), e.value(QStringLiteral("name")).toString()},
            // Our own number is measured here and is fresher than the copy the
            // hub is holding.
            {QStringLiteral("rtt"), mine && m_partyRttMs >= 0
                                        ? m_partyRttMs
                                        : e.value(QStringLiteral("rtt")).toInt(-1)},
            {QStringLiteral("watching"), e.value(QStringLiteral("w")).toBool(true)},
            {QStringLiteral("me"), mine},
            // What THIS screen says it needs, which is what the room meter
            // plots — the room's number is the worst of these.
            {QStringLiteral("cushion"), e.value(QStringLiteral("cu")).toDouble(-1)},
            // Seats (the hub's "Seats"): seated / joining / away / card, how
            // far into earning a seat, how far behind the clock — and the id
            // DROP takes (this poll is LAN-only, so the raw id is fine here).
            {QStringLiteral("id"), e.value(QStringLiteral("id")).toString()},
            {QStringLiteral("state"), e.value(QStringLiteral("st")).toString()},
            {QStringLiteral("earn"), e.value(QStringLiteral("earn")).toDouble(0)},
            {QStringLiteral("behind"), e.value(QStringLiteral("behind")).toVariant()},
            {QStringLiteral("lan"), e.value(QStringLiteral("lan")).toBool()},
            {QStringLiteral("tv"), e.value(QStringLiteral("tv")).toBool()},
        });
    }
    m_partyLocked = o.value(QStringLiteral("locked")).toBool();
    // The room's cushion and who set it — visible even before we join, so the
    // overlay can explain a room that's deliberately running a few seconds back
    // rather than leaving it looking like a fault.
    m_partyRoomLagMs = o.value(QStringLiteral("roomLagMs")).toInt(-1);
    m_partyLagWho = o.value(QStringLiteral("lagWho")).toString();
    m_partyWaitingFor.clear();
    for (const QJsonValue &w : o.value(QStringLiteral("waitingFor")).toArray())
        m_partyWaitingFor << w.toString();
    m_partyLoading = o.value(QStringLiteral("loading")).toBool();
    m_partyNext = o.value(QStringLiteral("next")).toString();
    // While following, partyFollow owns the clock (it polls faster and carries
    // our presence id); don't fight it with a staler reading.
    if (!m_partyFollowing) {
        m_partyClockPos = o.value(QStringLiteral("pos")).toDouble();
        m_partyPaused = o.value(QStringLiteral("paused")).toBool();
        m_partyRate = o.value(QStringLiteral("rate")).toDouble(1.0);
        const qint64 serverNow = qint64(o.value(QStringLiteral("serverNowMs")).toDouble());
        m_partySkewMs = serverNow - QDateTime::currentMSecsSinceEpoch();
        // /party/status's `pos` is ALREADY projected to now (serverNowMs);
        // pairing it with the room's epochMs (the last command) counted the
        // time since then twice — over an hour after a long stretch with no
        // seek, so a join loaded the film at its very end (clamped), it ended
        // at once and closed the player, and the panel's clock read the
        // film's length. The position belongs to the status's own moment.
        const qint64 roomEpoch = qint64(o.value(QStringLiteral("epochMs")).toDouble());
        m_partyEpochMs = (roomEpoch > serverNow) ? roomEpoch   // a scheduled start still ahead
                                                 : serverNow;
    }
    emit partyChanged();
}

void AppController::castQueuePoll()
{
    // Always-on: the shared queue is THE queue, casting or not.
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/castqueue")));
    req.setTransferTimeout(4000);
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        if (r->error() != QNetworkReply::NoError) {
            r->deleteLater();
            return; // hub away — keep the local queue, try again in 5s
        }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        const int rev = o.value(QStringLiteral("rev")).toInt();
        if (rev == 0 || rev == m_castqRev)
            return;
        // Local edits from the last moments win until their push lands.
        if (QDateTime::currentMSecsSinceEpoch() - m_castqLastEdit < 3000)
            return;
        // Edits made while the hub was unreachable are NEWER than the hub's
        // copy: reclaim the revision instead of adopting, or queueing done
        // offline would be silently thrown away on reconnect.
        if (m_castqLastEdit > 0
            && double(m_castqLastEdit)
                   > o.value(QStringLiteral("updated")).toDouble() * 1000.0) {
            castQueuePush();
            return;
        }
        m_castqRev = rev;
        QVariantList items;
        const QJsonArray arr = o.value(QStringLiteral("items")).toArray();
        for (const QJsonValue &v : arr)
            items.append(localizedQueueItem(v.toObject().toVariantMap()));
        m_adoptingQueue = true;
        m_queue->replaceAll(items);
        m_adoptingQueue = false;
        Logger::log(QStringLiteral("queue"),
                    QStringLiteral("adopted hub queue rev %1 (%2 items)")
                        .arg(rev).arg(m_queue->count()));
    });
}

void AppController::rcPoll()
{
    // Physical-TV-remote (Phase 2). Only while a cast is live — no target, no
    // remote to drive. Drain the hub's per-device /rc queue (keyed by the cast
    // device uuid, which is our m_cast->targetId()) and fire each key's method.
    const QString dev = m_cast->targetId();
    if (dev.isEmpty())
        return;
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/rc?dev=")
                             + QString::fromUtf8(QUrl::toPercentEncoding(dev))));
    req.setTransferTimeout(2000);
    QNetworkReply *r = m_nam->get(req);
    connect(r, &QNetworkReply::finished, this, [this, r] {
        if (r->error() != QNetworkReply::NoError) {
            r->deleteLater();
            return; // hub away — try again next tick
        }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        const QJsonArray ops = o.value(QStringLiteral("ops")).toArray();
        for (const QJsonValue &v : ops) {
            const QString op = v.toObject().value(QStringLiteral("op")).toString();
            if (op == QLatin1String("audio"))          castCycleAudio();
            else if (op == QLatin1String("sub"))       castToggleSub();
            else if (op == QLatin1String("sub_cycle")) castCycleSub();
            else if (op == QLatin1String("chan_next")) castNext();
            else if (op == QLatin1String("chan_prev")) castPrev();
            else if (op == QLatin1String("stop"))      stopPlayback();
            else if (op == QLatin1String("zoom"))      castCycleScreenMode();
            // the Sony remote answering the UP NEXT card on the TV (receiver sends
            // these only while the card is up): OK = now, Back = watch the credits
            else if (op == QLatin1String("credits_go"))     castCreditsGo();
            else if (op == QLatin1String("credits_cancel")) castCreditsCancel();
            else if (op == QLatin1String("seek")) {
                // #6: physical-remote seek on a DV-cast party HOST. The receiver
                // already re-warmed its own TV to the target; we only AUTHOR the
                // room so followers + the room clock follow it (and the server's
                // post-cmd cooldown then swallows the stale re-warm position pins
                // partyPublishCast is about to send). Deliberately NO m_cast->seek
                // — a second cast seek would fight the receiver's in-flight
                // re-warm. Off-party this no-ops (the receiver handled it locally).
                const double tgt = v.toObject().value(QStringLiteral("arg")).toDouble(-1.0);
                if (tgt >= 0.0 && partyDriving())
                    partyCmd(QStringLiteral("seek"), tgt);
            }
            // unknown op: ignore
        }
    });
}

QVariantMap AppController::localizedQueueItem(QVariantMap it) const
{
    // Queue items travel with the uri of the device that queued them —
    // /mnt/… on the hub, http://hub:8200/… on a satellite. ResumeStore's
    // canonical key is the shared identity; rebuild a playable uri from it.
    const QString uri = it.value(QStringLiteral("uri")).toString();
    if (uri.isEmpty() || uri.contains(QLatin1String("youtube.com"))
        || uri.contains(QLatin1String("youtu.be")) || !m_store)
        return it;
    const QString key = m_store->mediaKey(uri);
    if (key.isEmpty() || key.startsWith(QLatin1String("yt:")))
        return it;
    const QString root = m_store->serveRoot();
    if (m_library->remoteMode()) {
        // Satellite: anything hub-rooted plays as a hub stream.
        if (uri.startsWith(root + QLatin1Char('/'))
            || uri.startsWith(QLatin1String("http"))) {
            it.insert(QStringLiteral("uri"),
                      hubBase() + QLatin1Char('/')
                          + QString::fromUtf8(QUrl::toPercentEncoding(key, "/")));
        }
    } else if (uri.startsWith(QLatin1String("http"))) {
        // Hub: prefer the local file the URL points at, when it exists.
        const QString local = root + QLatin1Char('/') + key;
        if (QFile::exists(local))
            it.insert(QStringLiteral("uri"), local);
    }
    const QString art = it.value(QStringLiteral("artUrl")).toString();
    if (art.startsWith(QLatin1Char('/')) && !QFile::exists(art))
        it.insert(QStringLiteral("artUrl"),
                  hubBase() + QStringLiteral("/art?f=")
                      + QFileInfo(art).fileName());
    return it;
}

QVariantMap AppController::queueItemForPath(const QString &path) const
{
    QString p = path;
    if (p.startsWith(QStringLiteral("file://")))
        p = QUrl(p).toLocalFile();
    QVariantMap it;
    it.insert(QStringLiteral("uri"), p);
    // Enrich from the library when codec already knows this file — real title,
    // poster art, movie/tv kind. Otherwise fall back to a readable filename.
    const QVariantMap info = m_library ? m_library->entryInfo(p) : QVariantMap();
    if (!info.isEmpty()) {
        it.insert(QStringLiteral("title"), info.value(QStringLiteral("title")));
        it.insert(QStringLiteral("subtitle"), info.value(QStringLiteral("subtitle")));
        it.insert(QStringLiteral("kind"), info.value(QStringLiteral("kind")));
        const QString poster = info.value(QStringLiteral("poster")).toString();
        if (!poster.isEmpty())
            it.insert(QStringLiteral("artUrl"), poster);
    } else {
        it.insert(QStringLiteral("title"), Library::prettyTitle(p));
        it.insert(QStringLiteral("kind"), QStringLiteral("file"));
    }
    return it;
}

// VLC "Add to Playlist": append dropped files to the queue without touching
// what's playing. Opens the queue sidebar so the add is visible.
void AppController::enqueuePaths(const QStringList &paths)
{
    int added = 0;
    for (const QString &raw : paths) {
        if (raw.trimmed().isEmpty())
            continue;
        m_queue->add(localizedQueueItem(queueItemForPath(raw)));
        ++added;
    }
    if (added <= 0)
        return;
    Logger::log(QStringLiteral("queue"),
                QStringLiteral("enqueue %1 file(s) via IPC").arg(added));
    setQueueOpen(true);
}

// VLC "Open": play the first file now, queue the rest, and bring codec forward.
void AppController::playPaths(const QStringList &paths)
{
    if (paths.isEmpty())
        return;
    QString first = paths.first();
    if (first.startsWith(QStringLiteral("file://")))
        first = QUrl(first).toLocalFile();
    for (int i = 1; i < paths.size(); ++i)
        m_queue->add(localizedQueueItem(queueItemForPath(paths.at(i))));
    presentWindow();
    play(first);
}

void AppController::presentWindow()
{
    if (!m_window)
        return;
    m_window->raise();
    m_window->requestActivate();
}

void AppController::frontWindow()
{
    if (!m_window || qEnvironmentVariableIsSet("CODEC_SHOT"))
        return;
    // Focusing our window warps the pointer to its middle — but a bare warp
    // doesn't tell us the pointer arrived, so the hidden cursor can't apply
    // and the arrow sat mid-film until the mouse was touched. A cursor move
    // to the same spot does hand us the pointer. Neither is a person moving
    // the mouse: the cursor stays hidden and the OSD stays down.
    m_pointerHushUntil = QDateTime::currentMSecsSinceEpoch() + 2000;
    m_cursorTimer.stop();
    hideCursor();
    const qint64 pid = QCoreApplication::applicationPid();
    auto *focus = new QProcess(this);
    connect(focus, &QProcess::errorOccurred, focus, &QObject::deleteLater);
    connect(focus, &QProcess::finished, this, [this, focus, pid] {
        focus->deleteLater();
        auto *q = new QProcess(this);
        connect(q, &QProcess::errorOccurred, q, &QObject::deleteLater);
        connect(q, &QProcess::finished, this, [this, q, pid] {
            const QJsonArray arr = QJsonDocument::fromJson(q->readAllStandardOutput()).array();
            q->deleteLater();
            for (const QJsonValue &v : arr) {
                const QJsonObject w = v.toObject();
                if (w.value(QStringLiteral("pid")).toInteger() != pid)
                    continue;
                const QJsonArray at = w.value(QStringLiteral("at")).toArray();
                const QJsonArray size = w.value(QStringLiteral("size")).toArray();
                const int x = at.at(0).toInt() + size.at(0).toInt() / 2;
                const int y = at.at(1).toInt() + size.at(1).toInt() / 2;
                m_pointerHushUntil = QDateTime::currentMSecsSinceEpoch() + 1500;
                QProcess::startDetached(QStringLiteral("hyprctl"),
                    {QStringLiteral("dispatch"),
                     QStringLiteral("hl.dsp.cursor.move({ x = %1, y = %2 })").arg(x).arg(y)});
                break;
            }
        });
        q->start(QStringLiteral("hyprctl"), {QStringLiteral("clients"), QStringLiteral("-j")});
    });
    focus->start(QStringLiteral("hyprctl"),
        {QStringLiteral("dispatch"),
         QStringLiteral("hl.dsp.focus({ window = \"pid:%1\" })").arg(pid)});
}

// A rebuilt surface (HDR on/off recreates the window) sits under a pointer that
// hasn't moved, and Hyprland only tells a surface the pointer is over it when
// the pointer moves — so the cursor the player had just hidden couldn't apply
// to the new window and the arrow sat over the film until the mouse was
// touched (the author 2026-10-16, every HDR title: the player hides it, HDR engages
// 0.3 s later and rebuilds the window). Move the cursor to where it already is
// once the new surface and the panel's mode change have landed — frontWindow's
// proven trick: that hands us the pointer, and the Enter re-pushes the blank
// cursor. The motion it makes is hushed. Only while the cursor SHOULD be
// hidden: a visible one shows the default arrow anyway, and a hush would eat a
// real mouse's moves.
void AppController::rehandPointer()
{
    if (qEnvironmentVariableIsSet("CODEC_SHOT"))
        return;
    for (const int ms : {700, 1600}) {   // the monitor's mode set is async: twice
        QTimer::singleShot(ms, this, [this] {
            if (!m_cursorHidden)
                return;
            auto *q = new QProcess(this);
            connect(q, &QProcess::errorOccurred, q, &QObject::deleteLater);
            connect(q, &QProcess::finished, this, [this, q] {
                const QJsonObject p = QJsonDocument::fromJson(q->readAllStandardOutput()).object();
                q->deleteLater();
                if (!m_cursorHidden || !p.contains(QStringLiteral("x")))
                    return;
                m_pointerHushUntil = QDateTime::currentMSecsSinceEpoch() + 800;
                QProcess::startDetached(QStringLiteral("hyprctl"),
                    {QStringLiteral("dispatch"),
                     QStringLiteral("hl.dsp.cursor.move({ x = %1, y = %2 })")
                         .arg(p.value(QStringLiteral("x")).toInt())
                         .arg(p.value(QStringLiteral("y")).toInt())});
            });
            q->start(QStringLiteral("hyprctl"), {QStringLiteral("cursorpos"), QStringLiteral("-j")});
        });
    }
}

void AppController::screenshot()
{
    if (!m_engine || m_engine->idle() || m_engine->path().isEmpty())
        return; // nothing playing to grab
    const QString dir =
        QStandardPaths::writableLocation(QStandardPaths::PicturesLocation)
        + QStringLiteral("/codec");
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/codec-")
        + QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd-HHmmss-zzz"))
        + QStringLiteral(".png");
    // The video item lives in Main.qml; QML does the actual grabToImage + save.
    emit grabFrame(path);
}

void AppController::pullLibrary()
{
    // Satellite: ask the hub for the current manifest + any art we lack
    // (codec_pull_library.py), then reload. Inverts the old push-only rsync
    // whose freshness depended on this machine being awake when the hub
    // pushed — ghosts of deleted files, missing new ones, stale URLs.
    if (!m_library->remoteMode())
        return;
    const QString script = codecScript(QStringLiteral("codec_pull_library.py"));
    if (!QFile::exists(script))
        return;
    if (m_libPullInFlight) // don't stack overlapping pulls
        return;
    m_libPullInFlight = true;
    auto *p = new QProcess(this);
    connect(p, &QProcess::errorOccurred, this, [this, p] {
        m_libPullInFlight = false;
        p->deleteLater();
    });
    connect(p, &QProcess::finished, this,
            [this, p](int rc, QProcess::ExitStatus) {
        m_libPullInFlight = false;
        p->deleteLater();
        if (rc == 0) { // manifest changed (2 = hub away, 3 = already current)
            Logger::log(QStringLiteral("library"),
                        QStringLiteral("hub manifest updated — reloading"));
            m_library->rescan();
            emit toast(QStringLiteral("LIBRARY SYNCED FROM HUB"));
        }
    });
    p->start(QStringLiteral("/usr/bin/python3"), {script});
}

void AppController::castPrev()
{
    const QString uri = m_cast->currentUri();
    if (uri.isEmpty())
        return;
    // Standard remote semantics: deep into playback restarts the current
    // item; near the start it jumps back an episode when one exists.
    if (m_cast->castPosition() > 10) {
        m_cast->seek(0);
        emit toast(QStringLiteral("RESTART"));
        return;
    }
    const QVariantMap ep = m_library->prevEpisode(uri);
    if (ep.isEmpty()) {
        m_cast->seek(0);
        return;
    }
    castPlay(QVariantMap{
        {QStringLiteral("uri"), ep.value(QStringLiteral("path"))},
        {QStringLiteral("title"),
         ep.value(QStringLiteral("show")).toString() + QStringLiteral("  ")
             + ep.value(QStringLiteral("title")).toString()},
    });
}

void AppController::ytDownload(const QString &videoId, const QString &title)
{
    Logger::log(QStringLiteral("ytdl"), videoId + QStringLiteral(" ") + title);
    QNetworkRequest req(QUrl(hubBase() + QStringLiteral("/ytdl")));
    req.setHeader(QNetworkRequest::ContentTypeHeader,
                  QStringLiteral("application/json"));
    QNetworkReply *r = m_nam->post(req, QJsonDocument(QJsonObject{
        {QStringLiteral("videoId"), videoId}}).toJson(QJsonDocument::Compact));
    connect(r, &QNetworkReply::finished, this, [this, r, title] {
        const bool ok = QJsonDocument::fromJson(r->readAll()).object()
                            .value(QStringLiteral("ok")).toBool();
        emit toast(ok ? QStringLiteral("DOWNLOADING TO LIBRARY · %1")
                            .arg(title.toUpper())
                      : QStringLiteral("DOWNLOAD FAILED — HUB UNREACHABLE?"));
        r->deleteLater();
    });
}

bool AppController::hdrDirect() const
{
    return m_settings.value(QStringLiteral("hdrDirect"), false).toBool();
}

void AppController::toggleHdrDirect()
{
    saveSetting(QStringLiteral("hdrDirect"), !hdrDirect());
    emit hdrDirectChanged();
    emit toast(hdrDirect() ? QStringLiteral("HDR OUTPUT ▸ ON")
                           : QStringLiteral("HDR OUTPUT ▸ OFF"));
    updateHdrEngaged(); // toggling mid-HDR-playback takes effect live
}

void AppController::setMonitorHdr(bool on, bool blocking)
{
    // The panel enters HDR ONLY while an HDR file plays: rebuild the monitor
    // line from live state and set bitdepth+cm. Restored on disengage AND app
    // quit (mod+q) so the desktop never sticks in HDR. `hyprctl keyword` is
    // refused under a Lua config ("non-legacy parsers") — this must go through
    // `hyprctl eval` + the hl.monitor DSL, and the restore must set bitdepth/cm
    // EXPLICITLY: omitted keys keep their previous values (verified live).
    //
    // Async by default: the old synchronous waits (3.5s+ of hyprctl per flip)
    // stacked into UI freezes when skipping through mixed HDR/SDR queues.
    // `blocking` exists for quit(), where the event loop is about to die and
    // the restore MUST land before the process exits.
    // Newest request wins: quick player enter/leave overlaps two async chains,
    // and the ENGAGE chain landing after the disengage stuck the desktop in
    // HDR while browsing the PiP. Stale chains bail at every async seam.
    const int seq = ++m_monitorHdrSeq;
    // The panel named NOW: moving screens hands the old one back out of HDR
    // and changes m_display before this answer lands.
    const QString disp = m_display;
    auto *mon = new QProcess(this);
    connect(mon, &QProcess::errorOccurred, mon, &QObject::deleteLater);
    connect(mon, &QProcess::finished, this, [this, mon, on, blocking, seq, disp] {
        const QJsonArray arr = QJsonDocument::fromJson(
            mon->readAllStandardOutput()).array();
        mon->deleteLater();
        if (seq != m_monitorHdrSeq)
            return;
        for (const QJsonValue &v : arr) {
            const QJsonObject m = v.toObject();
            if (m.value(QStringLiteral("name")).toString() != disp)
                continue;
            const QString mode = QStringLiteral("%1x%2@%3")
                .arg(m.value(QStringLiteral("width")).toInt())
                .arg(m.value(QStringLiteral("height")).toInt())
                .arg(qRound(m.value(QStringLiteral("refreshRate")).toDouble()));
            const QString pos = QStringLiteral("%1x%2")
                .arg(m.value(QStringLiteral("x")).toInt())
                .arg(m.value(QStringLiteral("y")).toInt());
            const double scale = m.value(QStringLiteral("scale")).toDouble();
            const QString lua = QStringLiteral(
                "hl.monitor({ output = \"%1\", mode = \"%2\", position = \"%3\", "
                "scale = %4, bitdepth = %5, cm = \"%6\" })")
                .arg(disp, mode, pos)
                .arg(scale)
                .arg(on ? 10 : 8)
                .arg(on ? QStringLiteral("hdr") : QStringLiteral("srgb"));
            Logger::log(QStringLiteral("hdr"),
                        QStringLiteral("monitor %1").arg(lua));
            // Legacy (non-Lua) Hyprland config fallback: the classic keyword
            // line, fire-and-forget (execute() had NO timeout — an unbounded
            // GUI-thread block if hyprctl ever hung).
            const QString fallback = QStringLiteral("%1,%2,%3,%4%5")
                .arg(disp, mode, pos)
                .arg(scale)
                .arg(on ? QStringLiteral(",bitdepth,10,cm,hdr") : QString());
            auto *ev = new QProcess(this);
            connect(ev, &QProcess::errorOccurred, ev, &QObject::deleteLater);
            connect(ev, &QProcess::finished, this, [this, ev, fallback, seq] {
                if (seq == m_monitorHdrSeq
                    && ev->readAllStandardOutput().trimmed() != "ok")
                    QProcess::startDetached(QStringLiteral("hyprctl"),
                                            {QStringLiteral("keyword"),
                                             QStringLiteral("monitor"), fallback});
                ev->deleteLater();
            });
            ev->start(QStringLiteral("hyprctl"), {QStringLiteral("eval"), lua});
            if (blocking)
                ev->waitForFinished(2000);
            m_monitorHdrOn = on;
            break;
        }
    });
    mon->start(QStringLiteral("hyprctl"), {QStringLiteral("monitors"),
                                           QStringLiteral("-j")});
    if (blocking)
        mon->waitForFinished(1500);
}

void AppController::probeDisplayHdr()
{
    // EDID of the chosen connector: CTA-861 extension → HDR Static Metadata
    // data block (extended tag 6) with the ST2084 bit = the panel takes HDR10.
    m_displayHdrCapable = false;
    const QStringList matches = QDir(QStringLiteral("/sys/class/drm"))
        .entryList({QStringLiteral("card?-") + m_display}, QDir::Dirs);
    if (!matches.isEmpty()) {
        QFile f(QStringLiteral("/sys/class/drm/") + matches.first()
                + QStringLiteral("/edid"));
        if (f.open(QIODevice::ReadOnly)) {
            const QByteArray edid = f.readAll();
            for (int b = 128; b + 128 <= edid.size(); b += 128) {
                if (quint8(edid[b]) != 0x02) // not a CTA-861 block
                    continue;
                const int dtd = quint8(edid[b + 2]);
                int i = b + 4;
                const int end = b + (dtd > 4 ? dtd : 127);
                while (i < end && i + 2 < b + 128) {
                    const int tag = quint8(edid[i]) >> 5;
                    const int len = quint8(edid[i]) & 0x1f;
                    if (tag == 7 && len >= 2 && quint8(edid[i + 1]) == 0x06
                        && (quint8(edid[i + 2]) & 0x04)) {
                        m_displayHdrCapable = true;
                        // Same block, byte 4: desired content max luminance,
                        // coded L = 50·2^(code/32) — the panel's own peak,
                        // used when hdrPeakNits is AUTO.
                        if (len >= 4 && quint8(edid[i + 4]) > 0)
                            m_edidPeakNits = qRound(
                                50.0 * std::pow(2.0, quint8(edid[i + 4]) / 32.0));
                    }
                    i += len + 1;
                }
            }
        }
    }
    Logger::log(QStringLiteral("hdr"), QStringLiteral("display %1 hdr-capable=%2 edid-peak=%3")
                                           .arg(m_display)
                                           .arg(m_displayHdrCapable)
                                           .arg(m_edidPeakNits));
    emit hdrPeakChanged(); // AUTO label can now show the panel's real number
}

void AppController::recreateWindow(bool pq)
{
    // A Wayland surface's color description is fixed at creation, so flipping
    // colorspace = recreate the platform window in place. The new surface
    // inherits our workspace, so no re-placement dispatch.
    if (!m_window)
        return;
    m_window->destroy();
    // Start from the format Qt gave us at startup and change ONLY the
    // colorspace. A default-constructed QSurfaceFormat requests no depth or
    // stencil buffer, and Qt Quick draws opaque nodes — every Image — in a
    // depth-tested pass while text and translucent nodes go through the
    // blended pass. Rebuilding the window with a bare format therefore lost
    // exactly the art while leaving text looking fine.
    QSurfaceFormat f = m_baseFormat;
    f.setColorSpace(pq ? QColorSpace(QColorSpace::Bt2100Pq) : QColorSpace());
    m_window->setFormat(f);
    m_window->showFullScreen();
}

bool AppController::hdrWanted() const
{
    auto *mpv = qobject_cast<MpvEngine *>(m_engine);
    return mpv && mpv->hdrContent() && hdrDirect() && m_displayHdrCapable
        && !m_cast->active() && m_mode == QLatin1String("hd")
        && m_stage == QLatin1String("player");
}

void AppController::updateHdrEngaged()
{
    // Debounced: hdrContent flaps on every loadfile (drops during the load,
    // returns when the new file's params land). Skipping through a queue of
    // HDR files used to disengage+re-engage per skip — each one a window
    // recreate + monitor mode set. Coalescing 300ms turns the burst into at
    // most one real transition, and steady states are untouched.
    if (hdrWanted() == m_hdrEngaged) {
        m_hdrDebounce.stop();
        return;
    }
    m_hdrDebounce.start();
}

void AppController::setHdrEngaged(bool on)
{
    if (on == m_hdrEngaged)
        return;
    m_hdrEngaged = on;
    // 0 = AUTO: the panel's EDID-advertised peak, 400 when it doesn't say.
    double peak = m_settings.value(QStringLiteral("hdrPeakNits"), 0).toDouble();
    if (peak <= 0)
        peak = m_edidPeakNits > 0 ? m_edidPeakNits : 400;
    peak = qBound(100.0, peak, 10000.0);
    Logger::log(QStringLiteral("hdr"),
                on ? QStringLiteral("engage peak=%1").arg(peak)
                   : QStringLiteral("disengage"));
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
        mpv->setHdrOutput(on, peak);
    recreateWindow(on);
    setMonitorHdr(on);
    rehandPointer();
    emit hdrEngagedChanged();
    emit toast(on ? QStringLiteral("HDR ▸ PQ PASSTHROUGH · %1 NITS").arg(peak)
                  : QStringLiteral("HDR ▸ OFF"));
}

void AppController::playerNext()
{
    const QString uri = m_engine->path();
    if (uri.isEmpty())
        return;
    maybeMarkWatched();
    advanceAfter(uri); // queue first, then episode chain — same authority
}

// SUBS when there are none: fetch — for the film CASTING when a cast is on
// (the TV learns the file with no lane restart), else the one playing here.
// A second press within a few seconds of "already here" REFETCHES: the
// next-best release, for a file whose text or timing turned out wrong. A new
// file is re-timed against the film's audio on the hub in the background;
// pollSubSync() waits for the verdict and re-reads a re-timed file.
void AppController::findSubtitles()
{
    const bool casting = castingNow();
    if (casting && m_cast->castIsYoutube()) {
        emit toast(QStringLiteral("CAPTIONS COME WITH THE VIDEO"));
        return;
    }
    const QString path = casting ? m_cast->currentUri()
                                 : playbackIdentity(m_engine->path());
    if (path.isEmpty() || ephemeralUri(path)) {
        emit toast(QStringLiteral("NO FILM PLAYING"));
        return;
    }
    if (m_subFindBusy) {
        emit toast(QStringLiteral("SEARCHING SUBTITLES…"));
        return;
    }
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const bool force = path == m_subFindArmPath && now - m_subFindArmAt < 8000;
    m_subFindArmPath.clear();
    findSubtitlesFor(path, casting, force);
}

void AppController::findSubtitlesFor(const QString &path, bool casting, bool force)
{
    Logger::log(QStringLiteral("subs"), (force ? QStringLiteral("refetch ") : QStringLiteral("find "))
                                         + (casting ? QStringLiteral("(cast) ") : QString()) + path);
    emit toast(force ? QStringLiteral("REFETCHING SUBTITLES…") : QStringLiteral("SEARCHING SUBTITLES…"));
    // the hub's finder: over a private road by path; over the public door by
    // the title's index (the answer names no path there)
    const bool viaRoad = !privateRoad() && publicRoad();
    QUrl u;
    if (viaRoad) {
        const QString pu = publicUrlFor(path, QStringLiteral("subfind"),
                                        force ? QStringLiteral("&force=1") : QString());
        if (pu.isEmpty()) {
            emit toast(QStringLiteral("NOT IN THE SYNCED LIBRARY · NO SUBTITLE SEARCH"));
            return;
        }
        u = QUrl(pu);
    } else if (privateRoad()) {
        u = QUrl(hubBase() + QStringLiteral("/subfind"));
        QUrlQuery q;
        q.addQueryItem(QStringLiteral("src"), QString::fromUtf8(QUrl::toPercentEncoding(path)));
        if (force)
            q.addQueryItem(QStringLiteral("force"), QStringLiteral("1"));
        u.setQuery(q);
    } else {
        emit toast(QStringLiteral("HUB AWAY · NO SUBTITLE SEARCH"));
        return;
    }
    QNetworkRequest rq(u);
    rq.setTransferTimeout(150000);   // two providers, a zip each — a slow one is still a fetch
    m_subFindBusy = true;
    QNetworkReply *r = m_nam->get(rq);
    connect(r, &QNetworkReply::finished, this, [this, r, path, casting, viaRoad] {
        m_subFindBusy = false;
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) {
            emit toast(QStringLiteral("SUBTITLE SEARCH FAILED · THE HUB DIDN'T ANSWER"));
            return;
        }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        if (!o.value(QStringLiteral("ok")).toBool()) {
            const QString err = o.value(QStringLiteral("error")).toString();
            emit toast(err.isEmpty() ? QStringLiteral("NO SUBTITLES FOUND") : err.toUpper());
            return;
        }
        const bool existing = o.value(QStringLiteral("existing")).toBool();
        const QString name = o.value(QStringLiteral("name")).toString().toUpper();
        if (existing) {   // a second press within 8 s fetches the next-best release
            m_subFindArmPath = path;
            m_subFindArmAt = QDateTime::currentMSecsSinceEpoch();
        }
        if (casting) {
            if (m_cast->currentUri() == path)
                m_cast->addSub(false);
        } else {
            // the hub saved the file beside the movie: a local file loads it
            // by path, hub-streamed playback as a sibling url, the public
            // door as the title's own sub handle
            QString sub = o.value(QStringLiteral("sub")).toString();
            if (viaRoad)
                sub = publicUrlFor(path, QStringLiteral("sub"), QStringLiteral("&t=-2"));
            else if (path.startsWith(QLatin1String("http")))
                sub = o.value(QStringLiteral("url")).toString();
            if (auto *mpv = qobject_cast<MpvEngine *>(m_engine);
                mpv && !sub.isEmpty() && playbackIdentity(m_engine->path()) == path) {
                mpv->addSubFile(sub, /*cached=*/true);   // never a duplicate track
                if (!existing)
                    mpv->reloadSubs();                    // a fresh file at a known name
            }
        }
        emit toast(existing ? QStringLiteral("SUBTITLES ON · PRESS AGAIN TO REFETCH")
                            : QStringLiteral("SUBTITLES ON · %1").arg(name));
        // a new file: the hub measures it against the audio now
        const QString sync = o.value(QStringLiteral("sync")).toObject()
                                 .value(QStringLiteral("state")).toString();
        if (sync == QLatin1String("queued") || sync == QLatin1String("running")) {
            m_subSyncPath = path;
            m_subSyncCast = casting;
            m_subSyncPolls = 0;
            m_subSyncTimer.start();
        }
    });
}

// After a fetch: the hub's timing verdict for the new file. A re-timed file
// is re-read where it plays (mpv's sub-reload; the TV via add_sub refresh)
// and the old nudge for this film is void.
void AppController::pollSubSync()
{
    if (++m_subSyncPolls > 72) {   // six minutes: a feature's measurement takes about two
        m_subSyncTimer.stop();
        return;
    }
    const QString path = m_subSyncPath;
    const bool viaRoad = !privateRoad() && publicRoad();
    QUrl u;
    if (viaRoad)
        u = QUrl(publicUrlFor(path, QStringLiteral("subsync"), QString()));
    else if (privateRoad()) {
        u = QUrl(hubBase() + QStringLiteral("/subsync"));
        QUrlQuery q;
        q.addQueryItem(QStringLiteral("src"), QString::fromUtf8(QUrl::toPercentEncoding(path)));
        u.setQuery(q);
    }
    if (u.isEmpty()) {
        m_subSyncTimer.stop();
        return;
    }
    QNetworkRequest rq(u);
    rq.setTransferTimeout(8000);
    QNetworkReply *r = m_nam->get(rq);
    connect(r, &QNetworkReply::finished, this, [this, r, path, casting = m_subSyncCast] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError || path != m_subSyncPath)
            return;
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        const QString st = o.value(QStringLiteral("state")).toString();
        if (st == QLatin1String("queued") || st == QLatin1String("running"))
            return;
        m_subSyncTimer.stop();
        if (st != QLatin1String("done"))
            return;
        const QString verdict = o.value(QStringLiteral("verdict")).toString();
        if (o.value(QStringLiteral("applied")).toBool()) {
            if (casting) {
                if (m_cast->currentUri() == path)
                    m_cast->addSub(true);
            } else if (auto *mpv = qobject_cast<MpvEngine *>(m_engine);
                       mpv && playbackIdentity(m_engine->path()) == path) {
                mpv->reloadSubs();
                m_subDelayQuiet = 0.0;
                mpv->setSubDelay(0.0);
            }
            if (m_store)
                m_store->saveSubDelay(path, 0.0);   // the file's clock moved
            emit toast(QStringLiteral("SUBTITLES RE-TIMED ▸ %1")
                           .arg(o.value(QStringLiteral("readout")).toString()));
        } else if (verdict == QLatin1String("keep")) {
            emit toast(QStringLiteral("SUBTITLES IN SYNC WITH THE AUDIO"));
        } else if (verdict == QLatin1String("suspect")) {
            emit toast(QStringLiteral("SUBTITLES MAY BE THE WRONG CUT · PRESS AGAIN TO REFETCH"));
            m_subFindArmPath = path;
            m_subFindArmAt = QDateTime::currentMSecsSinceEpoch();
        } else {
            emit toast(QStringLiteral("SUBTITLE TIMING UNCHECKED"));
        }
    });
}

void AppController::onSubDelayChanged()
{
    // mpv adds the 0.1 steps in binary: +0.3 then −0.3 is 1e-8, not 0
    const double d = std::round(m_engine->subDelay() * 100.0) / 100.0;
    if (qFuzzyCompare(d + 1.0, m_subDelayQuiet + 1.0)) {   // the restore at load
        m_subDelayQuiet = -999.0;
        return;
    }
    emit toast(qAbs(d) < 0.005 ? QStringLiteral("SUB DELAY ▸ 0")
                               : QStringLiteral("SUB DELAY ▸ %1%2 S")
                                     .arg(d > 0 ? QStringLiteral("+") : QStringLiteral("−"))
                                     .arg(qAbs(d), 0, 'f', 1));
    m_subDelaySave.start();
}

// Settings ▸ SUBTITLE TIMING: whether the hub re-times what it fetches, and
// the tally so far.
void AppController::probeSubTiming()
{
    auto set = [this](const QString &s) {
        if (s != m_subTimingStatus) {
            m_subTimingStatus = s;
            emit subTimingStatusChanged();
        }
    };
    if (!privateRoad()) {
        set(publicRoad() ? QStringLiteral("ON THE HUB · OVER THE PUBLIC DOOR")
                         : QStringLiteral("HUB AWAY"));
        return;
    }
    QNetworkRequest rq(QUrl(hubBase() + QStringLiteral("/subsync?status=1")));
    rq.setTransferTimeout(5000);
    QNetworkReply *r = m_nam->get(rq);
    connect(r, &QNetworkReply::finished, this, [this, r, set] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError) {
            set(QStringLiteral("THE HUB DIDN'T ANSWER"));
            return;
        }
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        if (!o.value(QStringLiteral("available")).toBool()) {
            set(QStringLiteral("NOT INSTALLED ON THE HUB"));
            return;
        }
        set(QStringLiteral("AUDIO-SYNCED · %1 OF %2 RE-TIMED")
                .arg(o.value(QStringLiteral("applied")).toInt())
                .arg(o.value(QStringLiteral("measured")).toInt()));
    });
}

void AppController::loadOcrSubtitle(int subIndex)
{
    loadOcrSubtitleTry(subIndex, 0);
}

void AppController::loadOcrSubtitleTry(int subIndex, int attempt)
{
    // The active sub is a bitmap (PGS/dvdsub). Ask the hub for its OCR'd text
    // (the same track the cast uses, pre-warmed by codec_ocrsweep). /subready
    // reports whether the VTT is cached (and warms it in the background if not);
    // once ready, sideload the /subs URL, which mpv selects and renders in our
    // MGS caption style — instead of the unstyleable burned-in bitmap.
    const QString path = m_engine->path();
    if (path.isEmpty() || ephemeralUri(path))
        return;
    // Build the query as a fully-encoded string directly: QUrlQuery + toString()
    // decodes %20 back to a literal space, yielding a broken URL (mpv then loaded
    // an empty track). Keep the path fully percent-encoded end to end.
    const QString qs = QStringLiteral("src=")
        + QString::fromUtf8(QUrl::toPercentEncoding(path))
        + QStringLiteral("&i=") + QString::number(subIndex);
    const QString readyUrl = hubBase() + QStringLiteral("/subready?") + qs;
    // ?srt=1 → the hub strips the WEBVTT header so mpv's SRT parser accepts the
    // OCR sub's comma timestamps (the WebVTT parser silently drops every cue).
    const QString subsUrl = hubBase() + QStringLiteral("/subs?") + qs + QStringLiteral("&srt=1");
    QNetworkReply *r = m_nam->get(QNetworkRequest(QUrl::fromEncoded(readyUrl.toUtf8())));
    connect(r, &QNetworkReply::finished, this, [this, r, path, subsUrl, subIndex, attempt] {
        const QJsonObject o = QJsonDocument::fromJson(r->readAll()).object();
        r->deleteLater();
        auto *mpv = qobject_cast<MpvEngine *>(m_engine);
        // Only while the SAME bitmap track of the SAME file is still on screen —
        // a late reply must never override a sub the viewer picked since.
        if (!mpv || m_engine->path() != path || mpv->activeBitmapSub() != subIndex)
            return;
        if (!o.value(QStringLiteral("ready")).toBool()) {
            // Not cached yet — the hub is OCR'ing it now (at idle disk
            // priority, behind this very playback). Look again shortly instead
            // of leaving the plain bitmap up for the whole film, which is what
            // a single ask did. ~15 min of checks, then the bitmap stays.
            if (attempt < 45)
                QTimer::singleShot(20000, this, [this, subIndex, attempt] {
                    loadOcrSubtitleTry(subIndex, attempt + 1);
                });
            return;
        }
        mpv->addOcrSubFile(subsUrl); // `cached`: reuses the track if already added
    });
}

void AppController::playerPrev()
{
    const QString uri = m_engine->path();
    if (uri.isEmpty())
        return;
    // Standard remote semantics (matches castPrev): deep into playback
    // restarts the current item; near the start it jumps back an episode.
    if (m_engine->position() > 10) {
        seekTo(0);   // party-aware (room clock / cast lane) — not a bare local seek
        emit toast(QStringLiteral("RESTART"));
        return;
    }
    const QVariantMap ep = m_library->prevEpisode(uri);
    if (ep.isEmpty()) {
        seekTo(0);
        return;
    }
    play(ep.value(QStringLiteral("path")).toString());
}

void AppController::autoplayGo()
{
    if (m_autoplayNext.isEmpty())
        return;
    const int chain = m_autoplayChain >= 3 ? 0 : m_autoplayChain;
    const QString next = m_autoplayNext;
    m_autoplayNext.clear();
    play(next);
    m_autoplayChain = chain + 1;
}

void AppController::autoplayCancel()
{
    m_autoplayNext.clear();
    m_autoplayChain = 0;
    leavePlayer();
}

// The credits began (codec_credits.py's start for this file): the episode counts
// as watched from here, and if something is next, offer it now instead of after
// the last frame. Only PEEKS at what's next — the queue is consumed by the same
// advanceAfter() end-of-file uses, and only once the viewer accepts.
void AppController::checkCredits()
{
    // Seeked back out of the credits (a peek at the end, an over-long seek, a
    // credits mark that landed mid-episode): the title is being WATCHED again.
    // The completed-path guard used to stay up for the rest of the load, so no
    // resume point or watch time was saved after it — the place was lost.
    if (m_creditsFired && m_creditsStart > 0 && !m_completedPath.isEmpty()
        && m_engine->path() == m_completedPath
        && m_engine->position() < m_creditsStart - 30) {
        m_completedPath.clear();
        m_creditsFired = false;      // they can fire again at the real credits
        m_creditsPath.clear();
    }
    if (m_creditsFired || m_creditsStart <= 0 || m_engine->position() < m_creditsStart)
        return;
    // Full player only, solo only: the PiP/browse case and the party/cast legs keep
    // their own end-of-file flow (a party room must advance as one).
    if (m_stage != QLatin1String("player") || m_cast->active() || m_partyLive
        || m_queue->repeatMode() == QueueModel::RepeatOne)
        return;
    m_creditsFired = true;
    const QString path = m_engine->path();
    if (ephemeralUri(path) || m_liveNow)
        return;
    // Bank the watch now — and flag the path so the credits' own periodic saves
    // don't write a resume point back over the completed row (endReached then
    // skips the second markCompleted).
    // the TITLE's row — not the warm lane's url, not the public door's
    const QString key = playbackIdentity(path);
    m_store->markCompleted(key);
    m_library->refreshResume();
    m_completedPath = path;     // the guards compare the engine's own path

    const QString title = peekNextTitle(key);
    if (title.isEmpty())
        return; // nothing next — the credits just play out
    m_creditsPath = key;
    Logger::log(QStringLiteral("credits"),
                QStringLiteral("UP NEXT at %1 s → %2").arg(m_creditsStart).arg(title));
    emit creditsUpNext(title, m_autoplayChain >= 3);
}

// What advanceAfter() WOULD play after `path`, without consuming the queue.
QString AppController::peekNextTitle(const QString &path) const
{
    if (m_queue->count() > 0)
        return m_queue->itemAt(0).value(QStringLiteral("title")).toString();
    if (autoplayNext()) {
        const QVariantMap ep = m_library->nextEpisode(path);
        if (!ep.isEmpty())
            return ep.value(QStringLiteral("show")).toString() + QStringLiteral("  ")
                   + ep.value(QStringLiteral("title")).toString();
    }
    return QString();
}

// Casting: the same end-credits moment, read off the TV's reported position. The
// app is usually a lid-closed laptop on the couch, so the prompt lives ON THE TV
// (a held receiver toast) and the remote answers it: OK = now, Back = credits.
void AppController::checkCastCredits()
{
    if (!m_cast->active() || m_castCreditsPending)
        return;
    const QString uri = m_cast->currentUri();
    if (uri.isEmpty() || m_cast->castState() != QLatin1String("PLAYING"))
        return;
    const double start = m_library->creditsFor(uri);
    const double pos = m_cast->castPosition();
    if (uri == m_castCreditsUri) {
        // Playing well before the credits again = a rewatch (re-cast / seek back):
        // re-arm, and let its resume point save again. (PLAYING + pos > 1 only — a
        // re-warm's BUFFERING/0 report must not re-arm.)
        if (start > 0 && pos > 1.0 && pos < start - 30.0)
            m_castCreditsUri.clear();
        return;
    }
    if (start <= 0 || pos < start)
        return;
    // a party room advances as one; repeat-one and live streams have no "next"
    if (m_partyViaCast || m_partyLive || m_queue->repeatMode() == QueueModel::RepeatOne
        || (!m_liveUri.isEmpty() && uri == m_liveUri))
        return;
    m_castCreditsUri = uri;           // fires once per title; banked as watched now
    m_store->markCompleted(uri);
    m_library->refreshResume();
    const QString title = peekNextTitle(uri);
    if (title.isEmpty())
        return;                       // nothing next — the credits just play out
    m_castCreditsPending = true;
    m_castCreditsTimer.start();
    m_cast->showTvToast(QStringLiteral("UP NEXT · %1   ·   BACK TO STAY").arg(title),
                        m_castCreditsTimer.interval(), /*prompt=*/true);
    emit toast(QStringLiteral("UP NEXT ON TV · %1 — BACK TO WATCH THE CREDITS").arg(title));
    Logger::log(QStringLiteral("credits"),
                QStringLiteral("cast UP NEXT at %1 s → %2").arg(start).arg(title));
}

void AppController::castCreditsGo()
{
    if (!m_castCreditsPending)
        return;
    m_castCreditsPending = false;
    m_castCreditsTimer.stop();
    if (!m_cast->active() || m_cast->currentUri() != m_castCreditsUri)
        return;
    m_cast->hideTvToast();
    Logger::log(QStringLiteral("credits"), QStringLiteral("cast UP NEXT accepted"));
    advanceAfter(m_castCreditsUri);   // casting: loads the next item straight onto the TV
}

void AppController::castCreditsCancel(bool flash)
{
    if (!m_castCreditsPending)
        return;
    m_castCreditsPending = false;
    m_castCreditsTimer.stop();
    if (flash) {
        m_cast->showTvToast(QStringLiteral("CREDITS · NEXT WHEN THEY END"));
        Logger::log(QStringLiteral("credits"), QStringLiteral("cast UP NEXT cancelled — credits play on"));
    } else {
        m_cast->hideTvToast();
    }
}

void AppController::creditsGo()
{
    if (m_creditsPath.isEmpty() || playbackIdentity(m_engine->path()) != m_creditsPath)
        return;
    const QString path = m_creditsPath;
    m_creditsPath.clear();
    Logger::log(QStringLiteral("credits"), QStringLiteral("UP NEXT accepted"));
    m_skipCountdownOnce = true;   // they just said yes — no second countdown
    advanceAfter(path);
    m_skipCountdownOnce = false;
}

void AppController::creditsDismiss()
{
    Logger::log(QStringLiteral("credits"), QStringLiteral("UP NEXT cancelled — credits play on"));
    m_creditsPath.clear(); // watch the credits; end-of-file advances as usual
}

// Deterministic order, whatever order hyprctl/Qt enumerated them in: a real
// display first (the CRT — crtLike — is always LAST), then by output name. Fixes
// the picker's layout jumping — HDMI-A-1 (the CRT) landed on top or not depending
// on whether it was powered at boot (device order, not sorted).
static void sortMonitorList(QVariantList &mons)
{
    std::sort(mons.begin(), mons.end(), [](const QVariant &a, const QVariant &b) {
        const QVariantMap ma = a.toMap(), mb = b.toMap();
        const bool ca = ma.value(QStringLiteral("crtLike")).toBool();
        const bool cb = mb.value(QStringLiteral("crtLike")).toBool();
        if (ca != cb)
            return !ca;   // non-CRT displays sort before the CRT
        return ma.value(QStringLiteral("name")).toString()
             < mb.value(QStringLiteral("name")).toString();
    });
}

QVariantList AppController::monitorsFromQt() const
{
    QVariantList mons;
    const auto screens = QGuiApplication::screens();
    for (QScreen *s : screens) {
        const QSize size = s->size();
        const double ratio =
            size.height() > 0 ? double(size.width()) / double(size.height()) : 0;
        mons.append(QVariantMap{
            {QStringLiteral("name"), s->name()},
            {QStringLiteral("width"), size.width()},
            {QStringLiteral("height"), size.height()},
            {QStringLiteral("refresh"), qRound(s->refreshRate())},
            {QStringLiteral("description"), s->model()},
            {QStringLiteral("crtLike"), ratio > 0 && ratio < 1.4},
        });
    }
    return mons;
}

void AppController::refreshMonitors()
{
    // Fill from Qt screens SYNCHRONOUSLY so the chooser (the first frame) has data
    // instantly, then refine ASYNCHRONOUSLY from hyprctl (authoritative names +
    // refresh rates) and re-emit when it lands. The old path ran a blocking
    // `hyprctl monitors -j` in the ctor and could stall the first frame up to 1.5s.
    m_monitors = monitorsFromQt();
    sortMonitorList(m_monitors);
    emit monitorsChanged();

    auto *proc = new QProcess(this);
    // FailedToStart (hyprctl absent, e.g. a non-Hyprland session) never emits
    // finished — clean the process up on error so it can't leak per call.
    connect(proc, &QProcess::errorOccurred, proc, &QObject::deleteLater);
    connect(proc, &QProcess::finished, this,
            [this, proc](int code, QProcess::ExitStatus status) {
                proc->deleteLater();
                if (code != 0 || status != QProcess::NormalExit)
                    return; // keep the Qt-screens list
                const QJsonArray arr =
                    QJsonDocument::fromJson(proc->readAllStandardOutput()).array();
                if (arr.isEmpty())
                    return;
                QVariantList mons;
                for (const QJsonValue &v : arr) {
                    const QJsonObject m = v.toObject();
                    const int w = m.value(QStringLiteral("width")).toInt();
                    const int h = m.value(QStringLiteral("height")).toInt();
                    const double ratio = h > 0 ? double(w) / double(h) : 0;
                    mons.append(QVariantMap{
                        {QStringLiteral("name"), m.value(QStringLiteral("name")).toString()},
                        {QStringLiteral("width"), w},
                        {QStringLiteral("height"), h},
                        {QStringLiteral("refresh"),
                         qRound(m.value(QStringLiteral("refreshRate")).toDouble())},
                        {QStringLiteral("description"),
                         m.value(QStringLiteral("description")).toString()},
                        {QStringLiteral("crtLike"), ratio > 0 && ratio < 1.4},
                    });
                }
                if (mons.isEmpty())
                    return;
                sortMonitorList(mons);
                // Only replace + re-emit if hyprctl actually differs from the Qt
                // list already shown — otherwise the chooser needlessly rebuilds
                // every plate ~100ms after the first frame.
                if (mons != m_monitors) {
                    m_monitors = mons;
                    emit monitorsChanged();
                }
            });
    proc->start(QStringLiteral("hyprctl"),
                {QStringLiteral("monitors"), QStringLiteral("-j")});
}

void AppController::attachWindow(QQuickWindow *window)
{
    m_window = window;
    if (m_window) {
        m_window->installEventFilter(this); // catch mouse movement for cursor hide
        // Remember the format Qt actually gave us. HDR recreates the window and
        // must hand back THIS format with only the colorspace changed — see
        // recreateWindow().
        m_baseFormat = m_window->format();
        // FreeSync without the flicker: watch whether it runs on our display
        // (see updateSteadyFrames; Main.qml's steady tick does the drawing —
        // QQuickWindow::update() on an unchanged scene drew no frame here).
        if (!m_vrrPoll) {
            m_vrrPoll = new QTimer(this);
            m_vrrPoll->setInterval(5000);
            connect(m_vrrPoll, &QTimer::timeout, this, &AppController::pollVrr);
            m_vrrPoll->start();
            QTimer::singleShot(1500, this, &AppController::pollVrr);
            connect(m_engine, &PlaybackEngine::pausedChanged, this,
                    &AppController::updateSteadyFrames);
            connect(m_engine, &PlaybackEngine::idleChanged, this,
                    &AppController::updateSteadyFrames);
        }
        // Start hidden: Wayland only honors cursor changes at pointer
        // enter/motion, so a timer firing while the mouse is parked changes
        // nothing on screen ("needs a nudge to hide"). Making blank the
        // state BEFORE the first enter means the enter itself applies it;
        // the first real mouse move brings the arrow back.
        hideCursor();
    }
}

void AppController::pollVrr()
{
    // Is adaptive sync (FreeSync) running on codec's display right now?
    // Hyprland reports it per monitor, and with misc:vrr = 2 it runs exactly
    // while a fullscreen window — codec — is up there. Asked off the GUI
    // thread and never waited on; no hyprctl (another compositor) reads "off".
    if (m_display.isEmpty() || m_vrrProbing)
        return;
    m_vrrProbing = true;
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p] {
        m_vrrProbing = false;
        bool on = false;
        const QJsonArray mons = QJsonDocument::fromJson(p->readAllStandardOutput()).array();
        for (const QJsonValue &v : mons) {
            const QJsonObject m = v.toObject();
            if (m.value(QStringLiteral("name")).toString() == m_display) {
                on = m.value(QStringLiteral("vrr")).toBool();
                break;
            }
        }
        p->deleteLater();
        if (on == m_vrrActive)
            return;
        m_vrrActive = on;
        Logger::log(QStringLiteral("display"),
                    QStringLiteral("adaptive sync %1 (%2)")
                        .arg(on ? QStringLiteral("running") : QStringLiteral("off"), m_display));
        updateSteadyFrames();
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            m_vrrProbing = false;
            p->deleteLater();
        }
    });
    p->start(QStringLiteral("hyprctl"), {QStringLiteral("monitors"), QStringLiteral("-j")});
}

void AppController::updateSteadyFrames()
{
    // A VA panel under FreeSync dims and brightens as its refresh rate swings,
    // and an idle codec draws about one frame a second — far under the
    // panel's 48 Hz floor, then a burst for every animation — so the screen
    // flickered on codec and nowhere else (the author, 2026-10-13; turning FreeSync
    // off cured it, but games want it). While FreeSync runs on our display,
    // codec presents EVERY refresh, so the rate never moves. Films included:
    // a playing film is no steady cadence on its own — the UI draws between
    // its frames (measured 32-65 presents a second for a 24 fps film, mpv
    // asking for exactly 24) — and on a steady refresh mpv still renders each
    // frame once; the scene just shows the latest at every refresh.
    // That holds on the THREADED loop (MATCH DISPLAY), which presents on the
    // display's vsync. The BASIC loop (STANDARD 60) presents whenever asked:
    // the tick's 60 plus mpv's 24 came out 63-129 uneven presents a second, so
    // there a playing film keeps its old ~58 cadence and the tick rests.
    const bool playing = !m_engine->idle() && !m_engine->paused();
    const bool want = m_vrrActive
        && (m_frameRateLive == QLatin1String("display") || !playing);
    if (want == m_steadyFrames)
        return;
    m_steadyFrames = want;
    Logger::log(QStringLiteral("display"),
                want ? QStringLiteral("steady frames on (FreeSync)")
                     : QStringLiteral("steady frames off"));
    emit steadyFramesChanged();
}

void AppController::sendKey(int key)
{
    // Synth a tap of a key codec already handles, to the focused QML item. These
    // re-enter eventFilter but aren't remote keys, so handleRemoteKey passes them.
    QKeyEvent press(QEvent::KeyPress, key, Qt::NoModifier);
    QKeyEvent release(QEvent::KeyRelease, key, Qt::NoModifier);
    QCoreApplication::sendEvent(m_window, &press);
    QCoreApplication::sendEvent(m_window, &release);
}

// A two-key cap ("l/⏎", "w/esc", "a/A") is clickable by the key that means
// the same on a click — Enter, Escape, or the plain letter; "j/k" (two
// different actions) is not.
static QString capToken(const QString &cap)
{
    const QString c = cap.trimmed();
    if (!c.contains(QLatin1Char('/')) || c == QLatin1String("/"))
        return c;
    const QStringList parts = c.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (const QString &p : parts)
        if (p == QStringLiteral("⏎") || p.toLower() == QLatin1String("esc"))
            return p;
    if (parts.size() == 2 && parts[0].size() == 1
        && parts[0].compare(parts[1], Qt::CaseInsensitive) == 0)
        return parts[0];
    return QString();
}

int AppController::keyCapKey(const QString &cap) const
{
    const QString c = capToken(cap);
    if (c.size() == 1) {
        const QChar ch = c.at(0);
        if (ch.isLetter() && ch.unicode() < 128)
            return Qt::Key_A + (ch.toUpper().unicode() - 'A');
        if (ch.isDigit())
            return Qt::Key_0 + (ch.unicode() - '0');
        switch (ch.unicode()) {
        case 0x23CE: case 0x21B5: return Qt::Key_Return;   // ⏎ ↵
        case 0x2423: return Qt::Key_Space;                  // ␣
        case 0x2191: return Qt::Key_Up;
        case 0x2193: return Qt::Key_Down;
        case 0x2190: return Qt::Key_Left;
        case 0x2192: return Qt::Key_Right;
        case '/': return Qt::Key_Slash;
        case '?': return Qt::Key_Question;
        case '`': return Qt::Key_QuoteLeft;
        default: return 0;
        }
    }
    const QString l = c.toLower();
    if (l == QLatin1String("esc"))
        return Qt::Key_Escape;
    if (l == QLatin1String("tab"))
        return Qt::Key_Tab;
    if (l == QLatin1String("del"))
        return Qt::Key_Delete;
    if (l == QLatin1String("space"))
        return Qt::Key_Space;
    return 0;
}

void AppController::pressKeyCap(const QString &cap)
{
    const int key = keyCapKey(cap);
    if (!key || !m_window)
        return;
    // The views tell "S" from "s" by the event's text + Shift, so send both
    // as the keyboard would.
    const QString c = capToken(cap);
    QString text;
    Qt::KeyboardModifiers mods = Qt::NoModifier;
    if (c.size() == 1 && c.at(0).isLetterOrNumber()) {
        text = c;
        if (c.at(0).isUpper())
            mods = Qt::ShiftModifier;
    } else if (key == Qt::Key_Return) {
        text = QStringLiteral("\r");
    } else if (key == Qt::Key_Space) {
        text = QStringLiteral(" ");
    } else if (key == Qt::Key_Slash || key == Qt::Key_Question || key == Qt::Key_QuoteLeft) {
        text = c;
        if (key == Qt::Key_Question)
            mods = Qt::ShiftModifier;
    }
    QKeyEvent press(QEvent::KeyPress, key, mods, text);
    QKeyEvent release(QEvent::KeyRelease, key, mods, text);
    QCoreApplication::sendEvent(m_window, &press);
    QCoreApplication::sendEvent(m_window, &release);
    // The synthetic KeyPress hid the pointer and handed selection to the
    // keyboard — it was a CLICK, so give the pointer back.
    showCursor();
    m_cursorTimer.start();
    setPointerActive(true);
}

namespace { enum RemoteHold { HoldNone = 0, HoldBack, HoldHome, HoldGuide, HoldCast, HoldResume, HoldStopQueue }; }

void AppController::remoteHoldFired()
{
    m_remoteHeldDone = true; // the eventual release now does nothing
    const bool inPlayer = (m_stage == QLatin1String("player"));
    switch (m_remoteHoldAction) {
    case HoldBack:                                        // hold Back  → home
        // (not from the player: the film just moves into the miniplayer — silent)
        if (m_sfx && m_stage != QLatin1String("home") && !inPlayer) m_sfx->play(QStringLiteral("back"));
        goHome();
        break;
    case HoldHome:                                        // hold Home  → display picker
        if (m_sfx) m_sfx->play(QStringLiteral("back"));
        backToChooser();
        break;
    case HoldGuide:  if (inPlayer) findSubtitles(); break; // hold Guide → fetch subs online
    case HoldCast:   remoteResumeLast(/*toCast=*/true);  break; // hold CAST   → cast last/current to the TV
    case HoldResume: remoteResumeLast(/*toCast=*/false); break; // hold RESUME → resume locally on this device
    case HoldStopQueue:                                          // hold STOP (queue open) → clear the queue
        emit remoteQueueAction(QStringLiteral("clear"));
        emit toast(QStringLiteral("QUEUE CLEARED"));
        break;
    default: break;
    }
}

// Fling the current title to the TV, or bring it back if already casting.
// Auto-targets a Sony/Bravia/TV device, else the first discovered one; kicks
// discovery if none are known yet.
// NOTE: no longer bound to CAST (195) — that button is now tap=hint / hold=resume
// (the flagship). This "fling/bring-home" toggle is kept for the future
// "switch device / output" spare key it belongs on. Still Q_INVOKABLE for QML.
void AppController::remoteCastToggle()
{
    if (m_cast->active()) { setOutput({}); return; }       // on the TV → bring it home
    const int n = m_cast->deviceCount();
    if (n <= 0) {
        m_cast->start();                                   // spin up discovery; press again once it lands
        emit toast(QStringLiteral("SEARCHING FOR TV…"));
        return;
    }
    QString id;
    for (int i = 0; i < n && id.isEmpty(); ++i) {
        const QVariantMap d = m_cast->deviceAt(i);
        const QString name = d.value(QStringLiteral("name")).toString().toUpper();
        if (name.contains(QLatin1String("BRAVIA")) || name.contains(QLatin1String("SONY"))
            || name.contains(QLatin1String("TV")))
            id = d.value(QStringLiteral("id")).toString();
    }
    if (id.isEmpty())
        id = m_cast->deviceAt(0).value(QStringLiteral("id")).toString();
    if (id.isEmpty()) { emit toast(QStringLiteral("NO CAST TARGET")); return; }
    setOutput(id);                                         // setOutput toasts "OUT → <NAME>"
}

// SLEEP (touchscreen Return) tap: cycle off → 30 → 60 min (tap during the 3·2·1
// aborts). On fire the single-shot m_sleepTimer starts a countdown that stops
// playback and blanks the displays (sleepDisplays).
void AppController::remoteSleepCycle(int dir)
{
    if (m_sleepCountTimer.isActive()) {       // tapped mid 3·2·1 → abort the stop
        m_sleepCountTimer.stop();
        m_sleepIdx = 0;
        emit toast(QStringLiteral("SLEEP CANCELLED"));
        emit sleepChanged();
        return;
    }
    static const int kMins[] = {0, 30, 60};
    m_sleepIdx = wrapStep(m_sleepIdx, 3, dir);
    const int mins = kMins[m_sleepIdx];
    if (mins == 0) {
        m_sleepTimer.stop();
        emit toast(QStringLiteral("SLEEP TIMER OFF"));
    } else {
        m_sleepTimer.start(mins * 60 * 1000);
        emit toast(QStringLiteral("SLEEP TIMER · %1 MIN").arg(mins));
    }
    emit sleepChanged();
}

int AppController::sleepMinutes() const
{
    static const int kMins[] = {0, 30, 60};
    return m_sleepTimer.isActive() || m_sleepCountTimer.isActive() ? kMins[m_sleepIdx] : 0;
}

double AppController::sleepEndsAt() const
{
    if (!m_sleepTimer.isActive())
        return 0;
    return double(QDateTime::currentMSecsSinceEpoch() + m_sleepTimer.remainingTime());
}

// SLEEP fire: blank the displays. Portable default = compositor dpms off, but a
// per-machine ~/.config/codec/sleep-displays.sh override wins (the desktop needs
// one: its CRT + DP-3 share a CRTC pool, so compositor-dpms crashes it — that
// script uses crt-power + ddcutil + hyprlock instead).
void AppController::sleepDisplays()
{
    const QString override = QDir::homePath() + QStringLiteral("/.config/codec/sleep-displays.sh");
    if (QFileInfo::exists(override))
        QProcess::startDetached(QStringLiteral("/bin/sh"), {override});
    else
        QProcess::startDetached(QStringLiteral("hyprctl"),
                                {QStringLiteral("dispatch"), QStringLiteral("dpms"), QStringLiteral("off")});
}

bool AppController::handleRemoteKey(QKeyEvent *ke)
{
    if (m_attract) // let the attract-wake path swallow the first press instead
        return false;
    const bool isPress = (ke->type() == QEvent::KeyPress);
    const bool repeat = ke->isAutoRepeat();
    const int key = ke->key();
    const int scan = (key == 0) ? int(ke->nativeScanCode()) : -1;
    const bool inPlayer = (m_stage == QLatin1String("player"));
    const bool overlay = m_queueOpen || m_searchOpen || m_partyOpen;

    // OFA remote colour/return/info keys — BLE HID F14–F19 (red, green, yellow,
    // blue, return, info) and the SPARE 1-10 keys. Matched by NATIVE SCANCODE
    // (evdev + 8: colours 192–195, return 196, info 197, spares 199–202, 138,
    // 140, 137, 100, 102, 98), NOT the Qt key: the keymap surfaces some as
    // Launch5–7, but the physical scancode is stable across keymaps and both
    // machines. Map as of 2026-10-04 (touchscreen pages de-duplicated, see
    // tools/ofa/drop_named_page.py): colours = free slots (settings.remoteColors),
    // return = add to queue, info = info page, spares = settings.remoteSpares.
    // SPARE 1-10 touchscreen keys → whatever the user put on them. The job
    // lives in config (settings.remoteSpares, ten action words) so relabelling
    // or reordering the spares on the remote never needs a code change.
    {
        static const int kSpareScans[10] = {199, 200, 201, 202, 138, 140, 137, 100, 102, 98};
        const int sc = int(ke->nativeScanCode());
        for (int n = 0; n < 10; ++n)
            if (sc == kSpareScans[n]) {
                remoteSpare(n, isPress, repeat);
                return true;
            }
    }

    switch (int(ke->nativeScanCode())) {
    // Red/Green/Yellow → screen-mode / subtitles / audio. When a cast is live,
    // drive the TV (the couch use-case); otherwise the local player. Without the
    // cast branch these keys were dead mid-cast — `inPlayer` is false while
    // casting and m_engine is idle, so a touchscreen tap hit nothing.
    // Red/Green/Yellow/Blue are FREE SLOTS now (2026-10-04): their old jobs —
    // screen mode, subtitles, audio, cast — moved to labelled spares, and the
    // colour buttons wait for new ones (settings.remoteColors; same action
    // words as the spares, default none).
    case 192: case 193: case 194: case 195:
        remoteKeyAction(colorAction(int(ke->nativeScanCode()) - 192),
                        QStringList{QStringLiteral("RED"), QStringLiteral("GREEN"),
                                    QStringLiteral("YELLOW"), QStringLiteral("BLUE")}
                            .value(int(ke->nativeScanCode()) - 192),
                        isPress, repeat);
        return true;
    // Return (196) = ADD TO QUEUE, like REC. It used to be SLEEP — but the
    // label page shows this same key as "SLEEP" AND the keypad's return icon
    // sends it too, so both buttons slept. SLEEP lives on SPARE 2 now.
    case 196: if (isPress && !repeat) emit queueAddRequested(); return true;
    case 197: if (isPress && !repeat && !m_searchOpen) sendKey(Qt::Key_I);   return true; // Info   → detail page
    default: break;
    }

    // Hold-capable buttons: Back, Home, Guide. Tap fires on release; the hold
    // action fires from m_remoteHoldTimer if still held past the threshold.
    int hold = HoldNone;
    if (key == Qt::Key_Back)          hold = HoldBack;
    else if (key == Qt::Key_HomePage) hold = HoldHome;
    else if (scan == 370)             hold = HoldGuide; // Guide (KEY_PROGRAM)
    else if (key == Qt::Key_MediaStop && m_queueOpen) hold = HoldStopQueue; // STOP over the queue
    if (hold != HoldNone) {
        if (isPress && !repeat) {
            m_remoteHoldAction = hold;
            m_remoteHeldDone = false;
            m_remoteHoldTimer.start();
        } else if (!isPress && !repeat) {
            m_remoteHoldTimer.stop();
            if (!m_remoteHeldDone && m_remoteHoldAction == hold) {
                switch (hold) { // tap action
                case HoldBack:
                    // The mouse's Back exactly (credits card, Esc, and the
                    // history the mouse's Forward re-enters).
                    mouseBack();
                    break;
                case HoldHome:
                    if (m_sfx && m_stage != QLatin1String("home") && !inPlayer)
                        m_sfx->play(QStringLiteral("back"));
                    goHome();
                    break;
                // GUIDE tap = the miniplayer (was REC's job; subtitles stay
                // on the green key, and GUIDE HOLD still finds subtitles).
                case HoldGuide: if (inPlayer) leavePlayer(); else toPlayer(); break;
                case HoldStopQueue: emit remoteQueueAction(QStringLiteral("remove")); break;
                default: break;
                }
            }
            m_remoteHoldAction = HoldNone;
        }
        return true;
    }

    // OK: bare player = play/pause; anywhere else it acts exactly like Enter
    // (tap = select, hold = the view's own context menu), so forward it as Return.
    if (key == Qt::Key_Select && m_castCreditsPending) {
        if (isPress && !repeat)
            castCreditsGo();                // UP NEXT on the TV → go now
        return true;
    }
    if (key == Qt::Key_Select) {
        if (inPlayer && !overlay && !m_playerPrompt) {
            if (isPress && !repeat)
                playPause();
        } else if (!repeat) {
            QKeyEvent ev(ke->type(), Qt::Key_Return, Qt::NoModifier);
            QCoreApplication::sendEvent(m_window, &ev);
        }
        return true;
    }

    // Remaining remote keys — act on the initial press (Rewind/FF also on repeat
    // for continuous seek). Synth targets are non-letter so text fields are safe.
    int synth = 0;
    bool recognized = true;
    switch (key) {
    case Qt::Key_AudioRewind:  synth = Qt::Key_Left;  break;                        // ◀◀
    case Qt::Key_AudioForward: synth = Qt::Key_Right; break;                        // ▶▶
    case Qt::Key_MediaStop:    if (isPress && !repeat) stopPlayback(); break;       // Stop
    case Qt::Key_MediaRecord:  if (isPress && !repeat) emit queueAddRequested(); break; // Rec → add to queue
    case Qt::Key_Search:                                                            // Search: YouTube's own in YouTube
        if (isPress && !repeat) {
            if (m_stage == QLatin1String("youtube") && m_detailUri.isEmpty())
                emit youtubeSearchRequested();
            else
                setSearchOpen(true);
        }
        break;
    case Qt::Key_Menu:
    case 0x010000dc:           if (isPress && !repeat) setQueueOpen(!m_queueOpen); break; // Menu → queue
    default:
        switch (scan) {
        case 588: if (isPress && !repeat && inPlayer) m_engine->cycleAudio();    break; // Apps  → audio
        // Input → zoom. On the desktop it never arrives: Hyprland takes INPUT
        // (and POWER) first for scripts/codec_screen.sh — codec ⇄ the CRT.
        case 385: if (isPress && !repeat && inPlayer) m_engine->cycleZoomMode(); break;
        // Ch+/Ch-: with the queue open they MOVE the selected item up/down
        // (the remote can't send the Shift+J/K the sidebar uses); else next/prev.
        case 410: if (isPress && !repeat) { if (m_queueOpen) emit remoteQueueAction(QStringLiteral("up"));
                                            else playerNext(); } break;                 // Ch+
        case 411: if (isPress && !repeat) { if (m_queueOpen) emit remoteQueueAction(QStringLiteral("down"));
                                            else playerPrev(); } break;                 // Ch-
        default:  recognized = false; break;
        }
        break;
    }
    if (!recognized)
        return false;
    if (synth && isPress) // Rewind/FF: forward each press (incl. auto-repeat)
        sendKey(synth);
    return true;
}

bool AppController::eventFilter(QObject *obj, QEvent *event)
{
    // frontWindow's warp + nudge arrive as pointer motion: swallow it, so it
    // neither shows the cursor nor wakes the OSD (the pointer's place is still
    // learned, so the first REAL move counts as one).
    if ((event->type() == QEvent::MouseMove || event->type() == QEvent::HoverMove)
        && m_pointerHushUntil > 0) {
        if (QDateTime::currentMSecsSinceEpoch() < m_pointerHushUntil) {
            m_lastCursorPos = QCursor::pos();
            return true;
        }
        m_pointerHushUntil = 0;
    }
    // OFA remote (BLE) → codec actions, incl. tap-vs-hold on Back/Home/Guide.
    // The full map + rationale live in handleRemoteKey (both press and release).
    if ((event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease)
        && obj == m_window) {
        if (handleRemoteKey(static_cast<QKeyEvent *>(event)))
            return true;
    }
    // A DELIBERATE input — key or click — dismisses attract mode; the waking
    // event is SWALLOWED so waking the screen never also presses play. Mouse
    // motion does NOT wake it (a desk bump shouldn't kill the slideshow); it
    // still counts as activity for the idle clock when attract isn't up.
    switch (event->type()) {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
        if (m_attract) {
            setAttract(false);
            armAttract();
            m_lastCursorPos = QCursor::pos();
            if (event->type() == QEvent::MouseButtonPress) {
                showCursor(); // a key wake keeps driving keyboard-dark
                m_cursorTimer.start();
            }
            Logger::log(QStringLiteral("attract"),
                        QStringLiteral("woken by event %1 — swallowed")
                            .arg(int(event->type())));
            return true;
        }
        m_attractTimer.stop();
        armAttract();
        break;
    case QEvent::Wheel:
    case QEvent::MouseMove:
    case QEvent::HoverMove: {
        const bool moved = event->type() == QEvent::Wheel
                           || QCursor::pos() != m_lastCursorPos;
        if (!moved || m_attract) // motion neither wakes nor rearms attract
            break;
        m_attractTimer.stop();
        armAttract();
        break;
    }
    default:
        break;
    }

    switch (event->type()) {
    case QEvent::MouseMove:
    case QEvent::HoverMove: {
        // Content sliding under a PARKED pointer synthesizes hover events;
        // only a really-moved cursor un-hides (same trap as hover-select).
        const QPoint g = QCursor::pos();
        if (g == m_lastCursorPos || m_attract)
            break;
        m_lastCursorPos = g;
        showCursor();
        m_cursorTimer.start();
        setPointerActive(true);
        break;
    }
    case QEvent::MouseButtonPress:
    case QEvent::Wheel:
        if (m_attract)
            break;
        if (event->type() == QEvent::MouseButtonPress && qobject_cast<QQuickWindow *>(obj)
            && !m_garageEditing) {
            // Mouse BACK / FORWARD, app-wide and for any mouse: the thumb
            // buttons (BTN_SIDE/BTN_EXTRA = Back/ForwardButton) AND the
            // dedicated BTN_BACK/BTN_FORWARD some mice send instead
            // (ExtraButton4/3 in Qt's Wayland mapping). Only the garage editor
            // used them before, so on any other screen they did nothing.
            const Qt::MouseButton b = static_cast<QMouseEvent *>(event)->button();
            // Both send synthetic keys, whose KeyPress path hides the cursor
            // and hands selection to the keyboard — wrong for a MOUSE button
            // (the arrow vanished after every thumb Back). Give it back, as the
            // wheel click below does.
            if (b == Qt::BackButton || b == Qt::ExtraButton4) {
                mouseBack();
                showCursor();
                m_cursorTimer.start();
                setPointerActive(true);
                return true;
            }
            if (b == Qt::ForwardButton || b == Qt::ExtraButton3) {
                mouseForward();
                showCursor();
                m_cursorTimer.start();
                setPointerActive(true);
                return true;
            }
            // Wheel CLICK = select, like the remote's OK: bare player toggles
            // pause, anywhere else it is Enter on the selection (which hover
            // already put under the pointer). On the trackball a held wheel
            // button + ball roll is SCROLL; libinput only delivers a click when
            // the ball stayed still, so the two never collide. Text fields keep
            // their own middle-click (paste).
            if (b == Qt::MiddleButton) {
                QQuickItem *f = m_window ? m_window->activeFocusItem() : nullptr;
                if (!(f && f->inherits("QQuickTextInput"))) {
                    remoteOk();
                    // remoteOk's synthetic Return runs the KeyPress path, which
                    // hides the cursor and hands selection to the keyboard —
                    // wrong for a MOUSE click. Give the pointer back.
                    showCursor();
                    m_cursorTimer.start();
                    setPointerActive(true);
                    return true;
                }
            }
        }
        if (event->type() == QEvent::Wheel && qobject_cast<QQuickWindow *>(obj)) {
            // Tilt wheel -> tiltStep(±1) for views that step sideways (the
            // YouTube tabs). Watched here, never consumed: a WheelHandler on
            // the list sat in the way of ordinary scrolling. Only DISCRETE
            // steps count — the trackball's ball-scroll is a continuous
            // source (pixel deltas) and its sideways drift is not a tilt.
            // Keyed on the KIND of scroll, never on a device name, so it holds
            // for any trackball / mouse: a tilt click is discrete (no pixel
            // delta) and purely sideways; ball-scroll and touchpads are
            // continuous sources and carry pixel deltas.
            const auto *we = static_cast<QWheelEvent *>(event);
            // (Scroll PHASE and device TYPE were tried as extra gates and broke
            // the tilt on Wayland — Qt phases/labels wheel clicks too. The pixel
            // delta alone is what actually separates the two sources.)
            if (we->pixelDelta().isNull() && we->angleDelta().y() == 0
                && we->angleDelta().x() != 0 && m_detailUri.isEmpty()) {
                // A tilt click NAVIGATES, like an arrow key — so the pointer
                // must not own the selection afterwards. Marking the pointer
                // active here (as an ordinary scroll does) made the movies/TV
                // grid treat each step as mouse input: no scrolloff, edge
                // auto-scroll, and the poster sliding under the parked cursor
                // stole the selection back — stepping right looped one row.
                setPointerActive(false);
                m_tiltAcc += we->angleDelta().x();
                if (qAbs(m_tiltAcc) >= 120) {
                    emit tiltStep(m_tiltAcc > 0 ? -1 : 1);
                    m_tiltAcc = 0;
                }
                // CONSUMED: a tilt means "step sideways" everywhere in codec.
                // Passed on, the movies/TV GridView ALSO scrolled on it, so the
                // page moved under the step and the selection wandered.
                return true;
            }
        }
        showCursor();
        m_cursorTimer.start();
        setPointerActive(true);
        break;
    case QEvent::KeyPress:
        // Keyboard driving = the pointer is noise; hide it NOW, not after
        // the idle timeout, and hand selection back to the keyboard. First
        // real mouse move brings both back.
        m_cursorTimer.stop();
        hideCursor();
        setPointerActive(false);
        break;
    case QEvent::Enter:
    case QEvent::FocusIn:
        // A pointer enter (or refocus) is exactly the moment the compositor
        // accepts a cursor change — re-push the hidden state that a parked
        // pointer may have kept from applying.
        if (m_cursorHidden)
            QGuiApplication::changeOverrideCursor(Qt::BlankCursor);
        break;
    default:
        break;
    }
    return QObject::eventFilter(obj, event);
}

void AppController::showCursor()
{
    if (m_cursorHidden) {
        QGuiApplication::restoreOverrideCursor();
        m_cursorHidden = false;
    }
}

void AppController::setPointerActive(bool on)
{
    if (on == m_pointerActive)
        return;
    m_pointerActive = on;
    emit pointerActiveChanged();
}

void AppController::hideCursor()
{
    // Application-wide override: a window-level cursor can be shadowed by
    // items that carry their own cursor shape (drag areas, text inputs),
    // which left the pointer visible "sometimes". The override wins.
    if (!m_cursorHidden) {
        QGuiApplication::setOverrideCursor(Qt::BlankCursor);
        m_cursorHidden = true;
    }
}

void AppController::updateSfxQuiet()
{
    if (m_sfx)
        m_sfx->setQuiet(!m_engine->paused() && !m_engine->idle()
                        && !m_engine->path().isEmpty());
}

void AppController::updateIdleInhibit()
{
    // Stay awake while a video is genuinely playing locally (not paused, not
    // idle) OR while a cast session is live. A cast drives the TV from this
    // machine's worker, so the host must not suspend — and, on a laptop, must
    // not act on a closed lid — or the session dies and remote control is lost.
    // The cast case holds even while PAUSED (target still set): suspending
    // mid-pause would kill the session just the same.
    const bool playing = !m_engine->paused() && !m_engine->idle()
        && !m_engine->path().isEmpty();
    const bool casting = m_cast && m_cast->active();
    setInhibited(playing || casting);
}

static QDBusMessage screensaverCall(const char *method)
{
    return QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.ScreenSaver"),
        QStringLiteral("/org/freedesktop/ScreenSaver"),
        QStringLiteral("org.freedesktop.ScreenSaver"),
        QLatin1String(method));
}

void AppController::acquireScreensaverInhibit()
{
    // Ask the org.freedesktop.ScreenSaver owner (hypridle) not to blank/lock the
    // screen and stash the returned cookie. Safe to call again after the owner
    // changes: the previous cookie died with the previous owner, so we simply take
    // a fresh one. Async — a hung/absent service must never block the UI.
    QDBusMessage m = screensaverCall("Inhibit");
    m << QStringLiteral("codec") << QStringLiteral("Video playback");
    auto *w = new QDBusPendingCallWatcher(
        QDBusConnection::sessionBus().asyncCall(m), this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<uint> r = *w;
        w->deleteLater();
        if (!r.isValid())
            return;
        if (m_inhibited && m_inhibitCookie == 0) {
            m_inhibitCookie = r.value();
        } else {
            // Flipped back off before the reply landed — or an on/off/on inside
            // one round trip left us holding a NEWER cookie already: storing
            // this one would orphan the other and keep the screen inhibited
            // until codec exits. Release it.
            QDBusMessage u = screensaverCall("UnInhibit");
            u << r.value();
            QDBusConnection::sessionBus().asyncCall(u);
        }
    });
}

void AppController::setInhibited(bool on)
{
    // Fully async: this fires on every play/idle flip, so during rapid queue
    // skipping a blocking D-Bus round-trip (25s default timeout when the
    // service is hung/absent) stacked up into a frozen UI.
    if (on == m_inhibited)
        return;
    m_inhibited = on;
    if (on) {
        // (1) Screensaver: keep the screen from blanking (session bus, cookie).
        // Re-acquired on ScreenSaver owner changes (see the ctor watcher) so a
        // restarted idle daemon (hypridle) can't orphan the cookie and let the
        // screen idle mid-playback while we still believe we're inhibited.
        acquireScreensaverInhibit();

        // (2) System suspend + lid: hold a logind inhibitor so the machine
        // can't auto-suspend mid-movie (the screensaver lock only stops screen
        // blanking) AND doesn't act on a closed laptop lid mid-cast. logind
        // lives on the SYSTEM bus and hands back a fd whose open file
        // description IS the lock — dup it and hold it while playing/casting;
        // closing the last dup releases the lock. Replaces the codec-movie-mode
        // shell workaround. NOTE: the handle-lid-switch inhibitor is only
        // honored when logind is configured with LidSwitchIgnoreInhibited=no
        // (a per-machine drop-in on the laptop); on the desktop hub it's a
        // harmless no-op (no lid), and "sleep" alone still blocks auto-suspend.
        QDBusMessage s = QDBusMessage::createMethodCall(
            QStringLiteral("org.freedesktop.login1"),
            QStringLiteral("/org/freedesktop/login1"),
            QStringLiteral("org.freedesktop.login1.Manager"),
            QStringLiteral("Inhibit"));
        s << QStringLiteral("sleep:handle-lid-switch") << QStringLiteral("codec")
          << QStringLiteral("Playback or cast active") << QStringLiteral("block");
        auto *sw = new QDBusPendingCallWatcher(
            QDBusConnection::systemBus().asyncCall(s), this);
        connect(sw, &QDBusPendingCallWatcher::finished, this,
                [this](QDBusPendingCallWatcher *w) {
            const QDBusPendingReply<QDBusUnixFileDescriptor> r = *w;
            w->deleteLater();
            if (!r.isValid() || !r.value().isValid())
                return;
            // Keep it only if still playing and we don't already hold one; the
            // reply's own copy closes when it goes out of scope, so if we've
            // flipped off in the meantime the lock releases on its own.
            if (m_inhibited && m_sleepInhibitFd < 0)
                m_sleepInhibitFd = ::dup(r.value().fileDescriptor());
        });
    } else {
        if (m_inhibitCookie) {
            QDBusMessage u = screensaverCall("UnInhibit");
            u << m_inhibitCookie;
            QDBusConnection::sessionBus().asyncCall(u);
            m_inhibitCookie = 0;
        }
        if (m_sleepInhibitFd >= 0) {
            ::close(m_sleepInhibitFd); // releases the logind sleep inhibitor
            m_sleepInhibitFd = -1;
        }
    }
}

QString AppController::modeForDisplay(const QString &name) const
{
    // The display IS the mode: a 5:4-ish panel is the CRT, anything else
    // (DP-3, external USB-C/HDMI) is HD.
    for (const QVariant &v : m_monitors) {
        const QVariantMap m = v.toMap();
        if (m.value(QStringLiteral("name")).toString() == name)
            return m.value(QStringLiteral("crtLike")).toBool() ? QStringLiteral("crt")
                                                               : QStringLiteral("hd");
    }
    return QStringLiteral("hd");
}

void AppController::setCliOptions(const QString &display, const QString &mode,
                                  const QString &path)
{
    m_pendingPath = path;
    if (display.isEmpty())
        return;
    m_display = display;
    m_mode = mode.isEmpty() ? modeForDisplay(display) : mode.toLower();
    emit modeChanged();
    probeDisplayHdr();
    applyPlacement();
    enterAfterChooser();
}

int AppController::zoomFor(const QString &identity, const QString &mode) const
{
    const int def = (mode == QLatin1String("crt")) ? PlaybackEngine::Zoom
                                                   : PlaybackEngine::Fit;
    if (identity.isEmpty())
        return def;
    // A file's zoom preference only carries over within the same viewing mode —
    // switching HD -> CRT must fall back to CRT's zoom-fill default.
    const QVariantMap st = m_store->state(identity);
    const int saved = st.value(QStringLiteral("lastMode")).toString() == mode
        ? st.value(QStringLiteral("zoomMode"), -1).toInt() : -1;
    return saved >= 0 ? saved : def;
}

void AppController::chooseDisplay(const QString &name)
{
    m_wantDisplay.clear(); // a choice made here outranks any screen we were waiting on
    switchDisplay(name);
    enterAfterChooser();
}

void AppController::switchDisplay(const QString &name)
{
    const QString oldMode = m_mode;
    // Leaving a panel codec put in HDR: hand it back while m_display still
    // names it. The new screen engages its own HDR below if it wants it.
    bool recreated = false;
    if (m_hdrEngaged && name != m_display) {
        m_hdrDebounce.stop();
        setHdrEngaged(false); // recreates the window (the surface's colour is fixed)
        recreated = true;
    }
    m_display = name;
    m_mode = modeForDisplay(name);
    emit modeChanged();
    // A film playing here when the MODE changes takes the new mode's zoom at
    // once — the CRT fills its glass (ZOOM), HD fits — as it would had it
    // started there. It used to keep the old mode's until the next film
    // (the author, 2026-10-13). A cast's zoom is the television's: left alone.
    if (m_mode != oldMode && !m_engine->idle() && !m_engine->path().isEmpty()
        && !castingNow()) {
        const int z = zoomFor(playbackIdentity(m_engine->path()), m_mode);
        if (z != m_engine->zoomMode())
            m_engine->setZoomMode(z);
        Logger::log(QStringLiteral("zoom"),
                    QStringLiteral("%1 mode → %2").arg(m_mode.toUpper(),
                        QLatin1String(z == PlaybackEngine::Zoom ? "ZOOM"
                                      : z == PlaybackEngine::Stretch ? "STRETCH" : "FIT")));
    }
    probeDisplayHdr();
    // a just-recreated surface isn't mapped yet — the move would find no window
    if (recreated)
        QTimer::singleShot(400, this, [this] { applyPlacement(); });
    else
        applyPlacement();
    updateHdrEngaged();
}

void AppController::moveToDisplay(const QString &name)
{
    if (name.isEmpty())
        return;
    m_wantDisplay.clear();
    bool lit = false;
    for (QScreen *s : QGuiApplication::screens())
        lit = lit || s->name() == name;
    if (!lit) {
        // The tube is still waking (the INPUT script lights it first): go the
        // moment it's there — or forget it, if it never comes.
        m_wantDisplay = name;
        const int gen = ++m_wantGen;
        QTimer::singleShot(10000, this, [this, name, gen] {
            if (m_wantGen == gen && m_wantDisplay == name) {
                Logger::log(QStringLiteral("place"),
                            QStringLiteral("%1 never lit — staying on %2").arg(name, m_display));
                m_wantDisplay.clear();
            }
        });
        Logger::log(QStringLiteral("place"), QStringLiteral("waiting for %1").arg(name));
        return;
    }
    refreshMonitors(); // a screen lit since launch isn't in the list (its shape = its mode)
    Logger::log(QStringLiteral("place"), QStringLiteral("move %1 → %2").arg(m_display, name));
    if (m_display.isEmpty() || m_stage == QLatin1String("chooser"))
        chooseDisplay(name); // still choosing: this IS the choice
    else
        switchDisplay(name);
}

void AppController::reconcileScreens()
{
    refreshMonitors();
    QStringList lit;
    for (QScreen *s : QGuiApplication::screens()) {
        const QString n = s->name();
        // Hyprland stands a placeholder output in while nothing is lit
        if (!n.isEmpty() && !n.startsWith(QLatin1String("FALLBACK"))
            && !n.startsWith(QLatin1String("HEADLESS")))
            lit << n;
    }
    const bool choosing = m_display.isEmpty() || m_stage == QLatin1String("chooser");
    if (!m_wantDisplay.isEmpty() && lit.contains(m_wantDisplay)) {
        const QString want = m_wantDisplay;
        m_wantDisplay.clear();
        Logger::log(QStringLiteral("place"), QStringLiteral("%1 lit — codec goes back").arg(want));
        if (choosing)
            chooseDisplay(want);
        else
            switchDisplay(want);
        return;
    }
    if (choosing || lit.contains(m_display))
        return;
    // Our screen went dark under us (the Pause lock sleeps the tube; SLEEP
    // darkens both): Hyprland has carried the window to what's still lit.
    // Wear that screen's mode until ours comes back, then go home to it.
    if (m_wantDisplay.isEmpty()) {
        m_wantDisplay = m_display;
        ++m_wantGen; // no expiry: a lock can last all night
    }
    QString to;
    if (m_window && m_window->screen() && lit.contains(m_window->screen()->name()))
        to = m_window->screen()->name();
    else if (!lit.isEmpty())
        to = lit.first();
    if (to.isEmpty())
        return; // nothing lit at all: wait for a screen
    Logger::log(QStringLiteral("place"),
                QStringLiteral("%1 went dark — on %2 until it's back").arg(m_display, to));
    switchDisplay(to);
}

void AppController::enterAfterChooser()
{
    if (!m_pendingPath.isEmpty()) {
        const QString path = m_pendingPath;
        m_pendingPath.clear();
        m_library->rescan();
        // A YouTube URL launched from the shell might be a live stream — one
        // short yt-dlp probe so it plays live (no bogus resume) and opens
        // chat, same as picking it from the browser. CLI is a one-shot, not
        // the hot path, so a bounded synchronous probe is fine here.
        if (path.contains(QLatin1String("youtube.com/watch"))
            || path.contains(QLatin1String("youtu.be/"))) {
            QProcess p;
            p.start(QStringLiteral("yt-dlp"),
                    {QStringLiteral("--no-warnings"), QStringLiteral("--print"),
                     QStringLiteral("%(live_status)s"), path});
            if (p.waitForFinished(8000)
                && p.readAllStandardOutput().trimmed() == "is_live")
                m_liveUri = canonicalYouTube(path); // play() compares canonical
        }
        play(path);
    } else if (needsMediaPaths()) {
        setStage(QStringLiteral("paths"));   // first run: where are the films?
    } else {
        m_library->rescan();
        setStage(QStringLiteral("home"));
    }
    // A fresh `codec --enqueue <files>` (or a multi-file open) that had no
    // running instance to forward to: drop the extras into the queue now that
    // the library is scanned and can enrich them.
    if (!m_pendingEnqueue.isEmpty()) {
        enqueuePaths(m_pendingEnqueue);
        m_pendingEnqueue.clear();
    }
}

void AppController::applyPlacement()
{
    if (!m_window)
        return;
    QScreen *target = nullptr;
    const auto screens = QGuiApplication::screens();
    for (QScreen *s : screens) {
        if (s->name() == m_display) {
            target = s;
            break;
        }
    }
    // Honored only while the surface is still unmapped (the CLI path).
    if (target && m_window->screen() != target)
        m_window->setScreen(target);
    m_window->showFullScreen();
    // A mapped Wayland window can't retarget itself — ask the compositor.
    // This Hyprland speaks a Lua dispatch DSL (same pattern as the AC6
    // launcher). The move names OUR window by pid: it used to act on the
    // focused one, and the remote's INPUT key moves codec from anywhere —
    // pressed over a terminal, that threw the terminal to the CRT.
    // (Never from an offscreen test run: it would move the real codec.)
    if (m_window->isVisible() && !qEnvironmentVariableIsSet("CODEC_SHOT")) {
        QProcess::startDetached(QStringLiteral("hyprctl"),
            {QStringLiteral("dispatch"),
             QStringLiteral("hl.dsp.window.move({ monitor = \"%1\", window = \"pid:%2\" })")
                 .arg(m_display).arg(QCoreApplication::applicationPid())});
    }
    moveToMediaWorkspace();
}

void AppController::moveToMediaWorkspace()
{
    // Codec is a media app: after the display choice, land on that monitor's
    // "Media" workspace (ws5 main / ws12 CRT today). Discovered live from
    // workspacerules — renumbering or renaming keeps working — and skipped
    // entirely when the monitor has no Media workspace (laptop).
    if (qEnvironmentVariableIsSet("CODEC_SHOT"))
        return; // offscreen test runs must never dispatch at the real session
    auto *p = new QProcess(this);
    connect(p, &QProcess::errorOccurred, p, &QObject::deleteLater);
    connect(p, &QProcess::finished, this, [this, p] {
        const QJsonArray arr =
            QJsonDocument::fromJson(p->readAllStandardOutput()).array();
        p->deleteLater();
        for (const QJsonValue &v : arr) {
            const QJsonObject w = v.toObject();
            if (w.value(QStringLiteral("monitor")).toString() != m_display)
                continue;
            if (!w.value(QStringLiteral("defaultName")).toString()
                     .contains(QLatin1String("media"), Qt::CaseInsensitive))
                continue;
            const QString ws =
                w.value(QStringLiteral("workspaceString")).toString();
            // codec's own window, by pid (as the monitor move above)
            QProcess::startDetached(QStringLiteral("hyprctl"),
                {QStringLiteral("dispatch"),
                 QStringLiteral("hl.dsp.window.move({ workspace = %1, window = \"pid:%2\" })")
                     .arg(ws).arg(QCoreApplication::applicationPid())});
            Logger::log(QStringLiteral("place"),
                        QStringLiteral("→ media workspace %1 on %2")
                            .arg(ws, m_display));
            break;
        }
    });
    p->start(QStringLiteral("hyprctl"),
             {QStringLiteral("workspacerules"), QStringLiteral("-j")});
}

void AppController::maybeMarkWatched()
{
    const QString p = m_engine->path();
    // idle = the file already ended naturally; endReached handled it.
    // Live streams report a DVR-window duration — no "watched" concept.
    if (p.isEmpty() || m_engine->idle() || ephemeralUri(p) || m_liveNow
        || m_engine->duration() <= 0)
        return;
    if (p == m_completedPath)
        return; // already banked when its end credits began (checkCredits)
    if (m_engine->position() / m_engine->duration() >= kWatchedPct) {
        m_store->markCompleted(playbackIdentity(p)); // the TITLE's row; rewinds position to 0
        m_library->refreshResume();
    }
}

// The OSD/PiP's name for a path: the library's pretty title (a show's episode
// carries its show), with its year — never the scene filename. "" = unknown.
void AppController::updatePlayingLogo()
{
    QString logo, line;
    const QString path = m_engine->path();
    if (!path.isEmpty()) {
        // the library's own title for this play (a road url, a warm lane or a
        // tailnet rewrite all map back to it); YouTube and a stray local file
        // have none and keep the words
        const QVariantMap e = m_library->entryForKey(playbackIdentity(path));
        const QString kind = e.value(QStringLiteral("kind")).toString();
        if (kind == QLatin1String("movie") || kind == QLatin1String("episode")) {
            logo = e.value(QStringLiteral("clearlogo")).toString();
            if (!logo.isEmpty()) {
                const int year = e.value(QStringLiteral("year")).toInt();
                if (kind == QLatin1String("episode")) {
                    // "S01E03 · Name" → S01E03 · "Name": the episode's own name
                    // in quotes, as the library and the miniplayer show it
                    line = e.value(QStringLiteral("title")).toString();
                    const qsizetype dot = line.indexOf(QStringLiteral(" · "));
                    if (dot >= 0 && dot + 3 < line.size())
                        line = line.left(dot + 3) + QLatin1Char('"')
                             + line.mid(dot + 3) + QLatin1Char('"');
                } else if (year > 0) {
                    line = QStringLiteral("(%1)").arg(year);
                }
            }
        }
    }
    if (logo == m_playingLogo && line == m_playingLogoLine)
        return;
    m_playingLogo = logo;
    m_playingLogoLine = line;
    emit playingLogoChanged();
}

QString AppController::osdTitleFor(const QString &path) const
{
    const QVariantMap info = m_library->entryInfo(path);
    QString t = info.value(QStringLiteral("title")).toString();
    if (!t.isEmpty()) {
        const QString show = info.value(QStringLiteral("show")).toString();
        if (!show.isEmpty() && !t.startsWith(show))
            t = show + QStringLiteral("  ") + t;
        const int year = info.value(QStringLiteral("year")).toInt();
        if (year > 0)
            t += QStringLiteral(" (%1)").arg(year);
    }
    return t;
}

void AppController::play(const QString &pathIn)
{
    const QString path = canonicalYouTube(pathIn);
    Logger::log(QStringLiteral("play"), path);
    // Playing something else while following a party: in a hub room that
    // moves the whole room to it (the fileLoaded hook → partyLoadMedia), so
    // hold the follower's reload off until the room has moved — or it would
    // pull this screen back to the old film. Following anyone else's room,
    // playing something else IS leaving it.
    if (m_partyFollowing && path != partyLocalFile() && !isPartyStream(path)) {
        // a trailer / search preview can't be a room's film: watching one
        // alone is leaving (it got seeked to the room's clock and "ended")
        if (partyHubMode() && !ephemeralUri(path)) {
            // the reload check is "> 10 s since": +10 s here holds it 20 s
            m_partyReloadAt = QDateTime::currentMSecsSinceEpoch() + 10000;
            m_partyViaStream = false;   // a direct play, not the room's stream
        } else {
            leaveWatchParty();
        }
    }
    // The OSD/PiP shows the library's pretty name, never the scene filename.
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine)) {
        QString t = osdTitleFor(path);
        // A live stream plays the hub's lane URL, so mpv's own title would be
        // "pl.m3u8?kind=yt&v=…" — use the item's real title.
        if (t.isEmpty() && path == m_liveUri && !m_liveTitle.isEmpty())
            t = m_liveTitle;
        mpv->setForcedTitle(t); // empty = mpv default (yt keeps real titles)
        // Prefer the viewer's audio language so an English film ripped with a
        // foreign default track (Sahara's Italian default) still plays English —
        // matches the cast worker's "preferred language first" pick.
        mpv->setAudioLang(m_audioLanguage);
    }
    // A live cast target owns non-ephemeral playback (trailers stay local —
    // a search pseudo-URL means nothing to the TV).
    if (m_cast->active() && !ephemeralUri(path)) {
        castPlay(QVariantMap{{QStringLiteral("uri"), path}});
        return;
    }

    // Bank the outgoing file first — switching mid-credits must still count.
    saveNow();
    maybeMarkWatched();
    // Push the OUTGOING YouTube video's stop position to the account so the
    // phone resumes where this session left off. Not for an outgoing LIVE
    // stream: playItem/advanceAfter already stamped m_liveUri with the NEW
    // title, so ytHistoryPing's own live guard can't see the old one —
    // m_liveNow still describes what is playing now.
    if (!m_liveNow && !m_engine->path().isEmpty() && m_engine->path() != path)
        ytHistoryPing(m_engine->path(), m_engine->position());

    // Live streams: no resume (a stored offset means nothing at the live
    // edge), no stale rows. playItem/advanceAfter stamped m_liveUri.
    const bool live = !m_liveUri.isEmpty() && path == m_liveUri;

    // STATS "PLAYS": count this play-start for real library items only — not
    // trailers/search previews (ephemeral) or live streams (no persistent row).
    // registerPlayStart's cooldown absorbs stop/restart churn on the same title.
    if (!live && !ephemeralUri(path))
        m_store->registerPlayStart(path);

    const QVariantMap st = live ? QVariantMap() : m_store->state(path);
    const double duration = st.value(QStringLiteral("duration")).toDouble();
    double start = st.value(QStringLiteral("position")).toDouble();
    // Resume only mid-file: >60s in and short of the watched zone.
    if (start < 60 || (duration > 0 && start / duration >= kWatchedPct))
        start = 0;


    // `path` stays the canonical identity (resume key, manifest match); only
    // the URL mpv actually opens is made reachable from where we are now.
    const QString playUrl = reachableHub(path);
    // A satellite that can reach NEITHER the hub's LAN nor its tailnet must not
    // hand mpv a dead http URL — it would retry forever behind a black player
    // ("resume-after-death"). Say so and bail; the next play re-probes. Only the
    // HUB's own urls: a YouTube link plays from any wifi and used to be refused
    // here too (every http url was), so roaming YouTube died with the hub.
    const bool hubUrl = path.startsWith(QLatin1String("http"))
        && (QUrl(path).host() == QUrl(m_cfgSyncUrl).host() || privateHost(QUrl(path).host()));
    // No private road but the public door answers our token: the title's own
    // file over it — full source quality (HDR, DV), the way the LAN plays it.
    // `path` still keys resume / credits / the manifest match.
    QString roadUrl;
    if (m_library->remoteMode() && hubUrl && !m_hubLanOk && !m_hubTnetOk && publicRoad())
        roadUrl = publicUrlFor(path, QStringLiteral("raw"));
    if (m_library->remoteMode() && hubUrl && !m_hubLanOk && !m_hubTnetOk && roadUrl.isEmpty()) {
        emit toast(publicRoad() ? QStringLiteral("NOT IN THE SYNCED LIBRARY · SYNC WITH THE HUB FIRST")
                                : QStringLiteral("HUB UNREACHABLE · check Tailscale / wifi, then retry"));
        return;
    }
    const int aid = st.value(QStringLiteral("aid"), -1).toInt();
    const int sid = st.value(QStringLiteral("sid"), -1).toInt();
    const double subDelay = st.value(QStringLiteral("subDelay"), 0.0).toDouble();
    const double speed = st.value(QStringLiteral("speed"), 1.0).toDouble();
    const int zoom = live ? zoomFor(QString(), m_mode) : zoomFor(path, m_mode);

    // Roaming far-resume hybrid: play the raw remux (full quality) as always,
    // but a far seek on a big remux over a thin foreign link can buffer for
    // minutes. Arm a watchdog — if playback hasn't started in 15s (or the raw
    // load errors), switch to the seekable warm-HLS lane, which starts at the
    // resume point and adapts (SDR — the tradeoff). On the hub LAN, or from the
    // start of a file, raw is unconditional.
    m_resumeWatchdog.stop();
    m_stallTimer.stop();
    m_hlsFallbackUrl.clear();
    m_fallbackViaRoad = false;
    m_resumeFellBack = false;
    // the title this play IS, whatever url mpv opens for it
    m_playIdentity = path;
    m_playUrl = roadUrl.isEmpty() ? playUrl : roadUrl;
    // The lane is ARMED for every remote raw play off the LAN (the stall
    // step-down and a failed load both reach for it); the cold-start watchdog
    // only runs for a resume, where a far seek on the remux is the known trap.
    if (m_library->remoteMode() && !m_hubLanOk
        && path.startsWith(QLatin1String("http")) && (playUrl != path || !roadUrl.isEmpty())) {
        // over the public door the warm lane is the token surface's ladder
        m_fallbackViaRoad = !roadUrl.isEmpty();
        m_hlsFallbackUrl = roadUrl.isEmpty()
            ? warmHlsUrl(path, start, duration)
            : publicUrlFor(path, QStringLiteral("hls/pl"),
                           QStringLiteral("&warm=%1&sdr=1&dur=%2")
                               .arg(int(start / 4.0)).arg(int(duration)));
        m_hlsFallbackStart = start;
        m_hlsFallbackAid = aid;
        m_hlsFallbackSid = sid;
        m_hlsFallbackSpeed = speed;
        m_hlsFallbackZoom = zoom;
        if (!m_hlsFallbackUrl.isEmpty() && start > 60)
            m_resumeWatchdog.start();
    }
    // A YouTube LIVESTREAM buffers when mpv reads YouTube's own sliding-window
    // manifest (measured: the demuxer cache drains below realtime → stalls). The
    // hub restreams a live source into a smooth rolling HLS — the SAME lane the
    // cast uses, and mpv holds a healthy buffer on it (measured). Open THAT while
    // keeping `path` as the youtube identity, so chat/history/cast are unaffected.
    // Only over a PRIVATE road: with the hub away a live stream plays straight
    // from YouTube through mpv's own hook (no DVR, the sliding-window buffering
    // the lane was built to beat — but it plays, where it used to hang on a
    // dead hub url).
    QString streamUrl;
    if (live && (m_hubLink == QLatin1String("hub") || m_hubLanOk || m_hubTnetOk)) {
        const QString ytId = youtubeIdOf(path);
        if (!ytId.isEmpty())
            streamUrl = hubBase() + QStringLiteral("/hls/pl.m3u8?kind=yt&v=")
                        + ytId + QStringLiteral("&dur=0");
    }
    // ⚠ roadUrl carries the browse token in its path: Engine.path is never
    // shown as text (the OSD title comes from osdTitleFor, MPRIS publishes the
    // title only, mpv's terminal is off) — keep it that way.
    // The subtitle nudge this film needed last time — and none at all for a
    // film that needed none (mpv would carry the previous film's over).
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine)) {
        if (!qFuzzyCompare(subDelay + 1.0, m_engine->subDelay() + 1.0))
            m_subDelayQuiet = subDelay;
        mpv->setSubDelay(subDelay);
    }
    m_engine->load(roadUrl.isEmpty() ? playUrl : roadUrl, start, aid, sid, speed, zoom, streamUrl);
    // A hub-streamed title's sidecar (fetched here or on the hub) is
    // invisible to mpv's own sub-auto over http: offer it, unselected (a
    // 404 is nothing) — the one place a satellite used to lose fetched subs.
    if (auto *mpv = qobject_cast<MpvEngine *>(m_engine);
        mpv && path.startsWith(QLatin1String("http")) && !ephemeralUri(path)) {
        const QString side = !roadUrl.isEmpty()
            ? publicUrlFor(path, QStringLiteral("sub"), QStringLiteral("&t=-2"))
            : QFileInfo(path).completeBaseName().isEmpty() ? QString()
              : path.left(path.lastIndexOf(QLatin1Char('.'))) + QStringLiteral(".en.srt");
        if (!side.isEmpty())
            mpv->addSubFile(side, /*cached=*/true, /*select=*/false);
    }
    // Announced AFTER load so listeners (the chat rail reads Engine.path)
    // see the new file, not the one this play() replaced.
    if (live != m_liveNow) {
        m_liveNow = live;
        emit liveNowChanged();
    }
    if (live)
        liveBegin();
    else
        liveReset();
    m_autoplayChain = 0; // manual play resets the chain (autoplayGo re-sets it)
    setStage(QStringLiteral("player"));
    m_saveTimer.start();
    vaultNoteKick(path);
    ytHistoryPing(path, start); // register the watch on the YouTube account
    // Keep the resume fresh only for real YouTube watch urls.
    if (path.contains(QLatin1String("youtube.com/watch"))
        || path.contains(QLatin1String("youtu.be/")))
        m_ytPingTimer.start();
    else
        m_ytPingTimer.stop();
    if (start > 0)
        emit toast(QStringLiteral("RESUMED · %1").arg(prettyTime(start)));
}

void AppController::probeMedia(const QString &path)
{
    // Local files only — a hub-streamed satellite path or a yt url has no
    // ffprobe-able file here.
    if (!path.startsWith(QLatin1Char('/')) || !QFile::exists(path))
        return;
    auto *pr = new QProcess(this);
    connect(pr, &QProcess::errorOccurred, pr, &QObject::deleteLater);
    connect(pr, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, pr, path] {
        const QJsonObject root =
            QJsonDocument::fromJson(pr->readAllStandardOutput()).object();
        pr->deleteLater();
        QVariantList audio, subs;
        QString videoRes, videoCodec;
        auto langOf = [](const QJsonObject &tags) {
            QString l = tags.value(QStringLiteral("language")).toString().toUpper();
            return (l.isEmpty() || l == QLatin1String("UND")) ? QString() : l;
        };
        for (const QJsonValue &v : root.value(QStringLiteral("streams")).toArray()) {
            const QJsonObject s = v.toObject();
            const QString type = s.value(QStringLiteral("codec_type")).toString();
            const QJsonObject tags = s.value(QStringLiteral("tags")).toObject();
            if (type == QLatin1String("audio")) {
                const int ch = s.value(QStringLiteral("channels")).toInt();
                QString layout = ch == 8 ? QStringLiteral("7.1")
                               : ch == 6 ? QStringLiteral("5.1")
                               : ch == 2 ? QStringLiteral("STEREO")
                               : ch == 1 ? QStringLiteral("MONO")
                                         : QStringLiteral("%1CH").arg(ch);
                audio.append(QVariantMap{
                    {QStringLiteral("layout"), layout},
                    {QStringLiteral("codec"),
                     s.value(QStringLiteral("codec_name")).toString().toUpper()},
                    {QStringLiteral("lang"), langOf(tags)},
                    {QStringLiteral("title"), tags.value(QStringLiteral("title")).toString()}});
            } else if (type == QLatin1String("subtitle")) {
                subs.append(QVariantMap{
                    {QStringLiteral("codec"),
                     s.value(QStringLiteral("codec_name")).toString().toUpper()},
                    {QStringLiteral("lang"), langOf(tags)},
                    {QStringLiteral("title"), tags.value(QStringLiteral("title")).toString()}});
            } else if (type == QLatin1String("video") && videoRes.isEmpty()) {
                const int w = s.value(QStringLiteral("width")).toInt();
                const int h = s.value(QStringLiteral("height")).toInt();
                if (w > 0 && h > 0)
                    videoRes = QStringLiteral("%1×%2").arg(w).arg(h);
                videoCodec = s.value(QStringLiteral("codec_name")).toString().toUpper();
            }
        }
        emit mediaProbed(path, QVariantMap{
            {QStringLiteral("audio"), audio},
            {QStringLiteral("subs"), subs},
            {QStringLiteral("videoRes"), videoRes},
            {QStringLiteral("videoCodec"), videoCodec}});
    });
    pr->start(QStringLiteral("ffprobe"),
              {QStringLiteral("-v"), QStringLiteral("quiet"),
               QStringLiteral("-print_format"), QStringLiteral("json"),
               QStringLiteral("-show_streams"), path});
}

// ── Live DVR ─────────────────────────────────────────────────────────────
// YouTube keeps ~4 h of every live broadcast in its own HLS playlist, but a
// sliding live playlist cannot be seeked by ffmpeg (no ENDLIST) and played
// directly it stutters (measured — hence the hub restream at the live edge).
// So: the live edge stays on the hub lane; a rewind writes a SNAPSHOT of
// YouTube's playlist with #EXT-X-ENDLIST to $XDG_RUNTIME_DIR and plays that —
// an ordinary seekable 4-hour file. Catching up (or the snapshot running out)
// returns to the lane. Quality is the same 1080p either way: YouTube serves
// live HLS no higher (1440p/4K exist only as DASH VP9).

static double nowS() { return QDateTime::currentMSecsSinceEpoch() / 1000.0; }

void AppController::liveReset()
{
    m_liveTick.stop();
    if (m_liveResolve) {
        m_liveResolve->disconnect(this);
        m_liveResolve->kill();
        m_liveResolve->deleteLater();
        m_liveResolve = nullptr;
    }
    const bool had = m_liveDvr || m_dvrWindow > 0 || m_liveStartTs > 0;
    // The last snapshot goes with the broadcast (it lives in tmpfs).
    if (m_dvrSnapSeq > 0)
        QFile::remove(QStringLiteral("%1/codec-dvr-%2-%3.m3u8")
                          .arg(QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation))
                          .arg(QCoreApplication::applicationPid()).arg(m_dvrSnapSeq));
    m_liveDvr = false;
    m_liveVariant.clear();
    m_liveStartTs = 0;
    m_dvrWindow = m_dvrSnapDur = 0;
    m_dvrWindowAtMs = m_dvrSnapAtMs = 0;
    m_liveWatchedMs = 0;
    if (had)
        emit liveStateChanged();
}

void AppController::liveBegin()
{
    liveReset();
    m_liveWatchClock.start();
    m_liveTick.start();
    const QString url = m_liveUri;
    if (url.isEmpty())
        return;
    // yt-dlp once per broadcast: the variant playlist (DVR source), the real
    // broadcast start ("LIVE FOR"), and the title when the item had none
    // (a pasted / CLI link). Best muxed HLS = what the hub lane carries.
    m_liveResolve = new QProcess(this);
    QStringList args{QStringLiteral("--no-warnings"),
                     QStringLiteral("-f"), QStringLiteral("b[protocol*=m3u8]/b"),
                     QStringLiteral("--print"), QStringLiteral("%(release_timestamp)s"),
                     QStringLiteral("--print"), QStringLiteral("%(title)s"),
                     QStringLiteral("--print"), QStringLiteral("%(url)s"), url};
    const QString jar = QDir::home().filePath(QStringLiteral(".cache/codec/ytcookies.txt"));
    if (QFile::exists(jar))
        args.prepend(jar), args.prepend(QStringLiteral("--cookies"));
    connect(m_liveResolve, &QProcess::finished, this, [this, url](int code) {
        QProcess *p = m_liveResolve;
        m_liveResolve = nullptr;
        if (!p)
            return;
        const QStringList lines = QString::fromUtf8(p->readAllStandardOutput())
                                      .split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        p->deleteLater();
        if (code != 0 || lines.size() < 3 || !m_liveNow || m_liveUri != url) {
            Logger::log(QStringLiteral("live"), QStringLiteral("resolve failed (%1)").arg(code));
            return;
        }
        bool ok = false;
        const qint64 ts = lines[0].trimmed().toLongLong(&ok);
        m_liveStartTs = ok ? ts : 0;
        if (m_liveTitle.isEmpty() && !lines[1].trimmed().isEmpty()) {
            m_liveTitle = lines[1].trimmed();
            if (auto *mpv = qobject_cast<MpvEngine *>(m_engine))
                mpv->setForcedTitle(m_liveTitle);
        }
        m_liveVariant = lines[2].trimmed();
        Logger::log(QStringLiteral("live"),
                    QStringLiteral("dvr source ready · started %1").arg(m_liveStartTs));
        liveFetchWindow([this](const QByteArray &) { emit liveStateChanged(); });
    });
    m_liveResolve->start(QStringLiteral("yt-dlp"), args);
}

// GET the variant playlist; sets m_dvrWindow (sum of EXTINF) and hands the
// body on. One fetch serves both the window size and a snapshot.
void AppController::liveFetchWindow(std::function<void(const QByteArray &)> done)
{
    if (m_liveVariant.isEmpty() || !m_nam)
        return;
    QNetworkRequest req{QUrl(m_liveVariant)};
    req.setHeader(QNetworkRequest::UserAgentHeader,
                  QStringLiteral("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0"));
    req.setTransferTimeout(15000);
    QNetworkReply *r = m_nam->get(req);
    const QString forUri = m_liveUri;
    connect(r, &QNetworkReply::finished, this, [this, r, done, forUri] {
        r->deleteLater();
        if (r->error() != QNetworkReply::NoError || !m_liveNow || m_liveUri != forUri) {
            Logger::log(QStringLiteral("live"), QStringLiteral("playlist fetch failed: %1").arg(r->errorString()));
            return;
        }
        const QByteArray body = r->readAll();
        double total = 0;
        for (const QByteArray &line : body.split('\n'))
            if (line.startsWith("#EXTINF:"))
                total += line.mid(8).split(',').value(0).toDouble();
        if (total <= 0)
            return;
        m_dvrWindow = total;
        m_dvrWindowAtMs = QDateTime::currentMSecsSinceEpoch();
        done(body);
    });
}

double AppController::liveWindow() const
{
    if (!m_liveNow)
        return 0;
    const double base = m_liveDvr ? m_dvrSnapDur : m_dvrWindow;
    const qint64 at = m_liveDvr ? m_dvrSnapAtMs : m_dvrWindowAtMs;
    if (base <= 0)
        return 0;
    // A full window (YouTube keeps ~4 h) slides; a young broadcast's grows.
    if (base >= 14000)
        return base;
    return base + qMax(0.0, nowS() - at / 1000.0);
}

double AppController::livePos() const
{
    if (!m_liveNow)
        return 0;
    return m_liveDvr ? m_engine->position() : liveWindow();
}

double AppController::liveBehind() const
{
    return qMax(0.0, liveWindow() - livePos());
}

double AppController::liveWatched() const
{
    return m_liveWatchedMs / 1000.0;
}

double AppController::liveFor() const
{
    return m_liveStartTs > 0 ? qMax(0.0, nowS() - double(m_liveStartTs)) : 0;
}

void AppController::liveSeekFrac(double frac)
{
    const double w = liveWindow();
    if (w <= 0) {
        emit toast(QStringLiteral("REWIND NOT READY YET"));
        return;
    }
    const double behind = (1.0 - qBound(0.0, frac, 1.0)) * w;
    if (behind < 12.0)
        goLive();
    else
        liveEnterDvr(behind);
}

void AppController::liveSeekBy(double seconds)
{
    const double w = liveWindow();
    if (w <= 0) {
        if (seconds < 0)
            emit toast(QStringLiteral("REWIND NOT READY YET"));
        return;
    }
    const double behind = qMin(w, liveBehind() - seconds);
    if (behind < 12.0) {
        goLive();
        return;
    }
    // Inside the loaded snapshot: an ordinary seek, no reload.
    if (m_liveDvr) {
        const double target = m_engine->position() + seconds;
        if (target >= 0 && target < m_dvrSnapDur - 5.0) {
            m_engine->seekAbs(target);
            return;
        }
    }
    liveEnterDvr(behind);
}

void AppController::liveEnterDvr(double behind)
{
    if (m_liveVariant.isEmpty()) {
        emit toast(QStringLiteral("REWIND NOT READY YET"));
        return;
    }
    liveFetchWindow([this, behind](const QByteArray &body) {
        QByteArray snap = body;
        if (!snap.contains("#EXT-X-ENDLIST")) {
            if (!snap.endsWith('\n'))
                snap += '\n';
            snap += "#EXT-X-ENDLIST\n";
        }
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
        // Per-process names: two codecs (or a test instance) must never
        // rewrite each other's snapshot mid-playback.
        const qint64 pid = QCoreApplication::applicationPid();
        const QString prev = QStringLiteral("%1/codec-dvr-%2-%3.m3u8").arg(dir).arg(pid).arg(m_dvrSnapSeq);
        const QString file = QStringLiteral("%1/codec-dvr-%2-%3.m3u8").arg(dir).arg(pid).arg(++m_dvrSnapSeq);
        QFile f(file);
        if (!f.open(QIODevice::WriteOnly)) {
            emit toast(QStringLiteral("REWIND FAILED"));
            return;
        }
        f.write(snap);
        f.close();
        QFile::remove(prev);
        const double dur = m_dvrWindow;
        const double target = qMax(0.0, dur - behind);
        m_liveDvr = true;
        m_dvrSnapDur = dur;
        m_dvrSnapAtMs = m_dvrWindowAtMs;
        Logger::log(QStringLiteral("live"),
                    QStringLiteral("dvr: %1 s behind (snapshot %2 s)")
                        .arg(qRound(behind)).arg(qRound(dur)));
        m_engine->load(m_liveUri, target, -1, -1, 1.0, m_engine->zoomMode(), file);
        emit liveStateChanged();
    });
}

void AppController::goLive()
{
    if (!m_liveNow)
        return;
    if (!m_liveDvr) {
        emit liveStateChanged();
        return;
    }
    m_liveDvr = false;
    const QString ytId = youtubeIdOf(m_liveUri);
    const QString lane = ytId.isEmpty() ? QString()
        : hubBase() + QStringLiteral("/hls/pl.m3u8?kind=yt&v=") + ytId + QStringLiteral("&dur=0");
    Logger::log(QStringLiteral("live"), QStringLiteral("back to live"));
    m_engine->load(m_liveUri, 0, -1, -1, 1.0, m_engine->zoomMode(), lane);
    emit toast(QStringLiteral("LIVE"));
    emit liveStateChanged();
}

// Spare n's job, from settings.remoteSpares (missing / short list = defaults,
// matching the author's final label sheet, 2026-10-04: SCREEN MODE · SUBTITLES ·
// AUDIO TRACK · TRAILER · SLEEP · WATCH PARTY · CAST · RESUME · DEVICE · OUTPUT).
QString AppController::spareAction(int n) const
{
    static const QStringList kDefaults{
        QStringLiteral("screen"), QStringLiteral("subs"), QStringLiteral("audio"),
        QStringLiteral("trailer"), QStringLiteral("sleep"), QStringLiteral("party"),
        QStringLiteral("cast"), QStringLiteral("resume"), QStringLiteral("device"),
        QStringLiteral("output")};
    const QStringList cfg = m_settings.value(QStringLiteral("remoteSpares")).toStringList();
    const QString a = n < cfg.size() ? cfg[n].trimmed().toLower() : QString();
    return a.isEmpty() ? kDefaults.value(n, QStringLiteral("none")) : a;
}

QString AppController::colorAction(int n) const
{
    const QStringList cfg = m_settings.value(QStringLiteral("remoteColors")).toStringList();
    const QString a = n < cfg.size() ? cfg[n].trimmed().toLower() : QString();
    return a.isEmpty() ? QStringLiteral("none") : a;
}

// ── Settings → REMOTE: the configurable keys as rows ─────────────────────────
// The action vocabulary remoteKeyAction() understands, in the order a Left/Right
// walk visits it, with the words the rows show. "none" first so an unassigned
// key is one step back from anything.
namespace {
const Labeled kRemoteActions[] = {
    {"none",    "UNASSIGNED"},  {"screen", "SCREEN MODE"}, {"subs",   "SUBTITLES"},
    {"audio",   "AUDIO TRACK"}, {"cast",   "CAST"},        {"output", "OUTPUT"},
    {"device",  "OTHER SCREEN"},{"party",  "WATCH PARTY"}, {"sleep",  "SLEEP TIMER"},
    {"trailer", "TRAILER"},     {"resume", "RESUME (HOLD)"},{"queue", "ADD TO QUEUE"},
};
// What the OFA's touchscreen label sheet PRINTS on each spare (the author's final
// sheet, 2026-10-04) — shown on a remapped row so the printed word and the
// job it now does can be told apart.
const char *kSparePrinted[10] = {"SCREEN MODE", "SUBTITLES", "AUDIO TRACK", "TRAILER",
                                 "SLEEP", "WATCH PARTY", "CAST", "RESUME", "DEVICE", "OUTPUT"};
const char *kColorNames[4] = {"RED", "GREEN", "YELLOW", "BLUE"};
} // namespace

QVariantList AppController::remoteActions() const
{
    QVariantList out;
    for (const auto &a : kRemoteActions)
        out.append(QVariantMap{{QStringLiteral("key"), QString::fromLatin1(a.key)},
                               {QStringLiteral("label"), QString::fromLatin1(a.label)}});
    return out;
}

QVariantList AppController::remoteMap() const
{
    QVariantList out;
    for (int n = 0; n < 14; ++n) {
        const bool spare = n < 10;
        const QString action = spare ? spareAction(n) : colorAction(n - 10);
        out.append(QVariantMap{
            {QStringLiteral("slot"), n},
            {QStringLiteral("name"), spare ? QStringLiteral("SPARE %1").arg(n + 1)
                                           : QString::fromLatin1(kColorNames[n - 10])},
            {QStringLiteral("printed"), spare ? QString::fromLatin1(kSparePrinted[n]) : QString()},
            {QStringLiteral("action"), action},
            {QStringLiteral("label"), labelFor(kRemoteActions, action, action.toUpper())}});
    }
    return out;
}

void AppController::setRemoteSlot(int slot, const QString &action)
{
    if (slot < 0 || slot >= 14)
        return;
    const bool spare = slot < 10;
    const int count = spare ? 10 : 4;
    const int at = spare ? slot : slot - 10;
    // Write the WHOLE list from the effective actions, not just the one entry:
    // a partial list on disk (the defaults filling the rest) would otherwise
    // shift the moment a later slot is set.
    QStringList list;
    for (int i = 0; i < count; ++i)
        list.append(spare ? spareAction(i) : colorAction(i));
    list[at] = action.trimmed().toLower();
    saveSetting(spare ? QStringLiteral("remoteSpares") : QStringLiteral("remoteColors"), list);
    emit remoteMapChanged();
    const QString who = spare ? QStringLiteral("SPARE %1").arg(slot + 1)
                              : QString::fromLatin1(kColorNames[slot - 10]);
    emit toast(who + QStringLiteral(" ▸ ") + labelFor(kRemoteActions, list[at], list[at].toUpper()));
}

void AppController::stepRemoteSlot(int slot, int dir)
{
    if (slot < 0 || slot >= 14)
        return;
    const QString cur = slot < 10 ? spareAction(slot) : colorAction(slot - 10);
    setRemoteSlot(slot, nextKey(kRemoteActions, cur, dir));
}

void AppController::setPartyName(const QString &name)
{
    const QString n = name.trimmed().left(24);
    if (n == m_settings.value(QStringLiteral("partyName")).toString().trimmed())
        return;
    saveSetting(QStringLiteral("partyName"), n);
    emit partyNameChanged();
    emit toast(n.isEmpty() ? QStringLiteral("PARTY NAME ▸ DEFAULT")
                           : QStringLiteral("PARTY NAME ▸ ") + n.toUpper());
}

QVariantMap AppController::hubLinks()
{
    loadHubConfig();   // Settings opens: pick up a hand-edit since launch
    QVariantMap out;
    out.insert(QStringLiteral("role"), deviceRole());
    out.insert(QStringLiteral("link"), m_hubLink);
    out.insert(QStringLiteral("lan"), m_cfgSyncUrl);
    out.insert(QStringLiteral("tailnet"), m_cfgTailnet);
    out.insert(QStringLiteral("funnel"), m_cfgFunnel);
    out.insert(QStringLiteral("direct"), m_cfgDirect);
    out.insert(QStringLiteral("token"), !m_hubToken.isEmpty());
    out.insert(QStringLiteral("tokenDays"),
               m_hubToken.isEmpty() ? 0
                   : int((m_hubTokenExp - QDateTime::currentSecsSinceEpoch()) / 86400));
    out.insert(QStringLiteral("manifest"), m_library ? m_library->manifestPath() : QString());
    return out;
}

QVariantMap AppController::artCacheInfo() const
{
    qint64 bytes = 0;
    int files = 0;
    QDirIterator it(QDir::homePath() + QStringLiteral("/.cache/codec/art"),
                    QDir::Files | QDir::NoDotAndDotDot);
    while (it.hasNext()) {
        it.next();
        ++files;
        bytes += it.fileInfo().size();
    }
    return QVariantMap{{QStringLiteral("files"), files},
                       {QStringLiteral("bytes"), double(bytes)}};
}

void AppController::remoteSpare(int n, bool isPress, bool repeat)
{
    remoteKeyAction(spareAction(n), QStringLiteral("SPARE %1").arg(n + 1), isPress, repeat);
}

// One configurable remote key. Actions: screen · subs · audio (cast-aware) ·
// cast · trailer · output · device · party · sleep · resume (hold) · queue · none.
void AppController::remoteKeyAction(const QString &a, const QString &name,
                                    bool isPress, bool repeat)
{
    if (repeat)
        return;
    if (a == QLatin1String("resume")) {            // tap = hint, hold = resume last HERE
        if (isPress) {
            m_remoteHoldAction = HoldResume; m_remoteHeldDone = false; m_remoteHoldTimer.start();
        } else {
            m_remoteHoldTimer.stop();
            if (!m_remoteHeldDone && m_remoteHoldAction == HoldResume)
                emit toast(QStringLiteral("HOLD TO RESUME LAST"));
            m_remoteHoldAction = HoldNone;
        }
        return;
    }
    if (!isPress)
        return;
    const bool inPlayer = (m_stage == QLatin1String("player"));
    if (a == QLatin1String("screen")) {
        if (m_cast->active()) castCycleScreenMode(); else if (inPlayer) m_engine->cycleZoomMode();
    } else if (a == QLatin1String("subs")) {
        if (m_cast->active()) castToggleSub(); else if (inPlayer) m_engine->cycleSub();
    } else if (a == QLatin1String("audio")) {
        if (m_cast->active()) castCycleAudio(); else if (inPlayer) m_engine->cycleAudio();
    }
    else if (a == QLatin1String("cast"))     remoteResumeLast(/*toCast=*/true);
    else if (a == QLatin1String("trailer"))  emit trailerRequested();
    else if (a == QLatin1String("output"))   setOutputOpen(!m_outputOpen);
    else if (a == QLatin1String("party"))    remoteWatchParty();
    else if (a == QLatin1String("sleep"))    remoteSleepCycle();
    else if (a == QLatin1String("queue"))    emit queueAddRequested();
    else if (a == QLatin1String("device")) {
        // Bring what the OTHER codec is playing onto THIS screen (it stops
        // there) — the remote is paired to both machines.
        if (m_nowElsewhere) resumeHere();
        else emit toast(QStringLiteral("NOTHING PLAYING ON THE OTHER SCREEN"));
    } else
        emit toast(name + QStringLiteral(" · UNASSIGNED"));
}

// WATCH PARTY spare: in a party → its panel; playing solo → start one for
// what's on; nothing playing → open the panel (join / start from there).
void AppController::remoteWatchParty()
{
    if (m_partyHosting || m_partyFollowing || m_partyViaCast) {
        setPartyOpen(!m_partyOpen);
        return;
    }
    if (!m_engine->idle() && !m_engine->path().isEmpty()) {
        startWatchParty();
        return;
    }
    setPartyOpen(true);
}

// OK, as the remote does it: bare player = play/pause, anywhere else Enter on
// the selection (a tap — the views open on Enter's release).
void AppController::remoteOk()
{
    if (m_castCreditsPending) { // the TV's UP NEXT card: OK = next now
        castCreditsGo();
        return;
    }
    const bool overlay = m_queueOpen || m_searchOpen || m_partyOpen;
    if (m_stage == QLatin1String("player") && !overlay && !m_playerPrompt)
        playPause();
    else
        sendKey(Qt::Key_Return);
}

// Back = Esc to the focused view (or "watch the credits" while the TV's UP NEXT
// card is up) — the mouse's thumb button and the remote's Back tap alike. Then
// record what it closed so Forward can go back in: a bonus page, a detail page,
// or the stage it walked out of. All three are synchronous (sendEvent), so the
// state read straight after Esc is the state Esc left.
void AppController::mouseBack()
{
    if (m_castCreditsPending) {
        castCreditsCancel();
        return;
    }
    const QString stage = m_stage;
    const QString section = m_library->section();
    const QString detail = m_detailUri;
    const bool bonus = m_detailBonus;
    m_inMouseNav = true;
    sendKey(Qt::Key_Escape);
    m_inMouseNav = false;
    FwdStep step;
    if (bonus && !m_detailBonus && m_detailUri == detail) {
        step.kind = QStringLiteral("bonus");         // bonus page -> its title's page
        step.target = detail;
    } else if (bonus && !detail.isEmpty() && m_detailUri.isEmpty()) {
        // A bonus page opened straight from the grid goes straight back to it;
        // Forward re-opens it the same way (the detail page takes the request).
        step.kind = QStringLiteral("bonus");
        step.target = detail;
    } else if (!detail.isEmpty() && m_detailUri.isEmpty()) {
        step.kind = QStringLiteral("detail");
        step.target = detail;
    } else if (m_stage != stage) {
        step.kind = QStringLiteral("stage");
        step.target = stage;
        step.section = section;
    } else {
        return; // Esc closed nothing we can re-enter (a menu, a search box)
    }
    step.landStage = m_stage;
    step.landDetail = m_detailUri;
    step.landBonus = m_detailBonus;
    m_fwd.append(step);
    if (m_fwd.size() > 16)
        m_fwd.removeFirst();
}

// Forward = browser-style: re-enter what Back just left — a YouTube
// channel/playlist first, else the last thing Back closed (only while still
// standing where that Back landed, so it never jumps somewhere stale; any
// other move forgets the history).
void AppController::mouseForward()
{
    if (m_stage == QLatin1String("youtube") && m_youtube && m_youtube->goForward()) {
        if (m_sfx) m_sfx->play(QStringLiteral("open"));
        return;
    }
    if (m_fwd.isEmpty())
        return;
    const FwdStep step = m_fwd.last();
    if (m_stage != step.landStage || m_detailUri != step.landDetail
        || m_detailBonus != step.landBonus) {
        m_fwd.clear();
        return;
    }
    m_fwd.removeLast();
    if (m_sfx) m_sfx->play(QStringLiteral("open"));
    struct NavGuard { bool &f; NavGuard(bool &x) : f(x) { f = true; } ~NavGuard() { f = false; } } guard(m_inMouseNav);
    if (step.kind == QLatin1String("bonus")) {
        emit detailBonusRequested(step.target);
        return;
    }
    if (step.kind == QLatin1String("detail")) {
        setDetailUri(step.target);
        return;
    }
    const QString &to = step.target;
    if (to == QLatin1String("player"))
        toPlayer();
    else if (to == QLatin1String("home") && !m_display.isEmpty())
        goHome(); // display picker -> back in; Back never changed the display
    else if (to == QLatin1String("library"))
        openSection(step.section);
    else if (to == QLatin1String("youtube") || to == QLatin1String("settings")
             || to == QLatin1String("stats"))
        openSection(to);
}

void AppController::ytHistoryPing(const QString &uri, double pos)
{
    // Only real YouTube videos (not trailer pseudo-searches or local files).
    const QString canon = canonicalYouTube(uri);
    if (!canon.contains(QLatin1String("youtube.com/watch")))
        return;
    // Live streams have no watch position to record, and pinging one every
    // 30 s only adds noise to the account's history.
    if (m_liveUri == canon || m_liveUri == uri)
        return;
    Logger::log(QStringLiteral("ythist"),
                QStringLiteral("%1 @ %2s").arg(canon).arg(qRound(pos)));
    if (m_youtube) {
        m_youtube->watchPing(canon, pos);
        return;
    }
    const QString worker = codecScript(QStringLiteral("codec_yt.py"));
    if (QFile::exists(worker))
        QProcess::startDetached(QStringLiteral("/usr/bin/python3"),
                                {worker, QStringLiteral("--watch"), canon,
                                 QString::number(qMax(0.0, pos), 'f', 1)});
}

void AppController::vaultNoteKick(const QString &path)
{
    // Reviews happen mid-watch: the vault note must exist the moment
    // playback starts, not at the nightly sync. Detached fire-and-forget —
    // never allowed to slow the playback path.
    if (!path.startsWith(QLatin1Char('/')))
        return;
    // Obsidian notes are opt-in (Settings ▸ SYSTEM, experimental): the sync
    // writes into ~/Documents/Obsidian Vault — Obsidian's DEFAULT vault name,
    // so on anyone else's machine it would have filled their vault.
    if (!m_settings.value(QStringLiteral("vaultNotes"), false).toBool())
        return;
    const QString script = codecScript(QStringLiteral("codec_vault_sync.py"));
    if (!QFile::exists(script))
        return; // satellites without the vault pipeline just skip
    QProcess::startDetached(QStringLiteral("/usr/bin/python3"),
                            {script, QStringLiteral("--apply"),
                             QStringLiteral("--path"), path});
}

void AppController::reconcileLibrary()
{
    if (m_artFetch && m_artFetch->state() != QProcess::NotRunning)
        return; // a reconcile is already in flight; its finish will re-scan

    // Automatic (scan-driven) enrichment obeys the AUTO-UPDATE setting; a manual
    // UPDATE LIBRARY (m_manualUpdate) always runs, off or not.
    if (!m_manualUpdate && autoUpdate() == QLatin1String("off"))
        return;

    // Act only on paths we have NOT already tried. Without this an item TMDB
    // can't match (or an orphan a guard-aborted prune left) stays out of step
    // forever, so every rescan — including the one we trigger on completion —
    // would re-fire the job in an infinite loop.
    QStringList fresh;
    for (const QString &p : m_library->unscrapedPaths())
        if (!m_reconcileAttempted.contains(p))
            fresh.append(p);
    const int adds = fresh.size();
    for (const QString &p : m_library->orphanPaths())
        if (!m_reconcileAttempted.contains(p))
            fresh.append(p);
    // A manual UPDATE LIBRARY runs the pipeline even when nothing on disk is new:
    // a title that already has a metadata row but is MISSING art (the common case
    // is a clearlogo — fanart.tv adds them out of band, so the original scrape had
    // none) is invisible to the unscraped/orphan sets, and re-filling it on demand
    // is the whole point of the button. codec_reconcile.sh's logo step is
    // idempotent + negative-cached, so an already-complete library exits fast. The
    // fetch's finished handler clears m_manualUpdate before its own rescan, so the
    // second pass falls through here and this cannot loop.
    if (fresh.isEmpty() && !m_manualUpdate)
        return;
    for (const QString &p : fresh)
        m_reconcileAttempted.insert(p);

    Logger::log(QStringLiteral("art"),
                QStringLiteral("reconcile: %1 new, %2 removed")
                    .arg(adds).arg(fresh.size() - adds));
    // Pixel-test harness scans the real (already-consistent) library; never let
    // a headless shot spawn a network scrape.
    if (!qEnvironmentVariable("CODEC_SHOT").isEmpty())
        return;

    const QString script = codecScript(QStringLiteral("codec_reconcile.sh"));
    if (!QFile::exists(script))
        return; // satellite without the pipeline — nothing to do

    if (!m_artFetch) {
        m_artFetch = new QProcess(this);
        connect(m_artFetch,
                QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this](int code, QProcess::ExitStatus) {
            Logger::log(QStringLiteral("art"),
                        QStringLiteral("fetch done rc=%1").arg(code));
            setLibraryUpdating(false);
            m_manualUpdate = false;
            if (code == 0) {
                emit toast(QStringLiteral("LIBRARY UPDATED"));
                m_library->rescan(); // re-merge; reconciled items drop out of
                                     // both sets, so this can't re-loop
            } else {
                emit toast(QStringLiteral("LIBRARY SYNC FAILED — CHECK TMDB KEY"));
            }
        });
    }
    setLibraryUpdating(true, adds);
    emit toast(adds > 0 ? QStringLiteral("UPDATING LIBRARY · %1 NEW…").arg(adds)
                        : QStringLiteral("TIDYING LIBRARY…"));
    m_artFetch->start(QStringLiteral("bash"), {script});
}

void AppController::setLibraryUpdating(bool on, int newCount)
{
    m_enrichCount = on ? newCount : 0;
    m_libraryUpdating = on;
    emit libraryUpdatingChanged(); // also carries libraryNewCount
}

void AppController::updateLibrary()
{
    // Manual full update. Clearing the attempted-guard is the point: a title
    // whose scrape was slow or failed (or an orphan a guard-aborted prune left)
    // stays out of step forever otherwise — the exact case you reach for this.
    m_reconcileAttempted.clear();
    m_manualUpdate = true;
    emit toast(QStringLiteral("CHECKING LIBRARY…"));
    pullLibrary();       // satellite: fetch the hub's latest manifest + art (no-op on the hub)
    m_library->rescan(); // hub: reconcileNeeded (if anything's out of step) enriches
}

void AppController::newFilesArrived()
{
    // Not updateLibrary(): no forced art refetch, no "CHECKING" toast — the
    // scan finds the new title and reconcileNeeded scrapes it like any other.
    Logger::log(QStringLiteral("scan"), QStringLiteral("new files arrived — rescanning"));
    m_library->rescan();
}

// ── is each file what codec says it is? ─────────────────────────────────────
// Identification is a chain of guesses: a folder name is parsed into a title,
// the title is searched on TMDB, and the top hit is taken as the answer. Every
// link fails quietly, and a wrong match looks exactly like a right one —
// poster, plot and cast, all confidently wrong. Nothing in the library ever
// disagrees with itself, so nothing surfaces on its own.
//
// codec_library_audit.py is the thing that can disagree. It runs OUT of
// process and READ-ONLY: it changes nothing, so this button is always safe to
// press. Durations are cached, so only the first run is slow.
void AppController::auditLibrary()
{
    if (m_libraryAuditing)
        return;
    const QString script = codecScript(QStringLiteral("codec_library_audit.py"));
    if (!QFile::exists(script)) {
        emit toast(QStringLiteral("AUDIT SCRIPT NOT INSTALLED"));
        return;
    }
    m_libraryAuditing = true;
    m_libraryAuditResult = QStringLiteral("checking…");
    emit libraryAuditChanged();
    emit toast(QStringLiteral("AUDITING LIBRARY…"));

    auto *p = new QProcess(this);
    connect(p, &QProcess::errorOccurred, this, [this, p] {
        p->deleteLater();
        m_libraryAuditing = false;
        m_libraryAuditResult = QStringLiteral("could not run");
        emit libraryAuditChanged();
    });
    connect(p, &QProcess::finished, this, [this, p](int, QProcess::ExitStatus) {
        const QJsonObject o =
            QJsonDocument::fromJson(p->readAllStandardOutput()).object();
        p->deleteLater();
        m_libraryAuditing = false;
        const int urgent = o.value(QStringLiteral("urgent")).toInt();
        const int cuts = o.value(QStringLiteral("cuts")).toInt();
        if (o.isEmpty()) {
            m_libraryAuditResult = QStringLiteral("audit failed");
        } else if (urgent == 0) {
            // Say "nothing wrong" as plainly as "3 problems" — an audit that
            // only speaks up when it is unhappy leaves you unsure it ran.
            m_libraryAuditResult = cuts > 0
                ? QStringLiteral("all %1 titles check out · %2 alternate cut(s)")
                      .arg(o.value(QStringLiteral("movies")).toInt()).arg(cuts)
                : QStringLiteral("all %1 titles check out")
                      .arg(o.value(QStringLiteral("movies")).toInt());
        } else {
            QStringList bits;
            const auto add = [&](const char *k, const char *label) {
                const int n = o.value(QLatin1String(k)).toInt();
                if (n > 0)
                    bits << QStringLiteral("%1 %2").arg(n).arg(QLatin1String(label));
            };
            add("runtime", "wrong film?");
            add("year", "wrong year");
            add("missing", "no metadata");
            add("title", "junk title");
            add("unnumbered", "unnumbered ep");
            m_libraryAuditResult = bits.join(QStringLiteral(" · "));
        }
        emit libraryAuditChanged();
        emit toast(urgent == 0 ? QStringLiteral("LIBRARY CLEAN")
                               : QStringLiteral("AUDIT: %1 TO LOOK AT").arg(urgent));
        Logger::log(QStringLiteral("audit"), m_libraryAuditResult);
    });
    p->start(QStringLiteral("/usr/bin/python3"),
             {script, QStringLiteral("--json")});
}

void AppController::onLibraryScanned()
{
    if (!m_manualUpdate)
        return;
    // scanned() and reconcileNeeded() are emitted back-to-back inside
    // setEntries(); defer one event-loop turn so reconcileLibrary has had its
    // chance to start. If nothing did, the library was already complete —
    // confirm it so the button never feels dead.
    QTimer::singleShot(0, this, [this] {
        if (m_manualUpdate && !m_libraryUpdating) {
            emit toast(QStringLiteral("LIBRARY UP TO DATE"));
            m_manualUpdate = false;
        }
    });
}

QString AppController::autoUpdate() const
{
    const QString v = m_settings.value(QStringLiteral("autoUpdate"),
                                       QStringLiteral("live")).toString();
    if (v == QLatin1String("off") || v == QLatin1String("launch")
        || v == QLatin1String("live"))
        return v;
    return QStringLiteral("live");
}

void AppController::applyAutoUpdate()
{
    m_library->setLiveWatch(autoUpdate() == QLatin1String("live"));
}

void AppController::cycleAutoUpdate(int dir)
{
    static const char *steps[] = {"off", "launch", "live"};
    const QString cur = autoUpdate();
    int idx = 2;
    for (int i = 0; i < 3; ++i)
        if (cur == QLatin1String(steps[i])) { idx = i; break; }
    const QString next = QLatin1String(steps[wrapStep(idx, 3, dir)]);
    saveSetting(QStringLiteral("autoUpdate"), next);
    applyAutoUpdate();
    emit autoUpdateChanged();
    emit toast(next == QLatin1String("off")
                   ? QStringLiteral("AUTO-UPDATE ▸ OFF  ·  update manually (F5)")
               : next == QLatin1String("launch")
                   ? QStringLiteral("AUTO-UPDATE ▸ ON LAUNCH")
                   : QStringLiteral("AUTO-UPDATE ▸ LIVE  ·  watches for new files"));
}

bool AppController::ephemeralUri(const QString &uri)
{
    // Trailer lookups play through mpv's ytdl hook via a search pseudo-URL;
    // recording resume/watched rows for those would be junk. So would a watch
    // party's stream (`…/p/<token>/hls/…`, a screen without the film): its
    // "path" is the room, not a title — it left a `p/<token>/hls/pl` row.
    return uri.startsWith(QLatin1String("ytdl://ytsearch"))
        || (uri.contains(QLatin1String("/p/")) && uri.contains(QLatin1String("/hls/")));
}

void AppController::advanceAfter(const QString &finished)
{
    // #32 / mixed-queue auto-advance: in a party-via-cast the TV is a room
    // FOLLOWER on the host's own cast lane. The queue DOES advance — but "advance"
    // means moving the whole room to the next item (re-cast the host TV AND
    // op:media so followers switch), never a local play() or a solo castPlay()
    // (which would yank the TV off the room, the old Transformers tangle).
    // partyAdvanceCast() does both, for any kind — a DV/HDR/SDR/YouTube queue
    // plays straight through. (This used to just hold the queue.) RepeatOne
    // re-casts the same item to the room.
    if (m_partyViaCast && m_queue->repeatMode() == QueueModel::RepeatOne) {
        partyAdvanceCast(QVariantMap{{QStringLiteral("uri"), finished}});
        return;
    }
    if (m_queue->repeatMode() == QueueModel::RepeatOne) {
        play(finished);
        return;
    }
    // The queue is the single advance authority. When it's empty, an
    // episode auto-chains to the next one in its show (Netflix-style).
    QVariantMap next;
    if (m_queue->count() > 0) {
        if (m_queue->repeatMode() == QueueModel::RepeatAll) {
            // Re-add with the FULL MediaItem contract, not just {uri,title}.
            // Stripping durationS/kind/artUrl collapsed totalDuration() to 0,
            // dropped the thumbnail, and (missing kind='episode') made the
            // re-added row skip the countdown/ask on the next lap. Rebuild the
            // metadata from the library + resume store so a RepeatAll loop looks
            // identical on every pass.
            QVariantMap again{
                {QStringLiteral("uri"), finished},
                {QStringLiteral("title"), m_cast->active() ? m_cast->castTitle()
                                                           : m_engine->mediaTitle()}};
            const QVariantMap info = m_library->entryInfo(finished);
            if (!info.isEmpty()) {
                again.insert(QStringLiteral("kind"), info.value(QStringLiteral("kind")));
                again.insert(QStringLiteral("subtitle"),
                             info.value(QStringLiteral("subtitle")));
                again.insert(QStringLiteral("artUrl"),
                             info.value(QStringLiteral("poster")));
            }
            double dur = m_store->state(finished)
                             .value(QStringLiteral("duration")).toDouble();
            if (dur <= 0)
                dur = m_cast->active() ? m_cast->castDuration()
                                       : m_engine->duration();
            if (dur > 0)
                again.insert(QStringLiteral("durationS"), dur);
            if (!m_liveUri.isEmpty() && finished == m_liveUri)
                again.insert(QStringLiteral("isLive"), true);
            m_queue->add(localizedQueueItem(again));
        }
        next = m_queue->takeAt(0);
    } else if (autoplayNext()) { // settings can switch the episode chain off
        const QVariantMap ep = m_library->nextEpisode(finished);
        if (!ep.isEmpty())
            next = QVariantMap{
                {QStringLiteral("uri"), ep.value(QStringLiteral("path"))},
                {QStringLiteral("title"),
                 ep.value(QStringLiteral("show")).toString() + QStringLiteral("  ")
                     + ep.value(QStringLiteral("title")).toString()},
                {QStringLiteral("kind"), QStringLiteral("episode")},
            };
    }
    if (next.isEmpty()) {
        emit toast(QStringLiteral("COMPLETED"));
        m_autoplayChain = 0;
        if (m_stage == QLatin1String("player"))
            leavePlayer();
        return;
    }
    rememberLive(next); // a queued live stream advances live, not resumed
    // Party-via-cast: advance the whole ROOM to the next item — re-cast the
    // host's own TV to it AND tell the room to move (op:media) so every follower
    // switches with it. No local countdown: the host is browsing while the film
    // plays on the TV, and the room moves as one.
    if (m_partyViaCast) {
        partyAdvanceCast(next);
        return;
    }
    m_autoplayNext = next.value(QStringLiteral("uri")).toString();
    // The countdown overlay lives in the player view; while casting we're
    // browsing, so everything advances immediately on the TV.
    if (!m_cast->active()
        && next.value(QStringLiteral("kind")).toString() == QLatin1String("episode")) {
        // Episodes keep the countdown + 3-chain-then-ask ritual — unless the
        // viewer already said yes to it at the credits (creditsGo).
        if (m_skipCountdownOnce)
            autoplayGo();
        else if (m_autoplayChain >= 3)
            emit autoplayAsk(next.value(QStringLiteral("title")).toString());
        else
            emit autoplayCountdown(next.value(QStringLiteral("title")).toString());
    } else {
        // Explicitly queued items (and any advance while casting) go immediately,
        // like a playlist — through playItem, NOT autoplayGo, so the queue row's
        // own title/art survive. autoplayGo replays from the bare uri, which for a
        // YouTube item (not in the library) re-derives an ugly "watch?v=..." title.
        emit toast(QStringLiteral("NEXT · %1")
                       .arg(next.value(QStringLiteral("title")).toString()));
        m_autoplayNext.clear();
        playItem(next);
    }
}

void AppController::rememberLive(const QVariantMap &item)
{
    // play() only sees a uri string; the map is where "this is a live
    // stream" travels (search result, queue row, hub adoption alike).
    // Canonical, because play() canonicalises the path it compares against —
    // a youtu.be / shorts link stored raw never matched, so a live stream
    // played as a VOD (no live lane, a resume point recorded).
    if (item.value(QStringLiteral("isLive")).toBool()) {
        m_liveUri = canonicalYouTube(item.value(QStringLiteral("uri")).toString());
        m_liveTitle = item.value(QStringLiteral("title")).toString();
    }
}

QVariantMap AppController::resumeTarget() const
{
    // The brain behind hold-CAST: pick WHAT to resume from the most-recently
    // touched title (the media_state key is device-independent, so a laptop/away
    // watch that has synced into this DB counts too). The decision:
    //   in progress      -> resume it       (play() restores the exact position)
    //   finished episode  -> the NEXT episode (or replay, if it was the last one)
    //   finished film     -> replay it
    //   nothing / unknown -> {kind:"none"}  (caller decides: toast or a picker)
    QVariantMap out{{QStringLiteral("kind"), QStringLiteral("none")}};
    if (!m_store || !m_library)
        return out;
    const QVariantMap row = m_store->lastTouched();
    if (row.isEmpty())
        return out;
    const QString key = row.value(QStringLiteral("key")).toString();
    const double pos = row.value(QStringLiteral("position")).toDouble();
    const double dur = row.value(QStringLiteral("duration")).toDouble();
    const bool completed = row.value(QStringLiteral("completed")).toBool();

    const QVariantMap e = m_library->entryForKey(key);
    if (e.isEmpty()) {
        // Not a library item. A YouTube row is stored under its canonical
        // "yt:<id>" key (ResumeStore::mediaKey) — not something mpv or the
        // cast worker can open — so turn it back into the watch URL.
        if (key.startsWith(QLatin1String("yt:"))) {
            const QString vid = key.mid(3);
            QString title = m_youtube ? m_youtube->recentTitle(vid) : QString();
            if (title.isEmpty())
                title = QStringLiteral("YouTube");
            return QVariantMap{{QStringLiteral("kind"), QStringLiteral("resume")},
                               {QStringLiteral("uri"),
                                QStringLiteral("https://www.youtube.com/watch?v=") + vid},
                               {QStringLiteral("startPos"), pos},
                               {QStringLiteral("title"), title}};
        }
        return QVariantMap{{QStringLiteral("kind"), QStringLiteral("resume")},
                           {QStringLiteral("uri"), key},
                           {QStringLiteral("startPos"), pos},
                           {QStringLiteral("title"), key}};
    }
    const QString path = e.value(QStringLiteral("path")).toString();
    const QString ekind = e.value(QStringLiteral("kind")).toString();
    const QString show = e.value(QStringLiteral("show")).toString();
    const QString etitle = e.value(QStringLiteral("title")).toString();
    const auto pretty = [](const QString &t, const QString &s) {
        return (!s.isEmpty() && !t.startsWith(s)) ? s + QStringLiteral("  ") + t : t;
    };

    // "Watched" = explicitly completed, or stopped inside the watched zone.
    const bool watched = completed || (dur > 0 && pos / dur >= kWatchedPct);
    if (!watched) {
        // Mid-watch (or barely started) — play THIS one; play() resumes if >60s in.
        return QVariantMap{{QStringLiteral("kind"), QStringLiteral("resume")},
                           {QStringLiteral("uri"), path},
                           {QStringLiteral("startPos"), pos > 60 ? pos : 0.0},
                           {QStringLiteral("title"), pretty(etitle, show)}};
    }
    if (ekind == QLatin1String("episode")) {
        const QVariantMap nx = m_library->nextEpisode(path);
        if (!nx.isEmpty())
            return QVariantMap{
                {QStringLiteral("kind"), QStringLiteral("next")},
                {QStringLiteral("uri"), nx.value(QStringLiteral("path"))},
                {QStringLiteral("startPos"), 0.0},
                {QStringLiteral("title"),
                 pretty(nx.value(QStringLiteral("title")).toString(),
                        nx.value(QStringLiteral("show")).toString())}};
        // Last episode of the run — nothing after it, so replay it.
        return QVariantMap{{QStringLiteral("kind"), QStringLiteral("replay")},
                           {QStringLiteral("uri"), path},
                           {QStringLiteral("startPos"), 0.0},
                           {QStringLiteral("title"), pretty(etitle, show)}};
    }
    // A finished film (or one-off) — replay from the top.
    return QVariantMap{{QStringLiteral("kind"), QStringLiteral("replay")},
                       {QStringLiteral("uri"), path},
                       {QStringLiteral("startPos"), 0.0},
                       {QStringLiteral("title"), pretty(etitle, show)}};
}

void AppController::remoteResumeLast(bool toCast)
{
    const QVariantMap t = resumeTarget();
    const QString kind = t.value(QStringLiteral("kind")).toString();
    if (kind == QLatin1String("none")) {
        emit toast(toCast ? QStringLiteral("NOTHING RECENT TO CAST")
                          : QStringLiteral("NOTHING RECENT TO RESUME"));
        return;
    }
    const QString uri = t.value(QStringLiteral("uri")).toString();
    if (uri.isEmpty())
        return;
    const QString label = t.value(QStringLiteral("title")).toString().toUpper();

    if (m_cast->active() && !m_cast->currentUri().isEmpty()) {
        if (toCast && m_store->mediaKey(m_cast->currentUri()) == m_store->mediaKey(uri)) {
            // Already on the TV: a re-cast reloaded it from a store position up
            // to 5 s stale (and re-warmed a DV lane for ~12 s). Just say so.
            emit toast(QStringLiteral("ON TV ▸ ") + label);
            return;
        }
        if (!toCast) {
            // RESUME means "on THIS machine": bring the TV's title home, at
            // its position (play() would otherwise route to the cast target).
            setOutput({});
            return;
        }
    }

    if (toCast && !m_cast->active()) {
        // CAST: target the Bravia so play() routes to the TV. If discovery hasn't
        // landed it yet, kick it and bail — the next press catches it, rather than
        // silently starting a LOCAL play (the "weird" thing the author flagged).
        const int n = m_cast->deviceCount();
        if (n <= 0) { m_cast->start(); emit toast(QStringLiteral("SEARCHING FOR TV…")); return; }
        // Pick the target deliberately — a loose "first device named TV" used to
        // grab a stale off-network "Lounge TV". Prefer (1) the last TV we actually
        // cast to, if it's in the current list; (2) else a Sony/Bravia by name OR
        // model (the Bravia's NAME is "Bedroom TV 2" but its MODEL is BRAVIA…);
        // (3) else the sole device. The worker now reachability-filters the list,
        // so anything here is on this network.
        const QString last = m_settings.value(QStringLiteral("lastCastTarget")).toString();
        QString id;
        for (int i = 0; i < n && id.isEmpty(); ++i)
            if (m_cast->deviceAt(i).value(QStringLiteral("id")).toString() == last)
                id = last;
        for (int i = 0; i < n && id.isEmpty(); ++i) {
            const QVariantMap d = m_cast->deviceAt(i);
            const QString name  = d.value(QStringLiteral("name")).toString().toUpper();
            const QString model = d.value(QStringLiteral("model")).toString().toUpper();
            if (name.contains(QLatin1String("BRAVIA")) || name.contains(QLatin1String("SONY"))
                || model.contains(QLatin1String("BRAVIA")) || model.contains(QLatin1String("SONY")))
                id = d.value(QStringLiteral("id")).toString();
        }
        if (id.isEmpty() && n == 1) id = m_cast->deviceAt(0).value(QStringLiteral("id")).toString();
        if (id.isEmpty()) { emit toast(QStringLiteral("NO CAST TARGET")); return; }
        // Something playing HERE goes to the TV with setOutput (it hands the
        // local title over at its position) — and that IS the answer to CAST.
        // Falling through to play() too sent a second cast load milliseconds
        // later: two lanes torn up, two toasts.
        const QString here = m_engine->path();
        const bool localPlaying = !here.isEmpty() && !m_engine->idle() && !ephemeralUri(here);
        setOutput(id);
        if (localPlaying)
            return;
        // ── SEAM · upstairs ── power the amp + TV to the right inputs here
        // (codec_amp cast-on). setOutput() is async, so the robust "cast connected
        // → THEN play" ordering also gets finished upstairs with the TV in hand.
    }

    const QString verb = kind == QLatin1String("next")   ? QStringLiteral("NEXT")
                       : kind == QLatin1String("replay") ? QStringLiteral("REPLAY")
                                                         : QStringLiteral("RESUME");
    emit toast((toCast ? QStringLiteral("CAST ▸ ") : (verb + QStringLiteral(" ▸ "))) + label);
    play(uri);
}

void AppController::playItem(const QVariantMap &itemIn)
{
    QVariantMap item = itemIn;
    item.insert(QStringLiteral("uri"),
                canonicalYouTube(item.value(QStringLiteral("uri")).toString()));
    const QString uri = item.value(QStringLiteral("uri")).toString();
    if (m_youtube && uri.contains(QLatin1String("youtube.com/watch"))
        && !item.value(QStringLiteral("title")).toString().isEmpty()) {
        QVariantMap seen = item;
        if (seen.value(QStringLiteral("videoId")).toString().isEmpty())
            seen.insert(QStringLiteral("videoId"), youtubeIdOf(uri));
        m_youtube->noteWatched(seen);
    }
    if (uri.isEmpty())
        return;
    if (m_cast->active() && !ephemeralUri(uri)) {
        castPlay(item);
        return;
    }
    rememberLive(item);
    play(uri);
}

void AppController::castPartyRecover()
{
    // Batch2 #4: rebuild the SAME party lane on the receiver at the room clock,
    // WITHOUT going through castPlay() (whose solo-lock refuses while m_partyViaCast
    // is set) and WITHOUT clearing m_partyViaCast. The worker builds the lane from
    // the token, so a bare item (token + title + dur) is all it needs — identical to
    // joinWatchParty's cast. This is the wedge's only recovery lever from inside the
    // party; §C/§D reduce the wedge but never re-cast.
    if (!m_partyViaCast || m_partyToken.isEmpty())
        return;
    QVariantMap item;
    item.insert(QStringLiteral("partyToken"), m_partyToken);
    item.insert(QStringLiteral("title"), m_partyTitle);
    if (m_partyDur > 0)
        item.insert(QStringLiteral("durationS"), m_partyDur);
    Logger::log(QStringLiteral("party"),
                QStringLiteral("cast wedge recovery — re-casting lane at %1s")
                    .arg(int(partyPos())));
    m_cast->castLoad(item, partyPos());
}

void AppController::castPlay(QVariantMap item)
{
    item.insert(QStringLiteral("uri"),
                canonicalYouTube(item.value(QStringLiteral("uri")).toString()));
    // The TV is a party FOLLOWER right now (party-from-cast). A plain solo cast
    // would silently yank it off the room — which is exactly the tangle that
    // put Transformers on the TV while everyone else watched Jack Ryan. Changing
    // what the room watches is a party action, not a solo cast; refuse here.
    if (m_partyViaCast) {
        emit toast(QStringLiteral("PARTY IS ON THE TV · END IT TO CAST SOLO"));
        return;
    }
    Logger::log(QStringLiteral("cast"),
                QStringLiteral("castPlay %1")
                    .arg(item.value(QStringLiteral("uri")).toString()));
    const QString uri = item.value(QStringLiteral("uri")).toString();
    rememberLive(item);   // #3: track a LIVE cast so its DVR-window position isn't
                          // banked as a resume point / marked watched (see below)
    // Bank whatever the local engine still holds (PiP), then send to the TV.
    saveNow();
    maybeMarkWatched();
    const QVariantMap info = m_library->entryInfo(uri);
    if (item.value(QStringLiteral("title")).toString().isEmpty())
        item.insert(QStringLiteral("title"),
                    info.value(QStringLiteral("title"),
                               Library::prettyTitle(uri)));
    // #1: back-fill the poster even when a title IS provided. The episode
    // auto-advance builds its item as {uri,title,kind} only, so gating art on an
    // empty title meant every next episode of a binge cast a card with NO poster.
    if (item.value(QStringLiteral("artUrl")).toString().isEmpty()) {
        const QString poster = info.value(QStringLiteral("poster")).toString();
        if (!poster.isEmpty())
            item.insert(QStringLiteral("artUrl"), poster);
    }
    const QVariantMap st = m_store->state(uri);
    const double duration = st.value(QStringLiteral("duration")).toDouble();
    double start = st.value(QStringLiteral("position")).toDouble();
    if (start < 60 || (duration > 0 && start / duration >= kWatchedPct))
        start = 0;
    item.insert(QStringLiteral("subsize"), castCaptionScale() / 100.0);   // a burn wears the CAST size
    // Known duration ships with the load — a lane that starts without one
    // shows the receiver a LIVE-ish endless bar until the first restart.
    if (item.value(QStringLiteral("durationS")).toDouble() <= 0 && duration > 0)
        item.insert(QStringLiteral("durationS"), duration);
    if (!ephemeralUri(uri))   // STATS "PLAYS": count the cast play-start (cooldown-gated)
        m_store->registerPlayStart(uri);
    m_cast->castLoad(item, start);
    // Account history for a cast YouTube video: the 30 s ping timer follows
    // the cast and pings only while it is PLAYING — no ping for a cast that
    // never got going.
    m_ytPingTimer.start();
    vaultNoteKick(uri);
    m_autoplayChain = 0;
    emit toast(QStringLiteral("→ %1 · %2")
                   .arg(m_cast->targetName().toUpper(),
                        item.value(QStringLiteral("title")).toString()));
}

void AppController::playQueued(int row)
{
    playItem(m_queue->takeAt(row));
}

// How to install a missing tool on THIS machine's distro (scripts/codec_paths
// install_hint has the same table): pacman / dnf / apt for the packages whose
// names are known, else the honest generic line.
static QString installHint(const QString &what)
{
    QFile f(QStringLiteral("/etc/os-release"));
    QString ids;
    if (f.open(QIODevice::ReadOnly))
        for (const QByteArray &line : f.readAll().split('\n'))
            if (line.startsWith("ID=") || line.startsWith("ID_LIKE="))
                ids += QString::fromUtf8(line.mid(line.indexOf('=') + 1)).remove(QLatin1Char('"')).toLower() + QLatin1Char(' ');
    if (what == QLatin1String("yt-dlp")) {
        if (ids.contains(QLatin1String("arch"))) return QStringLiteral("sudo pacman -S yt-dlp");
        if (ids.contains(QLatin1String("fedora"))) return QStringLiteral("sudo dnf install yt-dlp");
        if (ids.contains(QLatin1String("debian")) || ids.contains(QLatin1String("ubuntu")))
            return QStringLiteral("sudo apt install yt-dlp");
    }
    return QStringLiteral("install %1 with your package manager").arg(what);
}

void AppController::playTrailer(const QString &title, const QString &subtitle)
{
    if (QStandardPaths::findExecutable(QStringLiteral("yt-dlp")).isEmpty()) {
        emit toast(QStringLiteral("TRAILERS NEED YT-DLP — ") + installHint(QStringLiteral("yt-dlp")));
        return;
    }
    // Subtitles look like "1980 · 4K · HDR" — the leading year sharpens search.
    const QString year = subtitle.left(4);
    QString q = title;
    if (year.size() == 4 && year.toInt() > 1900)
        q += QLatin1Char(' ') + year;
    play(QStringLiteral("ytdl://ytsearch1:%1 trailer").arg(q));
    emit toast(m_cast->active()
                   ? QStringLiteral("TRAILER · %1 (PLAYS HERE, NOT ON %2)")
                         .arg(title, m_cast->targetName().toUpper())
                   : QStringLiteral("TRAILER · %1").arg(title));
}

void AppController::copyText(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
    emit toast(QStringLiteral("COPIED"));
}

void AppController::setWatched(const QString &uri, bool watched)
{
    if (watched)
        m_store->markCompleted(uri);
    else
        m_store->clearWatched(uri);
    m_library->refreshResume();
    emit toast(watched ? QStringLiteral("MARKED WATCHED")
                       : QStringLiteral("MARKED UNWATCHED"));
}

void AppController::setWatchedMany(const QStringList &uris, bool watched)
{
    for (const QString &u : uris) {
        if (watched)
            m_store->markCompleted(u);
        else
            m_store->clearWatched(u);
    }
    m_library->refreshResume();
    emit toast(QStringLiteral("%1 MARKED %2")
                   .arg(uris.size())
                   .arg(watched ? QStringLiteral("WATCHED") : QStringLiteral("UNWATCHED")));
}

void AppController::deleteMedia(const QString &path)
{
    // Local files only — a manifest satellite streams over http and must never
    // try to delete the hub's media, and a cast target isn't ours to touch.
    if (!path.startsWith(QLatin1Char('/')) || !QFile::exists(path)) {
        emit toast(QStringLiteral("CAN'T DELETE — NOT A LOCAL FILE"));
        return;
    }
    // If the file we're about to remove is playing, stop first so mpv isn't
    // left holding a deleted handle.
    if (m_engine->path() == path) {
        m_engine->stop();
        if (m_stage == QLatin1String("player"))
            setStage(m_browseStage);
    }

    const QFileInfo fi(path);
    const QString title = Library::prettyTitle(path);
    QDir dir = fi.absoluteDir();
    bool ok = QFile::remove(path);

    // A movie usually lives alone in its release folder; once the video is
    // gone, sweep the folder if only small junk (nfo/jpg/srt/sample) remains —
    // never if there's another sizeable video (a two-film folder, box set).
    if (ok) {
        // Recursively: a release folder's Featurettes/ or Extras/ (what the
        // BONUS FEATURES page shows) is real content too, and a top-level-only
        // look let removeRecursively() below take it with the film.
        bool onlyJunk = true;
        QDirIterator it(dir.absolutePath(), QDir::Files | QDir::NoDotAndDotDot,
                        QDirIterator::Subdirectories);
        while (it.hasNext()) {
            it.next();
            if (it.fileInfo().size() > 50LL * 1024 * 1024) { // >50MB = real content, keep folder
                onlyJunk = false;
                break;
            }
        }
        // NEVER remove a configured media root itself (a loose file lives
        // directly in one) — only a release subfolder that's now junk-only.
        bool isRoot = false;
        const QString here = dir.absolutePath();
        QFile cf(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                 + QStringLiteral("/codec/config.json"));
        if (cf.open(QIODevice::ReadOnly)) {
            const QJsonArray roots = QJsonDocument::fromJson(cf.readAll())
                .object().value(QStringLiteral("roots")).toArray();
            for (const QJsonValue &v : roots)
                if (QDir(v.toObject().value(QStringLiteral("path")).toString())
                        .absolutePath() == here) {
                    isRoot = true;
                    break;
                }
        }
        if (onlyJunk && !isRoot)
            dir.removeRecursively();
    }

    m_store->clearWatched(path); // drop any resume/watched row for the dead path
    Logger::log(QStringLiteral("delete"),
                (ok ? QStringLiteral("removed ") : QStringLiteral("FAILED ")) + path);
    emit toast(ok ? QStringLiteral("DELETED · %1").arg(title.toUpper())
                  : QStringLiteral("DELETE FAILED — %1").arg(title.toUpper()));
    if (ok)
        m_library->rescan(); // vanishes from the app now; the rescan's orphan
                             // pass reconciles the DB + laptop manifest
}

void AppController::setQueueOpen(bool on)
{
    if (on != m_queueOpen) {
        m_queueOpen = on;
        emit queueOpenChanged();
        if (on)
            pullHubQueue(); // opening the panel refreshes the shared inbox
    }
}

void AppController::setSearchOpen(bool on)
{
    if (on != m_searchOpen) {
        m_searchOpen = on;
        emit searchOpenChanged();
        Logger::log(QStringLiteral("ui"),
                    on ? QStringLiteral("search open")
                       : QStringLiteral("search closed"));
    }
}

// The miniplayer's corner persists (settings.pipLeft / pipTop): it used to
// reset to bottom-right every launch, and a corner is a preference, not a
// session whim — the Settings DISPLAY row and ctrl+h/j/k/l both land here.
void AppController::setPipLeft(bool v)
{
    if (v != m_pipLeft) {
        m_pipLeft = v;
        saveSetting(QStringLiteral("pipLeft"), v);
        emit pipCornerChanged();
    }
}

void AppController::setPipTop(bool v)
{
    if (v != m_pipTop) {
        m_pipTop = v;
        saveSetting(QStringLiteral("pipTop"), v);
        emit pipCornerChanged();
    }
}

void AppController::saveNow()
{
    // Playback may continue in the PiP dock while browsing — save whenever
    // something is actually loaded, regardless of stage. Under the warm-HLS
    // fallback the engine plays a LANE url; the row belongs to the title
    // (progress used to land under `/hls/pl.m3u8?src=…` and the resume was lost).
    const QString key = playbackIdentity(m_engine->path());
    if (key.isEmpty() || m_engine->duration() <= 0 || ephemeralUri(key))
        return;
    // Just completed via natural EOF: markCompleted already banked this row
    // (position=0). m_engine still reports it at ≈duration until the next load,
    // so saving now would re-inflate position and double-count watch time.
    if (!m_completedPath.isEmpty() && m_engine->path() == m_completedPath)
        return;
    // A live stream has no resumable position (the DVR window shifts under
    // it) — count the watch time, skip the row.
    // On the warm lane the engine's track ids are the LANE's (one transcoded
    // audio, no subs) — the title keeps the ids it was opened with, or the
    // next raw play would come up on the wrong audio track.
    const bool onLane = m_resumeFellBack && m_engine->path() == m_hlsFallbackUrl;
    if (!m_liveNow)
        m_store->saveProgress(key, m_engine->position(),
                              m_engine->duration(),
                              onLane ? m_hlsFallbackAid : m_engine->audioId(),
                              onLane ? m_hlsFallbackSid : m_engine->subId(),
                              m_engine->speed(),
                              m_engine->zoomMode(), m_mode);
    // Stats: credit the REAL time since the last active tick, not a flat 10s
    // pinned to the timer interval — saveNow also fires on manual events (track
    // switch, leaving the player), and the interval could change. Cap at 2× the
    // interval so a resume-from-pause gap isn't over-credited; invalidate while
    // paused/idle so that dead time isn't counted at all.
    if (!m_engine->paused() && !m_engine->idle()) {
        const double cap = m_saveTimer.interval() / 1000.0 * 2.0;
        double secs;
        if (m_watchTick.isValid()) {
            secs = m_watchTick.restart() / 1000.0;   // real elapsed, restarts
        } else {
            m_watchTick.start();                     // begin measuring
            secs = m_saveTimer.interval() / 1000.0;  // bootstrap estimate
        }
        m_store->addWatchTime(qBound(0.0, secs, cap));
    } else {
        m_watchTick.invalidate();
    }
}

void AppController::leavePlayer()
{
    saveNow();
    m_library->refreshResume();
    setStage(m_browseStage); // video keeps playing in the dock
    // Leaving the fullscreen player is a natural "banked my spot" moment for
    // YouTube resume — but the PiP may keep playing, so update, don't clear.
    if (!m_liveNow)
        ytHistoryPing(m_engine->path(), m_engine->position());
}

void AppController::stopPlayback()
{
    // Stopping IS a sound (x, the remote's Stop, the TV remote's): the
    // miniplayer / cast closing. Moving the film into the miniplayer is not.
    const bool had = (!m_engine->path().isEmpty() && !m_engine->idle())
                     || (m_cast->active() && !m_cast->currentUri().isEmpty());
    if (had && m_sfx) {
        m_sfx->setQuiet(false);   // the film is ending: its stop is the one cue it lets through
        m_sfx->play(QStringLiteral("back"));
    }
    setRemoteOpen(false);
    // Stopping while following a party IS leaving it: the follower reloads an
    // idle player onto the room's film, so `x` / Stop were undone within ~2 s
    // (audit 2026-10-10). A hub room carries on for everyone else.
    if (m_partyFollowing)
        leaveWatchPartyAs(QStringLiteral("LEFT THE PARTY"));
    if (m_cast->active() && !m_cast->currentUri().isEmpty()) {
        castCreditsCancel(/*flash=*/false);
        // Cast watched-zone: same 90% rule as local (unless the credits banked it).
        if (m_cast->currentUri() != m_castCreditsUri && m_cast->castDuration() > 0
            && m_cast->castPosition() / m_cast->castDuration() >= kWatchedPct)
            m_store->markCompleted(m_cast->currentUri());
        m_cast->stopCast();
    }
    saveNow();
    maybeMarkWatched();
    if (!m_liveNow) // final YouTube resume position before we tear down
        ytHistoryPing(m_engine->path(), m_engine->position());
    // Finishing or stopping a title is the moment worth propagating now, not
    // 30s from now — so a completed episode shows up on the other screen while
    // you're still deciding what's next. The 30s timer is the backstop.
    syncState();
    m_ytPingTimer.stop();
    m_saveTimer.stop();
    m_engine->stop();
    m_autoplayChain = 0;
    m_liveUri.clear();
    liveReset();
    if (m_liveNow) {
        m_liveNow = false;
        emit liveNowChanged();
    }
    m_library->refreshResume();
    if (m_stage == QLatin1String("player"))
        setStage(m_browseStage);
}

void AppController::setOutput(const QString &deviceId)
{
    setOutputOpen(false);
    if (deviceId == m_cast->targetId())
        return;
    setRemoteOpen(false);
    if (deviceId.isEmpty()) {
        // TV -> this machine, carrying the position along.
        const QString uri = m_cast->currentUri();
        const double pos = m_cast->castPosition();
        if (!uri.isEmpty()) {
            // Same rule as the status handler: a zero here is "we never got a
            // real position", not "rewind to the start" — banking it would
            // throw away whatever the store already holds for this item.
            if (pos > 1.0)
                m_store->saveProgress(uri, pos, m_cast->castDuration(), -1, -1,
                                      -1.0, -1, m_mode);  // sentinels: keep local prefs
            m_cast->stopCast();
        }
        m_cast->setTarget({});
        emit toast(QStringLiteral("OUT → THIS MACHINE"));
        if (!uri.isEmpty())
            play(uri); // resumes from the position just banked
        return;
    }
    // This machine -> TV: hand over whatever is mid-play here.
    const QString uri = m_engine->path();
    const bool localPlaying =
        !uri.isEmpty() && !m_engine->idle() && !ephemeralUri(uri);
    if (localPlaying) {
        // handing it to a TV leaves the party (the follower would otherwise
        // reload it here: the film on the TV AND this screen)
        if (m_partyFollowing)
            leaveWatchPartyAs(QString());
        saveNow();
        m_engine->stop();
        if (m_stage == QLatin1String("player"))
            setStage(m_browseStage);
    }
    m_cast->setTarget(deviceId);
    saveSetting(QStringLiteral("lastCastTarget"), deviceId); // CAST-hold prefers it
    emit toast(QStringLiteral("OUT → %1").arg(m_cast->targetName().toUpper()));
    if (localPlaying)
        play(uri); // routed to the cast target, resuming from the store
}

void AppController::setOutputOpen(bool on)
{
    if (on != m_outputOpen) {
        m_outputOpen = on;
        emit outputOpenChanged();
    }
}

void AppController::setRemoteOpen(bool on)
{
    if (on != m_remoteOpen) {
        m_remoteOpen = on;
        emit remoteOpenChanged();
    }
}

void AppController::backToChooser()
{
    refreshMonitors();
    setStage(QStringLiteral("chooser"));
}

void AppController::ensureHdrRestored()
{
    if (m_monitorHdrOn)
        setMonitorHdr(false, /*blocking=*/true); // must land before exit
}

void AppController::quit()
{
    if (m_monitorHdrOn)
        setMonitorHdr(false, /*blocking=*/true); // must land before exit
    // Quitting is leaving the room, not ending the night — the session lives on
    // the hub and everyone else is still watching. An app-mode party has no
    // clock without us, so that one does end (the hub also reaps it by TTL).
    if (m_partyHosting)
        endWatchParty();
    // Stop claiming a film we're no longer playing. Without this the chip
    // would hang around on the other screen until the staleness window let
    // go, offering to resume something that had already closed.
    m_nowPublishTimer.stop();
    if (m_nowPublished)
        nowBye();
    if (m_castqPushTimer.isActive()) {
        // Queue was edited within the debounce window — flush it, bounded,
        // so quitting right after queueing doesn't lose the push and let
        // another device resurrect the pre-edit queue.
        m_castqPushTimer.stop();
        QEventLoop loop;
        connect(this, &AppController::queuePushed, &loop, &QEventLoop::quit);
        QTimer::singleShot(1200, &loop, &QEventLoop::quit);
        castQueuePush();
        loop.exec();
    }
    saveNow();
    maybeMarkWatched();
    syncState(); // push this session's progress to the hub before exiting
    QCoreApplication::quit();
}

QString AppController::prettyTime(double seconds) const
{
    if (seconds < 0 || !qIsFinite(seconds))
        seconds = 0;
    const int total = int(seconds);
    const int h = total / 3600;
    const int m = (total % 3600) / 60;
    const int s = total % 60;
    if (h > 0)
        return QStringLiteral("%1:%2:%3")
            .arg(h)
            .arg(m, 2, 10, QLatin1Char('0'))
            .arg(s, 2, 10, QLatin1Char('0'));
    return QStringLiteral("%1:%2").arg(m).arg(s, 2, 10, QLatin1Char('0'));
}

void AppController::setStage(const QString &stage)
{
    if (stage == m_stage)
        return;
    // Forward only re-enters what Back left; any other navigation makes that
    // history stale (it would jump somewhere unexpected).
    if (!m_inMouseNav)
        m_fwd.clear();
    Logger::log(QStringLiteral("ui"),
                QStringLiteral("stage %1 -> %2").arg(m_stage, stage));
    m_stage = stage;
    emit stageChanged();
}
