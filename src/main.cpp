#include "appcontroller.h"
#include "mpris.h"
#include "castmanager.h"
#include "library.h"
#include "mpv/mpvengine.h"
#include "mpv/mpvvideoitem.h"
#include "livechat.h"
#include "queuemodel.h"
#include "resumestore.h"
#include "designtokens.h"
#include "theme.h"
#include "logger.h"
#include "youtubesource.h"
#include "sysvolume.h"
#include "uisound.h"

#include <QCommandLineParser>
#include <QGuiApplication>
#include <QImageReader>
#include <QDebug>
#include <QQmlApplicationEngine>
#include "hubnam.h"
#include <QQmlDebuggingEnabler>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSocketNotifier>
#include <QTimer>
#include <utility>
#include <QWheelEvent>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QPointingDevice>
#include <QElapsedTimer>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QFileInfo>
#include <QDir>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>

#include <clocale>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <csignal>
#include <sys/socket.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <algorithm>

// Unix-signal → Qt bridge (self-pipe). A SIGTERM (what `pkill`/logout send) or
// SIGINT (Ctrl+C) would otherwise kill the process instantly — bypassing the
// HDR restore in quit(), leaving the desktop stuck in HDR. The handler only
// writes one byte (async-signal-safe); a QSocketNotifier turns that into a
// normal event-loop callback that shuts down cleanly.
static int g_sigFd[2] = {-1, -1};
static void unixSignalHandler(int) { char c = 1; ssize_t r = ::write(g_sigFd[0], &c, 1); (void)r; }

// The MGS faces live in TWO places: compiled into codec (qrc, FontLoader) and
// installed for fontconfig in ~/.local/share/fonts/codec (what the hub's ffmpeg
// burn-in, the dashboard and every other app use). Qt resolves a family NAME
// ("MGS1 HUD") through fontconfig too — and prefers the INSTALLED copy — so when
// the two drift, codec silently draws with the old font: after the 2026-10 glyph
// pass "Gert Fröbe" took its Ö from a fallback face because the installed copy
// was from September. Keep the installed copy identical to the built-in one,
// BEFORE QGuiApplication builds its font database, so it takes effect this
// launch. Writes only when the bytes differ (i.e. once after a font change).
// codec began inside myOS and kept its data (the watch database, the queue,
// the manifest …) in ~/.local/share/myOS/codec. It's its own program now, and
// its data belongs in ~/.local/share/codec — which already holds the DV
// tools' scratch, so the move is entry by entry, not one folder rename. One
// filesystem, so every step is a rename: nothing is copied, nothing can be
// half-written. The database goes LAST, so whatever stops the move leaves it
// where it was; then the old folder becomes a link to the new one, so anything
// still naming it (the hub's server, a satellite's older build, a nightly
// script) finds the same files.
//
// Nothing is guessed: an entry already in the new folder by the same name
// stops the move — except an EMPTY file (a 0-byte codec.db a script created
// there early), which carries nothing to lose. Returns whether the data lives
// in the new folder; if not, codec keeps using the old one this launch.
static bool migrateDataDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    const QString oldDir = base + QStringLiteral("/myOS/codec");
    const QString newDir = base + QStringLiteral("/codec");
    const QFileInfo oi(oldDir);
    if (oi.isSymLink() || !oi.exists())
        return true;                                   // moved already, or never there
    const QStringList dbFiles = {QStringLiteral("codec.db"), QStringLiteral("codec.db-wal"),
                                 QStringLiteral("codec.db-shm")};
    QStringList names = QDir(oldDir).entryList(QDir::AllEntries | QDir::NoDotAndDotDot
                                               | QDir::Hidden | QDir::System);
    for (const QString &n : std::as_const(names)) {
        const QFileInfo t(newDir + QLatin1Char('/') + n);
        if ((t.exists() || t.isSymLink()) && !(t.isFile() && t.size() == 0)) {
            fprintf(stderr, "codec: data stays in %s — %s is already in %s\n",
                    qPrintable(oldDir), qPrintable(n), qPrintable(newDir));
            return false;
        }
    }
    QDir().mkpath(newDir);
    // everything else first, the database last
    std::stable_partition(names.begin(), names.end(),
                          [&dbFiles](const QString &n) { return !dbFiles.contains(n); });
    for (const QString &n : std::as_const(names)) {
        const QString to = newDir + QLatin1Char('/') + n;
        if (QFileInfo::exists(to))
            QFile::remove(to);                         // the empty file checked above
        if (::rename(QFile::encodeName(oldDir + QLatin1Char('/') + n).constData(),
                     QFile::encodeName(to).constData()) != 0) {
            fprintf(stderr, "codec: moving %s to %s stopped at %s (%s)\n", qPrintable(oldDir),
                    qPrintable(newDir), qPrintable(n), strerror(errno));
            return !QFileInfo::exists(oldDir + QStringLiteral("/codec.db"));
        }
    }
    if (QDir().rmdir(oldDir))
        QFile::link(newDir, oldDir);
    fprintf(stderr, "codec: data moved to %s\n", qPrintable(newDir));
    return true;
}

static void syncMgsFonts()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)
                        + QStringLiteral("/fonts/codec");
    bool changed = false;
    for (const char *name : {"mgs-codec.ttf", "mgs-hud.ttf"}) {
        QFile src(QStringLiteral(":/assets/mechui/") + QLatin1String(name));
        if (!src.open(QIODevice::ReadOnly))
            continue;
        const QByteArray bytes = src.readAll();
        const QString dst = dir + QLatin1Char('/') + QLatin1String(name);
        QFile cur(dst);
        if (cur.open(QIODevice::ReadOnly) && cur.readAll() == bytes)
            continue;
        cur.close();
        QDir().mkpath(dir);
        QSaveFile out(dst);
        if (out.open(QIODevice::WriteOnly) && out.write(bytes) == bytes.size() && out.commit()) {
            changed = true;
            std::fprintf(stderr, "codec: refreshed installed font %s\n", name);
        }
    }
    if (changed) {
        const QString cmd = QStringLiteral("fc-cache -f '%1' >/dev/null 2>&1").arg(dir);
        const int rc = std::system(cmd.toLocal8Bit().constData());
        (void)rc;
    }
}

int main(int argc, char *argv[])
{
    syncMgsFonts();

    // mpv's OpenGL render API needs the scene graph on OpenGL, not Vulkan.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

    // Shipped globe textures are small, but make_globe_real.py can bake
    // them up to 16384x8192 (512MB decoded) — over the 256MB default
    // QImageReader ceiling, which fails SILENTLY (black texture). Raise
    // it so a big rebake just works; the assets are trusted qrc content.
    QImageReader::setAllocationLimit(1024);

    QGuiApplication app(argc, argv);
    // Dev hook: CODEC_QMLPROFILE=1 opens Qt's QML debug/profiler service on
    // 127.0.0.1:3768 (never another interface) and waits for a client:
    //   qmlprofiler -a 127.0.0.1 -p 3768 -o trace.qtd
    // Off unless the variable is set.
    if (qEnvironmentVariableIntValue("CODEC_QMLPROFILE") > 0) {
        QQmlDebuggingEnabler::enableDebugging(true);
        if (!QQmlDebuggingEnabler::startTcpDebugServer(3768, QQmlDebuggingEnabler::WaitForClient,
                                                       QStringLiteral("127.0.0.1")))
            qWarning("CODEC_QMLPROFILE: the QML debug server didn't start");
    }
    QGuiApplication::setApplicationName(QStringLiteral("codec"));
    // ~/.local/share/codec (no organisation folder) — unless the move out of
    // myOS couldn't finish, in which case the data is still there
    if (!migrateDataDir())
        QGuiApplication::setOrganizationName(QStringLiteral("myOS"));
    QGuiApplication::setApplicationVersion(QStringLiteral(CODEC_VERSION));

    // Qt applies the user locale after construction; libmpv requires C numerics.
    std::setlocale(LC_NUMERIC, "C");

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("codec — a media player and cast hub"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption({QStringLiteral("display"),
                      QStringLiteral("Monitor to open on (e.g. DP-3); skips the chooser. "
                                     "Mode is inferred from the panel (5:4 = CRT, else HD)."),
                      QStringLiteral("name")});
    parser.addOption({QStringLiteral("mode"),
                      QStringLiteral("Override the inferred viewing mode: crt or hd."),
                      QStringLiteral("mode")});
    parser.addOption({QStringLiteral("enqueue"),
                      QStringLiteral("Add the given files to the queue instead of "
                                     "playing them (forwards to a running codec).")});
    parser.addPositionalArgument(QStringLiteral("file"),
                                 QStringLiteral("Media file(s) or URL to play or enqueue."));
    parser.process(app);

    // ── Single-instance forwarding (VLC-style) ─────────────────────────────
    // If a codec is already running and we were handed files, hand them to it
    // over D-Bus (org.codec.App) and exit — no second window. A bare launch
    // (no files) always opens, so the dev kill/relaunch cycle is unaffected.
    const QStringList cliFiles = parser.positionalArguments();
    const bool cliEnqueue = parser.isSet(QStringLiteral("enqueue"));
    QStringList absFiles;
    for (const QString &f : cliFiles) {
        // Leave URLs (youtube etc.) as-is; absolute-ise local paths so the
        // running instance resolves them regardless of its working dir.
        if (f.contains(QStringLiteral("://")) && !f.startsWith(QStringLiteral("file://")))
            absFiles << f;
        else
            absFiles << QFileInfo(f.startsWith(QStringLiteral("file://"))
                                      ? QUrl(f).toLocalFile() : f)
                            .absoluteFilePath();
    }
    if (!absFiles.isEmpty()) {
        QDBusConnection bus = QDBusConnection::sessionBus();
        if (bus.isConnected() && bus.interface()
            && bus.interface()->isServiceRegistered(QStringLiteral("org.codec.App"))) {
            QDBusInterface iface(QStringLiteral("org.codec.App"),
                                 QStringLiteral("/org/codec/App"),
                                 QStringLiteral("org.codec.App"), bus);
            const QDBusMessage r =
                iface.call(cliEnqueue ? QStringLiteral("Enqueue") : QStringLiteral("PlayNow"),
                           absFiles);
            // Only a delivered call means the running codec has the files. A
            // codec that is quitting (its window gone, still finishing a scan)
            // can own the name with the object already unregistered: the call
            // errors, and returning here silently lost the "Open with codec".
            // Then this launch opens them itself.
            if (r.type() != QDBusMessage::ErrorMessage)
                return 0;
        }
    }

    Logger logger;
    Theme theme;
    ResumeStore store;
    MpvEngine engine;
    Library library(&store);
    QueueModel queue;
    YouTubeSource youtube;
    SysVolume sysvol;
    LiveChat livechat;
    CastManager cast;
    AppController controller(&engine, &store, &library, &queue, &cast);
    controller.setYouTube(&youtube);
    // the player reads the YouTube login the browse worker uses (Settings ▸
    // YOUTUBE): a connect or a switch to codec's own lists reaches it at once
    QObject::connect(&youtube, &YouTubeSource::accountChanged, &engine, [&youtube, &engine] {
        const QVariantMap a = youtube.account();
        if (a.value(QStringLiteral("state")) == QLatin1String("noengine"))
            return;
        engine.setYtCookieSpec(a.value(QStringLiteral("mode")) == QLatin1String("account")
                                   ? a.value(QStringLiteral("spec")).toString() : QString());
    });
    controller.setTheme(&theme);   // apply the persisted mech-palette choice at launch
    Mpris mpris(&controller, &engine, &sysvol); // media keys (playerctl) + now-playing over D-Bus
    UiSound sfx(&controller);   // UI sounds (QML: Sfx) — settings live in the controller's config
    controller.setUiSound(&sfx);

    qmlRegisterType<MpvVideoItem>("Codec.Core", 1, 0, "MpvVideo");
    qmlRegisterUncreatableType<PlaybackEngine>("Codec.Core", 1, 0, "PlaybackEngine",
                                               QStringLiteral("interface type"));

    DesignTokens tokens;   // motion / spacing / type scale
    // FRAME RATE (Settings ▸ DISPLAY). Qt fixes its render loop when the first
    // window is made, so it's decided here, at start-up. Qt's own choice on
    // this NVIDIA/Wayland box is its BASIC loop, whose animations tick off a
    // ~60 Hz timer whatever the screen (a probe measured 62/s on the 170 Hz
    // panel); the THREADED loop ticks with the display (170/s there, 60 on the
    // CRT). An explicit QSG_RENDER_LOOP in the environment wins; the
    // screenshot harness keeps Qt's default (offscreen has no display).
    if (qEnvironmentVariableIsEmpty("QSG_RENDER_LOOP")
        && !qEnvironmentVariableIsSet("CODEC_SHOT"))
        qputenv("QSG_RENDER_LOOP",
                controller.frameRateMode() == QLatin1String("60") ? "basic" : "threaded");
    controller.noteRenderLoop(QString::fromLatin1(qgetenv("QSG_RENDER_LOOP")));

    QQmlApplicationEngine qmlEngine;
    // a satellite's key to its hub rides QML's own requests too (posters)
    qmlEngine.setNetworkAccessManagerFactory(new HubNamFactory);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Theme"), &theme);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("DS"), &tokens);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Engine"), &engine);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("MediaLibrary"), &library);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Store"), &store);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("App"), &controller);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Queue"), &queue);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("YouTube"), &youtube);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("SysVol"), &sysvol);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("LiveChat"), &livechat);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Cast"), &cast);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("CLog"), &logger);
    qmlEngine.rootContext()->setContextProperty(QStringLiteral("Sfx"), &sfx);

    qmlEngine.load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    if (qmlEngine.rootObjects().isEmpty())
        return 1;

    auto *window = qobject_cast<QQuickWindow *>(qmlEngine.rootObjects().first());
    controller.attachWindow(window);
    cast.start(); // discovery begins after the UI is up (spec: async, non-blocking)
    // the YouTube worker at idle: who's signed in (and the player's login)
    // is known before the first YouTube anything
    QTimer::singleShot(1200, &youtube, &YouTubeSource::start);

    // Dev hook: CODEC_FPS=1 prints, once a second, frames swapped, the ms spent
    // syncing+rendering them, and the process CPU% — the idle-cost meter. A
    // still screen should read ~0 fps; anything near the refresh rate is an
    // animation or binding keeping the window awake. (On the threaded render
    // loop "render ms/s" includes the wait for vsync: it reads ~1000 there.)
    // It also flags HITCHES: `[stall]` = the GUI thread was blocked (a 10 ms
    // heartbeat fired late), `[slow-frame]` = one sync+render took too long —
    // each stamped with ms since launch and the stage, to line up with input.
    if (qEnvironmentVariableIntValue("CODEC_FPS") > 0) {
        auto *frames = new int(0);
        auto *renderNs = new qint64(0);
        auto *frameClock = new QElapsedTimer;
        auto *sinceLaunch = new QElapsedTimer;
        sinceLaunch->start();
        auto stamp = [sinceLaunch, &controller] {
            return QStringLiteral("t=%1 [%2]").arg(sinceLaunch->elapsed()).arg(controller.stage()).toUtf8();
        };
        QObject::connect(window, &QQuickWindow::beforeSynchronizing, window,
                         [frameClock] { frameClock->start(); }, Qt::DirectConnection);
        // frame PACING: the gap between presents. The shortest gap in a second
        // is the display's refresh period (steady frames present every one);
        // a gap 1.6x that or more is a refresh the frame missed — the
        // stutter a busy scene shows at 170 Hz that 60 Hz hides.
        auto *gapClock = new QElapsedTimer;
        auto *gaps = new QList<qint64>;
        QObject::connect(window, &QQuickWindow::frameSwapped, window, [gapClock, gaps] {
            if (gapClock->isValid()) gaps->append(gapClock->nsecsElapsed());
            gapClock->start();
        }, Qt::DirectConnection);
        QObject::connect(window, &QQuickWindow::frameSwapped, window, [frames, renderNs, frameClock, stamp] {
            ++*frames;
            if (!frameClock->isValid()) return;
            const qint64 ns = frameClock->nsecsElapsed();
            *renderNs += ns;
            if (ns > 30'000'000)
                std::fprintf(stderr, "[slow-frame] %6.1f ms  %s\n", ns / 1e6, stamp().constData());
        }, Qt::DirectConnection);
        QObject::connect(&controller, &AppController::stageChanged, window, [stamp] {
            std::fprintf(stderr, "[stage] %s\n", stamp().constData());
        });
        auto *beat = new QTimer(window);
        auto *beatClock = new QElapsedTimer;
        beatClock->start();
        QObject::connect(beat, &QTimer::timeout, window, [beatClock, stamp] {
            const qint64 gap = beatClock->restart();
            if (gap > 60)
                std::fprintf(stderr, "[stall] %5lld ms  %s\n", gap - 10, stamp().constData());
        });
        beat->setTimerType(Qt::PreciseTimer);
        beat->start(10);
        auto *tick = new QTimer(window);
        auto *lastCpu = new std::clock_t(std::clock());
        auto *mpvEngine = qobject_cast<MpvEngine *>(&engine);
        QObject::connect(tick, &QTimer::timeout, window, [frames, renderNs, lastCpu, mpvEngine, gaps] {
            const std::clock_t now = std::clock();
            // (read on the GUI thread while the render thread appends: a dev
            // meter, a stray race costs one sample)
            const QList<qint64> g = std::exchange(*gaps, {});
            qint64 shortest = 0, longest = 0; int missed = 0;
            for (qint64 x : g) { if (!shortest || x < shortest) shortest = x; longest = qMax(longest, x); }
            for (qint64 x : g) if (shortest && x >= shortest * 16 / 10) ++missed;
            const QByteArray fs = (mpvEngine ? mpvEngine->frameStats() : QString())
                .append(QStringLiteral("  mpv asks %1/s").arg(MpvVideoItem::takeUpdateRequests())).toUtf8();
            std::fprintf(stderr, "[fps] %3d fps  render %6.1f ms/s  cpu %5.1f%%  missed %d longest %.1f ms  %s\n", *frames,
                         *renderNs / 1e6, 100.0 * double(now - *lastCpu) / CLOCKS_PER_SEC,
                         missed, longest / 1e6, fs.constData());
            *frames = 0; *renderNs = 0; *lastCpu = now;
        });
        tick->start(1000);
    }

    // Dev hook: CODEC_SHOT=/path.png renders offscreen, grabs the window and
    // exits — pixel-verifies QML at any resolution without a live session.
    // CODEC_SHOT_STAGE=home|movies|tv|youtube|settings, CODEC_SHOT_SIZE=WxH,
    // CODEC_SHOT_DELAY=ms.
    const QString shotPath = qEnvironmentVariable("CODEC_SHOT");
    if (!shotPath.isEmpty()) {
        const QString stage = qEnvironmentVariable("CODEC_SHOT_STAGE");
        // CODEC_SHOT_MODE=crt|hd — the display mode to render in (layout only).
        if (!qEnvironmentVariable("CODEC_SHOT_MODE").isEmpty())
            controller.setShotMode(qEnvironmentVariable("CODEC_SHOT_MODE").toLower());
        const QString size = qEnvironmentVariable("CODEC_SHOT_SIZE");
        if (size.contains(QLatin1Char('x')))
            window->resize(size.section(QLatin1Char('x'), 0, 0).toInt(),
                           size.section(QLatin1Char('x'), 1, 1).toInt());
        int delay = qEnvironmentVariableIntValue("CODEC_SHOT_DELAY");
        if (delay <= 0)
            delay = 2500;
        QTimer::singleShot(400, window, [&controller, &library, stage] {
            if (stage.isEmpty())
                return;
            // The normal scan trigger is chooseDisplay(), but that path
            // fullscreens and asks Hyprland to move the REAL focused window
            // — never from a headless shot. Scan directly instead.
            library.rescan();
            if (stage == QLatin1String("home"))
                QMetaObject::invokeMethod(&controller, "goHome");
            else
                QMetaObject::invokeMethod(&controller, "openSection",
                                          Q_ARG(QString, stage));
        });
        // CODEC_SHOT_KEYS="j,j,k,1" — synthetic keypresses (180ms apart,
        // starting at 900ms) so scroll/zone/focus flows verify headlessly.
        const QString keys = qEnvironmentVariable("CODEC_SHOT_KEYS");
        // CODEC_SHOT_KEYS_AT=ms — when the first key fires (default 900). Views
        // that load over the network (YouTube) need the data before keys mean anything.
        int keysAt = qEnvironmentVariableIntValue("CODEC_SHOT_KEYS_AT");
        if (keysAt <= 0)
            keysAt = 900;
        if (!keys.isEmpty()) {
            const QStringList seq = keys.split(QLatin1Char(','), Qt::SkipEmptyParts);
            for (int i = 0; i < seq.size(); ++i) {
                QString rawk = seq[i].trimmed();
                // "S:<key>" applies Shift (e.g. "S:bsl", "S:r") so modifier combos
                // can be driven headlessly
                Qt::KeyboardModifiers mods = Qt::NoModifier;
                if (rawk.startsWith(QLatin1String("S:"))) { mods = Qt::ShiftModifier; rawk = rawk.mid(2); }
                const QString k = rawk;
                QTimer::singleShot(keysAt + i * 180, window, [window, k, mods] {
                    // "W:up"/"W:down"/"W:left"/"W:right" — one wheel notch at
                    // the window centre ("W:down@XxY" to aim it), so scroll
                    // behaviour verifies headlessly like keys do.
                    // "T:<dir>" = the same notch labelled as a TOUCHPAD — what Qt's
                    // Wayland backend reports for every real scroll on the author's
                    // desktop (the trackball included).
                    // "B:<dir>" = a trackball BALL-scroll event (continuous: carries
                    // pixel deltas, 3 notches' worth), touchpad-labelled like the real one.
                    // "_" alone is a spacer (no event) to separate gestures in time.
                    if (k == QLatin1String("_"))
                        return;
                    // "SC:<scancode>[:hold]" — a remote key as the OFA sends it:
                    // nativeScanCode set (handleRemoteKey matches on it), Qt key
                    // per the scancode. ":hold" keeps it down 900 ms (> the 700 ms
                    // hold threshold) before the release.
                    // "Q:<name>" — a Qt media key: rec, stop, search, back, menu, select.
                    // "M:<back|fwd|mid>[@XxY]" — a mouse button press+release.
                    // "H:XxY" — the pointer moves (hovers) to window X,Y, no buttons.
                    if (k.startsWith(QLatin1String("SC:")) || k.startsWith(QLatin1String("Q:"))) {
                        const QStringList parts = k.split(QLatin1Char(':'));
                        const bool hold = parts.size() > 2 && parts[2] == QLatin1String("hold");
                        int qkey = 0;
                        quint32 scan = 0;
                        if (parts[0] == QLatin1String("SC")) {
                            scan = parts.value(1).toUInt();
                        } else {
                            const QString n = parts.value(1);
                            qkey = n == QLatin1String("rec") ? Qt::Key_MediaRecord
                                 : n == QLatin1String("stop") ? Qt::Key_MediaStop
                                 : n == QLatin1String("search") ? Qt::Key_Search
                                 : n == QLatin1String("back") ? Qt::Key_Back
                                 : n == QLatin1String("menu") ? Qt::Key_Menu
                                 : n == QLatin1String("select") ? Qt::Key_Select : 0;
                        }
                        auto *press = new QKeyEvent(QEvent::KeyPress, qkey, Qt::NoModifier, scan, 0, 0);
                        QCoreApplication::sendEvent(window, press);
                        delete press;
                        QTimer::singleShot(hold ? 900 : 30, window, [window, qkey, scan] {
                            QKeyEvent rel(QEvent::KeyRelease, qkey, Qt::NoModifier, scan, 0, 0);
                            QCoreApplication::sendEvent(window, &rel);
                        });
                        return;
                    }
                    if (k.startsWith(QLatin1String("H:"))) {
                        const QStringList xy = k.mid(2).split(QLatin1Char('x'));
                        const QPointF at(xy.value(0).toDouble(), xy.value(1).toDouble());
                        QMouseEvent mv(QEvent::MouseMove, at, window->mapToGlobal(at),
                                       Qt::NoButton, Qt::NoButton, Qt::NoModifier);
                        QCoreApplication::sendEvent(window, &mv);
                        return;
                    }
                    // "LD:XxY" / "LM:XxY" / "LU:XxY" — the LEFT button down / moved
                    // while held / up at window X,Y, so drags verify headlessly.
                    if (k.startsWith(QLatin1String("LD:")) || k.startsWith(QLatin1String("LM:"))
                        || k.startsWith(QLatin1String("LU:"))) {
                        const QStringList xy = k.mid(3).split(QLatin1Char('x'));
                        const QPointF at(xy.value(0).toDouble(), xy.value(1).toDouble());
                        const QEvent::Type t = k[1] == QLatin1Char('D') ? QEvent::MouseButtonPress
                                             : k[1] == QLatin1Char('M') ? QEvent::MouseMove
                                             : QEvent::MouseButtonRelease;
                        QMouseEvent ev(t, at, window->mapToGlobal(at),
                                       t == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton,
                                       t == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton,
                                       Qt::NoModifier);
                        QCoreApplication::sendEvent(window, &ev);
                        return;
                    }
                    if (k.startsWith(QLatin1String("M:"))) {
                        QString b = k.mid(2);
                        QPointF at(window->width() / 2.0, window->height() / 2.0);
                        if (b.contains(QLatin1Char('@'))) {
                            const QStringList xy = b.section(QLatin1Char('@'), 1).split(QLatin1Char('x'));
                            if (xy.size() == 2) at = QPointF(xy[0].toDouble(), xy[1].toDouble());
                            b = b.section(QLatin1Char('@'), 0, 0);
                        }
                        const Qt::MouseButton btn = b == QLatin1String("back") ? Qt::BackButton
                                                  : b == QLatin1String("fwd") ? Qt::ForwardButton
                                                  : Qt::MiddleButton;
                        QMouseEvent pr(QEvent::MouseButtonPress, at, window->mapToGlobal(at), btn, btn, Qt::NoModifier);
                        QCoreApplication::sendEvent(window, &pr);
                        QMouseEvent rl(QEvent::MouseButtonRelease, at, window->mapToGlobal(at), btn, Qt::NoButton, Qt::NoModifier);
                        QCoreApplication::sendEvent(window, &rl);
                        return;
                    }
                    if (k.startsWith(QLatin1String("W:")) || k.startsWith(QLatin1String("T:"))
                        || k.startsWith(QLatin1String("B:"))) {
                        const bool ball = k.startsWith(QLatin1String("B:"));
                        const bool asPad = ball || k.startsWith(QLatin1String("T:"));
                        QString dir = k.mid(2);
                        QPointF at(window->width() / 2.0, window->height() / 2.0);
                        if (dir.contains(QLatin1Char('@'))) {
                            // "@XxY" — an 'x', not a comma: the key list itself is
                            // comma-separated, so "@1700,400" was split into two
                            // keys and every aimed scroll silently hit the centre.
                            const QStringList xy = dir.section(QLatin1Char('@'), 1).split(QLatin1Char('x'));
                            if (xy.size() == 2)
                                at = QPointF(xy[0].toDouble(), xy[1].toDouble());
                            dir = dir.section(QLatin1Char('@'), 0, 0);
                        }
                        const QPoint ang = dir == QLatin1String("up") ? QPoint(0, 120)
                                         : dir == QLatin1String("down") ? QPoint(0, -120)
                                         : dir == QLatin1String("left") ? QPoint(120, 0)
                                                                        : QPoint(-120, 0);
                        static const QPointingDevice pad(
                            QStringLiteral("shot-touchpad"), 4242,
                            QInputDevice::DeviceType::TouchPad,
                            QPointingDevice::PointerType::Finger,
                            QInputDevice::Capability::Position | QInputDevice::Capability::Scroll,
                            1, 3);
                        const QPoint pix = ball ? ang * 3 / 12 : QPoint();
                        QWheelEvent we(at, window->mapToGlobal(at), pix, ball ? ang * 3 : ang,
                                       Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false,
                                       Qt::MouseEventNotSynthesized,
                                       asPad ? &pad : QPointingDevice::primaryPointingDevice());
                        QCoreApplication::sendEvent(window, &we);
                        return;
                    }
                    int code = Qt::Key_unknown;
                    if (k == QLatin1String("[")) {
                        code = Qt::Key_BracketLeft;
                    } else if (k == QLatin1String("]")) {
                        code = Qt::Key_BracketRight;
                    } else if (k == QLatin1String("=")) {
                        code = Qt::Key_Equal;    // next editor page (checked
                    } else if (k == QLatin1String("-")) {
                        code = Qt::Key_Minus;    // prev editor page — both are
                                                 // size-1, so must beat the
                                                 // isLetter/isDigit branch below
                    } else if (k == QLatin1String(",")) {
                        code = Qt::Key_Comma;    // forge: prev strip frame
                    } else if (k == QLatin1String(".")) {
                        code = Qt::Key_Period;   // forge: next strip frame
                    } else if (k == QLatin1String("`") || k == QLatin1String("grave")) {
                        code = Qt::Key_QuoteLeft;  // open/close the garage editor
                    } else if (k.size() == 1) {
                        const QChar c = k[0];
                        if (c.isLetter())
                            code = Qt::Key_A + (c.toUpper().unicode() - 'A');
                        else if (c.isDigit())
                            code = Qt::Key_0 + (c.unicode() - '0');
                        else if (c == QLatin1Char('/'))
                            code = Qt::Key_Slash;
                        else if (c == QLatin1Char('?'))
                            code = Qt::Key_Question;   // help overlay
                    } else if (k == QLatin1String("ret")) {
                        code = Qt::Key_Return;
                    } else if (k == QLatin1String("esc")) {
                        code = Qt::Key_Escape;
                    } else if (k == QLatin1String("spc")) {
                        code = Qt::Key_Space;
                    } else if (k == QLatin1String("up")) {
                        code = Qt::Key_Up;
                    } else if (k == QLatin1String("down")) {
                        code = Qt::Key_Down;
                    } else if (k == QLatin1String("left")) {
                        code = Qt::Key_Left;
                    } else if (k == QLatin1String("right")) {
                        code = Qt::Key_Right;
                    } else if (k == QLatin1String("pgdn")) {
                        code = Qt::Key_PageDown;
                    } else if (k == QLatin1String("pgup")) {
                        code = Qt::Key_PageUp;
                    } else if (k == QLatin1String("bsl")) {
                        code = Qt::Key_Backslash; // save
                    }
                    if (code == Qt::Key_unknown)
                        return;
                    QKeyEvent press(QEvent::KeyPress, code, mods, k);
                    QKeyEvent release(QEvent::KeyRelease, code, mods, k);
                    QCoreApplication::sendEvent(window, &press);
                    QCoreApplication::sendEvent(window, &release);
                });
            }
        }
        // CODEC_SHOT_EVAL="App.queueOpen=true; queuePanel.mode='load'" — evaluate
        // arbitrary QML/JS in Main.qml's scope after load. Reaches the context
        // objects (App, Engine, Queue, MediaLibrary, …) AND Main.qml's root ids
        // (queuePanel, homeView, …), so any state — panel sub-modes, injected data,
        // a mocked now-playing (Engine.shotMockPlaying('Title')) — renders without
        // focus-sensitive synthetic keys. Runs ~300ms before the grab so bindings
        // and layout settle; override the moment with CODEC_SHOT_EVAL_DELAY.
        // CODEC_SHOT_EVAL2 / CODEC_SHOT_EVAL2_DELAY — a second expression at its
        // own moment (start something with EVAL, probe or act on it later).
        const QString eval2 = qEnvironmentVariable("CODEC_SHOT_EVAL2");
        if (!eval2.isEmpty()) {
            const int at2 = qMax(800, qEnvironmentVariableIntValue("CODEC_SHOT_EVAL2_DELAY"));
            QTimer::singleShot(at2, window, [window, eval2] {
                QQmlContext *ctx = QQmlEngine::contextForObject(window);
                QQmlExpression expr(ctx, window, eval2);
                const QVariant r = expr.evaluate();
                if (expr.hasError())
                    qWarning().noquote() << "[shot-eval2] ERROR:" << expr.error().toString();
                else
                    qInfo().noquote() << "[shot-eval2] ok:" << (r.isValid() ? r.toString() : QString());
            });
        }
        const QString evalStr = qEnvironmentVariable("CODEC_SHOT_EVAL");
        if (!evalStr.isEmpty()) {
            int evalAt = qEnvironmentVariableIntValue("CODEC_SHOT_EVAL_DELAY");
            if (evalAt <= 0)
                evalAt = qMax(800, delay - 300);
            QTimer::singleShot(evalAt, window, [window, evalStr] {
                QQmlContext *ctx = QQmlEngine::contextForObject(window);
                QQmlExpression expr(ctx, window, evalStr);
                const QVariant r = expr.evaluate();
                if (expr.hasError())
                    qWarning().noquote() << "[shot-eval] ERROR:" << expr.error().toString();
                else
                    qInfo().noquote() << "[shot-eval] ok:" << evalStr
                                      << (r.isValid() ? "->" + r.toString() : QString());
            });
        }
        QTimer::singleShot(delay, window, [window, shotPath] {
            window->grabWindow().save(shotPath);
            QCoreApplication::quit();
        });
    }

    // No running instance to forward to. `--enqueue` holds every file for the
    // queue (nothing plays); a plain multi-file open plays the first and queues
    // the rest — both applied once the library is scanned (enterAfterChooser).
    if (cliEnqueue)
        controller.setPendingEnqueue(absFiles);
    else if (absFiles.size() > 1)
        controller.setPendingEnqueue(absFiles.mid(1));
    controller.setCliOptions(parser.value(QStringLiteral("display")),
                             parser.value(QStringLiteral("mode")),
                             (cliEnqueue || absFiles.isEmpty()) ? QString()
                                                                : absFiles.first());

    // Restore the display out of HDR on EVERY exit path (window-close,
    // SIGTERM/pkill, Ctrl+C) — not just the in-app mod+Q quit(). Idempotent, so
    // it's a no-op when quit() already handed it back.
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     [&controller] {
                         Logger::log(QStringLiteral("exit"),
                                     QStringLiteral("clean shutdown — restoring HDR if engaged"));
                         controller.ensureHdrRestored();
                     });

    // Turn SIGTERM/SIGINT into a clean QCoreApplication::quit() (→ aboutToQuit
    // above) so a `pkill codec` no longer strands the monitor in HDR.
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, g_sigFd) == 0) {
        auto *sn = new QSocketNotifier(g_sigFd[1], QSocketNotifier::Read, &app);
        QObject::connect(sn, &QSocketNotifier::activated, &app, [sn] {
            sn->setEnabled(false);
            char c; ssize_t r = ::read(g_sigFd[1], &c, 1); (void)r;
            QCoreApplication::quit();
        });
        struct sigaction sa {};
        sa.sa_handler = unixSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        ::sigaction(SIGTERM, &sa, nullptr);
        ::sigaction(SIGINT, &sa, nullptr);
    }

    return app.exec();
}
