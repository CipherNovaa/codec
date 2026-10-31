#pragma once

#include <QObject>
#include <QSysInfo>
#include <functional>
#include <QHash>
#include <QPoint>
#include <QSet>
#include <QSurfaceFormat>
#include <QElapsedTimer>
#include <QTimer>
#include <QFileSystemWatcher>
#include <QVariantList>

class CastManager;
class YouTubeSource;
class UiSound;
class Library;
class PlaybackEngine;
class QueueModel;
class QKeyEvent;
class ResumeStore;
class QQuickWindow;
class QJsonObject;
class Theme;

// Orchestrates the launch flow (display -> mode -> library -> player),
// window placement, mode profiles, queue advance, and resume bookkeeping.
class AppController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString stage READ stage NOTIFY stageChanged)
    Q_PROPERTY(int heroDevRev READ heroDevRev NOTIFY heroDevRevChanged)
    Q_PROPERTY(QString version READ version CONSTANT)
    // HUB / SATELLITE — the role follows the library's manifest mode, which a
    // hub-sync can change at runtime, so it notifies (it was marked CONSTANT).
    Q_PROPERTY(QString deviceRole READ deviceRole NOTIFY deviceRoleChanged)
    Q_PROPERTY(QVariantList monitors READ monitors NOTIFY monitorsChanged)
    Q_PROPERTY(QString mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(QString display READ display NOTIFY modeChanged)
    // Queue sidebar visibility + PiP dock corner — controller-held so every
    // view (separate QML files) reads/writes the same state.
    // Set by the HOME/STATS garage editor while open: its MouseAreas page with
    // the thumb buttons, so the app-wide mouse back/forward must stand aside.
    Q_PROPERTY(bool garageEditing READ garageEditing WRITE setGarageEditing NOTIFY garageEditingChanged)
    // The detail page is showing its BONUS FEATURES (DetailView binds this), so
    // Back/Forward can step into and out of it like a page.
    Q_PROPERTY(bool detailBonus READ detailBonus WRITE setDetailBonus NOTIFY detailBonusChanged)
    Q_PROPERTY(bool queueOpen READ queueOpen WRITE setQueueOpen NOTIFY queueOpenChanged)
    // PlayerView sets this while a prompt that owns Enter is up (UP NEXT /
    // "still watching?" / SKIP INTRO), so the remote's OK accepts it instead
    // of pausing underneath it.
    Q_PROPERTY(bool playerPrompt READ playerPrompt WRITE setPlayerPrompt NOTIFY playerPromptChanged)
    Q_PROPERTY(bool outputOpen READ outputOpen WRITE setOutputOpen NOTIFY outputOpenChanged)
    Q_PROPERTY(bool remoteOpen READ remoteOpen WRITE setRemoteOpen NOTIFY remoteOpenChanged)
    // Chapter marks for whatever is CASTING. Engine.chapters comes from mpv,
    // and while casting mpv is not the player — the hub has to supply them.
    Q_PROPERTY(QVariantList castChapters READ castChapters NOTIFY castChaptersChanged)
    Q_PROPERTY(bool searchOpen READ searchOpen WRITE setSearchOpen NOTIFY searchOpenChanged)
    Q_PROPERTY(QString detailUri READ detailUri WRITE setDetailUri NOTIFY detailUriChanged)
    // Network media source health for the settings page ("is the hub up?").
    Q_PROPERTY(QString hubStatus READ hubStatus NOTIFY hubStatusChanged)
    Q_PROPERTY(double subtitleScale READ subtitleScale NOTIFY subtitleScaleChanged)
    Q_PROPERTY(bool nightMode READ nightMode NOTIFY nightModeChanged)
    Q_PROPERTY(bool mechPalette READ mechPalette NOTIFY mechPaletteChanged)
    Q_PROPERTY(bool editorEnabled READ editorEnabled NOTIFY editorEnabledChanged)
    Q_PROPERTY(bool hdrDirect READ hdrDirect NOTIFY hdrDirectChanged)
    // True while the panel + window are in PQ passthrough (fullscreen HDR
    // playback). QML gates the PQ-encode chrome layer on this.
    Q_PROPERTY(bool hdrEngaged READ hdrEngaged NOTIFY hdrEngagedChanged)
    // {start,end} of the current file's opening titles, empty when unknown.
    // Detected offline by scripts/codec_intro.py; drives the SKIP INTRO pill
    // for the vast majority of rips, which carry no chapter markers.
    Q_PROPERTY(QVariantMap introRange READ introRange NOTIFY introRangeChanged)
    // Device pairing (scripts/codec_pairing.py): a device asking to join this
    // hub (the first pending request — {rid, id, name, kind, ip} — or empty),
    // the devices already paired, and whether the hub trusts its whole network.
    Q_PROPERTY(QVariantMap pairRequest READ pairRequest NOTIFY pairRequestChanged)
    Q_PROPERTY(QVariantList pairedDevices READ pairedDevices NOTIFY pairedDevicesChanged)
    Q_PROPERTY(bool lanOpen READ lanOpen NOTIFY lanOpenChanged)
    // SHARE THIS LIBRARY: is this hub's server (codec-serve, a background
    // service) running? "on" | "off" | "busy" | "unsupported" (no systemd).
    Q_PROPERTY(QString sharing READ sharing NOTIFY sharingChanged)
    // Attract mode: after a spell of no input on a browse screen, the app
    // gives the room a cinematic slideshow instead of a parked menu.
    Q_PROPERTY(bool attract READ attract NOTIFY attractChanged)
    Q_PROPERTY(int attractMinutes READ attractMinutes NOTIFY attractMinutesChanged)
    // Seconds each home spotlight backdrop holds before the carousel advances.
    Q_PROPERTY(int spotlightSeconds READ spotlightSeconds NOTIFY spotlightSecondsChanged)
    // How the mini-info synopsis reveals: redact | light | type | off.
    Q_PROPERTY(QString redactionStyle READ redactionStyle NOTIFY redactionStyleChanged)
    // Glass level for the menu/queue/OSD/picker plate backings (1.0 = solid,
    // lower = glassier). The home wheel buttons are tuned separately.
    Q_PROPERTY(double glassLevel READ glassLevel NOTIFY glassLevelChanged)
    Q_PROPERTY(bool pipLeft READ pipLeft WRITE setPipLeft NOTIFY pipCornerChanged)
    Q_PROPERTY(bool pipTop READ pipTop WRITE setPipTop NOTIFY pipCornerChanged)
    // The OFA remote's configurable keys (SPARE 1-10 + the four colours) as
    // rows for Settings: [{slot, name, action, label}]. Edited with
    // stepRemoteSlot / setRemoteSlot; the words persist in settings.remoteSpares
    // and settings.remoteColors — the same lists handleRemoteKey reads.
    Q_PROPERTY(QVariantList remoteMap READ remoteMap NOTIFY remoteMapChanged)
    // SLEEP timer state (the remote's SLEEP key and the Settings row share it):
    // the armed preset (0 = off) and when it fires, ms since the epoch (0 = off).
    Q_PROPERTY(int sleepMinutes READ sleepMinutes NOTIFY sleepChanged)
    Q_PROPERTY(double sleepEndsAt READ sleepEndsAt NOTIFY sleepChanged)
    // Who this screen is in a watch party (settings.partyName, else the hub's
    // party.hostName, else the hostname) — editable from Settings.
    Q_PROPERTY(QString partyName READ partyMyName NOTIFY partyNameChanged)
    // How this machine reaches the hub right now — ONE answer every hub call
    // reads (hubBase), the top strip shows, and Settings reports:
    //   "hub"     this machine IS the hub (no syncUrl)
    //   "lan"     the hub's LAN address answers → stream direct
    //   "tailnet" the LAN doesn't, the Tailscale address does → everything
    //             (watch-state sync, manifest, cast queue, subs, chapters)
    //             goes over the tailnet, not just play()
    //   "fastroad" / "funnel"  no private road, but the hub's PUBLIC door
    //             answers with the browse token this machine holds → the
    //             library plays and casts over it (the title's own file at
    //             full quality on the fast road; the DV / HDR10 / ladder
    //             lanes for a cast); the private calls (sync, queue, party)
    //             wait for a private road
    //   "away"    nothing answers → the library browses from the manifest +
    //             art cache; plays refuse instead of hanging on a dead URL
    //   ""        not probed yet
    // Probed asynchronously every 30 s (and right after a failed load).
    Q_PROPERTY(QString hubLink READ hubLink NOTIFY hubLinkChanged)
    // Who owns selection right now: true after real cursor motion, false the
    // moment a key is pressed. Hover-select handlers gate on this so content
    // sliding under a PARKED cursor (keyboard scroll) can never steal the
    // selection — the per-delegate scene filters miss the delegate-boundary
    // case, this can't.
    Q_PROPERTY(bool pointerActive READ pointerActive NOTIFY pointerActiveChanged)
    // True while the current local playback is a live stream (no resume, no
    // duration; unlocks the live-chat panel on "c").
    // ── live DVR (local playback of a YouTube livestream) ──
    // The bar spans YouTube's own DVR window (~4 h). At the live edge playback
    // is the hub restream; rewinding plays a seekable SNAPSHOT of YouTube's
    // playlist (liveDvr), and catching up returns to the restream.
    Q_PROPERTY(bool liveDvr READ liveDvr NOTIFY liveStateChanged)
    Q_PROPERTY(double liveWindow READ liveWindow NOTIFY liveStateChanged)   // seconds the bar spans
    Q_PROPERTY(double livePos READ livePos NOTIFY liveStateChanged)         // playhead, s from window start
    Q_PROPERTY(double liveBehind READ liveBehind NOTIFY liveStateChanged)   // s behind the live edge
    Q_PROPERTY(double liveWatched READ liveWatched NOTIFY liveStateChanged) // s YOU have watched
    Q_PROPERTY(double liveFor READ liveFor NOTIFY liveStateChanged)         // s since the broadcast began (0 = unknown)
    Q_PROPERTY(bool liveNow READ liveNow NOTIFY liveNowChanged)
    Q_PROPERTY(int seekStep READ seekStep NOTIFY seekStepChanged)
    // Cast captions. They live here rather than in the receiver because the
    // receiver is a page the hub GENERATES — so a setting made on this screen
    // reaches every television the house casts to.
    Q_PROPERTY(int castCaptionScale READ castCaptionScale NOTIFY castCaptionsChanged)
    Q_PROPERTY(bool castCaptionBg READ castCaptionBg NOTIFY castCaptionsChanged)
    Q_PROPERTY(bool localCaptionBg READ localCaptionBg NOTIFY localCaptionsChanged)
    Q_PROPERTY(bool subHonourStyle READ subHonourStyle NOTIFY localCaptionsChanged)
    Q_PROPERTY(QString subTimingStatus READ subTimingStatus NOTIFY subTimingStatusChanged)
    Q_PROPERTY(QString castCaptionFontLabel READ castCaptionFontLabel NOTIFY castCaptionsChanged)
    Q_PROPERTY(QString castCaptionColorName READ castCaptionColorName NOTIFY castCaptionsChanged)
    Q_PROPERTY(QString castCaptionColorHex READ castCaptionColorHex NOTIFY castCaptionsChanged)
    // LOCAL captions (mpv, this screen) — same font/colour dials as cast; size is
    // the existing subtitleScale, reworked into "LOCAL CAPTION SIZE" in Settings.
    Q_PROPERTY(QString localCaptionFontLabel READ localCaptionFontLabel NOTIFY localCaptionsChanged)
    Q_PROPERTY(QString localCaptionColorName READ localCaptionColorName NOTIFY localCaptionsChanged)
    Q_PROPERTY(QString localCaptionColorHex READ localCaptionColorHex NOTIFY localCaptionsChanged)
    // Default audio-language preference (global first-time/tiebreak pick; a
    // per-film choice still overrides it). Lives at top-level audio.language in
    // config.json, which the cast worker already reads.
    Q_PROPERTY(QString audioLanguageLabel READ audioLanguageLabel NOTIFY audioLanguageChanged)
    Q_PROPERTY(bool autoplayNext READ autoplayNext NOTIFY autoplayNextChanged)
    Q_PROPERTY(QString hdrPeakLabel READ hdrPeakLabel NOTIFY hdrPeakChanged)
    // True while a library enrichment (art scrape) is in flight — QML shows an
    // "UPDATING LIBRARY" indicator and a shimmer on not-yet-scraped posters.
    Q_PROPERTY(bool libraryUpdating READ libraryUpdating NOTIFY libraryUpdatingChanged)
    Q_PROPERTY(int libraryNewCount READ libraryNewCount NOTIFY libraryUpdatingChanged)
    // Result of the last library audit — "" until one has been run.
    Q_PROPERTY(bool libraryAuditing READ libraryAuditing NOTIFY libraryAuditChanged)
    Q_PROPERTY(QString libraryAuditResult READ libraryAuditResult NOTIFY libraryAuditChanged)
    // "off" | "launch" | "live" — how aggressively the library keeps itself in
    // step with disk. Live adds the filesystem watcher (default).
    Q_PROPERTY(QString autoUpdate READ autoUpdate NOTIFY autoUpdateChanged)
    // Watch party (0.9.19): a movie playing in sync across screens that aren't
    // in the same house. The session lives on the HUB, not in this app — every
    // codec on the network polls for it, so opening codec anywhere shows what
    // is running and can join it. partyOpen = the `w` overlay.
    //
    //   partyLive       a session exists on the hub (whoever started it)
    //   partyHosting    THIS app publishes the clock (app-mode party)
    //   partyFollowing  THIS app is playing along with a hub-owned session
    //   partyDriving    our transport keys drive the session, not just us
    Q_PROPERTY(bool partyOpen READ partyOpen WRITE setPartyOpen NOTIFY partyOpenChanged)
    Q_PROPERTY(bool partyLive READ partyLive NOTIFY partyChanged)
    Q_PROPERTY(bool partyActive READ partyActive NOTIFY partyChanged)
    Q_PROPERTY(bool partyHosting READ partyHosting NOTIFY partyChanged)
    Q_PROPERTY(bool partyFollowing READ partyFollowing NOTIFY partyChanged)
    Q_PROPERTY(bool partyDriving READ partyDriving NOTIFY partyChanged)
    Q_PROPERTY(bool partyHubMode READ partyHubMode NOTIFY partyChanged)
    Q_PROPERTY(QString partyTitle READ partyTitle NOTIFY partyChanged)
    // a film change holding everyone until they have it, and what's on next
    Q_PROPERTY(bool partyLoading READ partyLoading NOTIFY partyChanged)
    Q_PROPERTY(QString partyNext READ partyNext NOTIFY partyChanged)
    Q_PROPERTY(bool partyPaused READ partyPaused NOTIFY partyChanged)
    Q_PROPERTY(double partyPos READ partyPos NOTIFY partyChanged)
    Q_PROPERTY(double partyDur READ partyDur NOTIFY partyChanged)
    Q_PROPERTY(bool partyHaveFile READ partyHaveFile NOTIFY partyChanged)
    Q_PROPERTY(QStringList partyWho READ partyWho NOTIFY partyChanged)
    // [{name, rtt, watching, me}] — the room, for the overlay's ping dots.
    Q_PROPERTY(QVariantList partyRoom READ partyRoom NOTIFY partyChanged)
    // The room's talk. A rolling list of {who, text, kind, t} — the same ring
    // the hub keeps, so every screen sees the same conversation.
    Q_PROPERTY(QVariantList partyChat READ partyChat NOTIFY partyChatChanged)
    Q_PROPERTY(int partyVotes READ partyVotes NOTIFY partyChanged)
    Q_PROPERTY(int partyVotesNeed READ partyVotesNeed NOTIFY partyChanged)
    Q_PROPERTY(bool partyLocked READ partyLocked NOTIFY partyChanged)
    Q_PROPERTY(QVariantList partyAsks READ partyAsks NOTIFY partyChanged)   // removed screens asking back in
    // The one cushion the whole room is holding, and who set it. Shown so a
    // room that's running a few seconds back has a visible reason rather than
    // feeling broken.
    Q_PROPERTY(int partyRoomLagMs READ partyRoomLagMs NOTIFY partyChanged)
    Q_PROPERTY(QString partyLagWho READ partyLagWho NOTIFY partyChanged)
    Q_PROPERTY(QStringList partyWaitingFor READ partyWaitingFor NOTIFY partyChanged)
    Q_PROPERTY(QString partyInviteUrl READ partyInviteUrl NOTIFY partyChanged)
    Q_PROPERTY(QString partyReceiverUrl READ partyReceiverUrl NOTIFY partyChanged)
    Q_PROPERTY(int partyPeers READ partyPeers NOTIFY partyChanged)

    // What another codec in the house has open right now (0.9.25). Presence,
    // not a session: one timeline MOVING between screens rather than one
    // timeline on several at once.
    Q_PROPERTY(bool nowElsewhere READ nowElsewhere NOTIFY nowChanged)
    Q_PROPERTY(QString nowWhere READ nowWhere NOTIFY nowChanged)
    Q_PROPERTY(QString nowTitle READ nowTitle NOTIFY nowChanged)
    Q_PROPERTY(double nowPos READ nowPos NOTIFY nowChanged)
    Q_PROPERTY(double nowDur READ nowDur NOTIFY nowChanged)
    Q_PROPERTY(bool nowPaused READ nowPaused NOTIFY nowChanged)
    Q_PROPERTY(bool nowIsYoutube READ nowIsYoutube NOTIFY nowChanged)
    // The title art for what THIS player shows: a library film's or show's
    // clearlogo (the detail page's title), "" for anything else — YouTube, a
    // file from outside the library, a title with no logo — which keeps the
    // OSD's words. The line beside the logo: an episode's "S01E03 · Name",
    // a film's year.
    Q_PROPERTY(QString playingLogo READ playingLogo NOTIFY playingLogoChanged)
    Q_PROPERTY(QString playingLogoLine READ playingLogoLine NOTIFY playingLogoChanged)
    // Logo or words for that title — right-click the OSD title to switch; kept.
    Q_PROPERTY(bool osdTitleLogo READ osdTitleLogo NOTIFY osdTitleLogoChanged)
    // FreeSync is running on our display: the window presents every refresh
    // (Main.qml's steady tick) — see updateSteadyFrames.
    Q_PROPERTY(bool steadyFrames READ steadyFrames NOTIFY steadyFramesChanged)
    // CODEC_FPS=1: the dev meter is on (QML adds its own timing lines)
    Q_PROPERTY(bool devMeter READ devMeter CONSTANT)
    // FRAME RATE (Settings ▸ DISPLAY): "display" = Qt's threaded render loop,
    // animations at the screen's own refresh; "60" = its basic loop's 60 Hz
    // timer. Chosen at start-up (main.cpp); pending = saved but not running yet.
    Q_PROPERTY(QString frameRateMode READ frameRateMode NOTIFY frameRateChanged)
    Q_PROPERTY(bool frameRatePending READ frameRatePending NOTIFY frameRateChanged)

public:
    void setYouTube(YouTubeSource *yt) { m_youtube = yt; }
    // UI sounds for the remote/mouse paths that never reach a view's key handler
    void setUiSound(UiSound *sfx) { m_sfx = sfx; updateSfxQuiet(); }
    AppController(PlaybackEngine *engine, ResumeStore *store, Library *library,
                  QueueModel *queue, CastManager *cast, QObject *parent = nullptr);

    bool garageEditing() const { return m_garageEditing; }
    void setGarageEditing(bool on) { if (on != m_garageEditing) { m_garageEditing = on; emit garageEditingChanged(); } }
    bool detailBonus() const { return m_detailBonus; }
    void setDetailBonus(bool on) { if (on != m_detailBonus) { m_detailBonus = on; emit detailBonusChanged(); } }
    QString stage() const { return m_stage; }
    QString version() const { return QStringLiteral(CODEC_VERSION); }
    QString deviceRole() const; // "HUB" (local roots) or "SATELLITE"
    QVariantList monitors() const { return m_monitors; }
    QString mode() const { return m_mode; }
    // CODEC_SHOT_MODE: render a mode (e.g. "crt") offscreen without choosing a
    // display — choosing one moves windows on the real desktop.
    void setShotMode(const QString &m) { m_mode = m; emit modeChanged(); }
    QString display() const { return m_display; }

    void attachWindow(QQuickWindow *window);
    void setCliOptions(const QString &display, const QString &mode, const QString &path);

    bool eventFilter(QObject *obj, QEvent *event) override;

    bool queueOpen() const { return m_queueOpen; }
    bool playerPrompt() const { return m_playerPrompt; }
    void setPlayerPrompt(bool on) { if (on != m_playerPrompt) { m_playerPrompt = on; emit playerPromptChanged(); } }
    void setQueueOpen(bool on);
    bool outputOpen() const { return m_outputOpen; }
    void setOutputOpen(bool on);
    bool remoteOpen() const { return m_remoteOpen; }
    QVariantList castChapters() const { return m_castChapters; }
    bool searchOpen() const { return m_searchOpen; }
    QString detailUri() const { return m_detailUri; }
    void setDetailUri(const QString &uri)
    {
        if (uri == m_detailUri)
            return;
        m_detailUri = uri;
        emit detailUriChanged();
    }
    Q_INVOKABLE void findSubtitles(); // online sub fetch: the film casting, else the one playing (again = refetch)
    Q_INVOKABLE void probeSubTiming(); // the hub's re-timing tally (Settings)
    Q_INVOKABLE void setSubtitleLift(bool lifted);
    void setSearchOpen(bool on);
    void setRemoteOpen(bool on);
    // Switch playback target ("" = this machine); hands the playing file over
    // with its position when something is mid-play.
    Q_INVOKABLE void setOutput(const QString &deviceId);
    bool pipLeft() const { return m_pipLeft; }
    void setPipLeft(bool v);
    bool pipTop() const { return m_pipTop; }
    void setPipTop(bool v);

    Q_INVOKABLE void chooseDisplay(const QString &name);
    // Carry codec to another screen mid-whatever (the remote's INPUT key, via
    // org.codec.App MoveTo): the film keeps playing, the mode follows the
    // screen. A screen not lit yet (the tube waking) is waited for.
    void moveToDisplay(const QString &name);
    // Bring codec's window to the front where it lives and hand it the pointer
    // without showing it (INPUT's last step, via org.codec.App Front).
    void frontWindow();
    void rehandPointer();   // after a surface rebuild: hand the parked pointer back (hidden cursor)
    Q_INVOKABLE void openSection(const QString &section); // movies|tv|youtube|settings[:section]
    // The Settings section an openSection("settings:<section>") asked for,
    // taken (and cleared) by the Settings view as it opens; "" = its own.
    Q_INVOKABLE QString takeSettingsJump() { const QString s = m_settingsJump; m_settingsJump.clear(); return s; }
    // Settings → REMOTE: the configurable keys. slot 0-9 = SPARE 1-10, 10-13 =
    // RED GREEN YELLOW BLUE. stepRemoteSlot walks the action vocabulary (dir
    // ±1); setRemoteSlot puts a named action on a key; remoteActions lists the
    // vocabulary ([{key, label}]) for a picker.
    QVariantList remoteMap() const;
    Q_INVOKABLE QVariantList remoteActions() const;
    Q_INVOKABLE void stepRemoteSlot(int slot, int dir);
    Q_INVOKABLE void setRemoteSlot(int slot, const QString &action);
    int sleepMinutes() const;
    double sleepEndsAt() const;
    Q_INVOKABLE void remoteSleepCycle(int dir = 1); // SLEEP tap: off → 30 → 60 min (dir -1 walks back)
    Q_INVOKABLE void setPartyName(const QString &name);
    // Settings → LIBRARY: the roads to the hub from config.json —
    // {role, link, lan, tailnet, funnel, direct, manifest}.
    Q_INVOKABLE QVariantMap hubLinks();
    QString hubLink() const { return m_hubLink; }
    Q_INVOKABLE void probeHubNow();            // re-probe the link right away (SYNC, the strip pill)
    // The satellite's art cache (~/.cache/codec/art): {files, bytes} — what the
    // library shows from when the hub is away.
    Q_INVOKABLE QVariantMap artCacheInfo() const;
    // Generic settings passthrough for QML — lets the icon-debug picker PERSIST
    // the wheel icon choices to config.json so they survive a restart (and can
    // be read back). Values live under the config "settings" object.
    Q_INVOKABLE void putSetting(const QString &key, const QVariant &value);
    Q_INVOKABLE QVariant getSetting(const QString &key, const QVariant &def = QVariant()) const;
    Q_INVOKABLE void goHome();
    Q_INVOKABLE void play(const QString &pathIn);
    // Play a MediaItem-shaped map (uri/title/kind/...) from any source.
    Q_INVOKABLE void playItem(const QVariantMap &itemIn);
    // Remote hold-CAST "resume the last thing" (the flagship). resumeTarget() is
    // the pure decision — WHAT to play and why ({kind,uri,startPos,title}) — with
    // no side effects, so it can be inspected/tested; remoteResumeLast() acts on
    // it (and is where the upstairs amp/TV power-on + cast wiring will slot in).
    Q_INVOKABLE QVariantMap resumeTarget() const;
    // Act on resumeTarget(). toCast=false → resume LOCALLY on this machine (the
    // device the remote is pointed at — the RESUME/Apps button); toCast=true →
    // target the TV and cast it (the CAST/Blue button). Two buttons, one brain.
    Q_INVOKABLE void remoteResumeLast(bool toCast = false);
    // Pop queue row `row` and play it now.
    Q_INVOKABLE void playQueued(int row);
    // ytsearch the movie's trailer and play it (ephemeral: no resume rows).
    Q_INVOKABLE void playTrailer(const QString &title, const QString &subtitle);
    Q_INVOKABLE void toPlayer();       // re-enter the running playback (or cast remote)
    // Cast remote actions: relative seek and skip-to-next on the TV.
    Q_INVOKABLE void castSeekRel(double delta);
    Q_INVOKABLE void castSeekTo(double pos); // absolute seek bar; routes to the room in party-via-cast (#218)
    Q_INVOKABLE void castTogglePause(); // routes to the party clock in party-via-cast
    Q_INVOKABLE void castNext();
    Q_INVOKABLE void castPrev();
    Q_INVOKABLE void playerNext(); // local queue/episode advance (PiP ctrl)
    Q_INVOKABLE void playerPrev(); // restart deep in, prev episode near start
    // External IPC / Dolphin integration (VLC-style single-instance forward):
    // enqueuePaths adds files to the queue ("Add to Playlist"); playPaths plays
    // the first and queues the rest ("Open"); presentWindow raises codec.
    Q_INVOKABLE void enqueuePaths(const QStringList &paths);
    Q_INVOKABLE void playPaths(const QStringList &paths);
    Q_INVOKABLE void presentWindow();
    // Ctrl-S in the player: compute a ~/Pictures/codec path and ask QML to grab
    // the rendered video item (vo=libmpv can't screenshot via mpv itself).
    Q_INVOKABLE void screenshot();
    void setPendingEnqueue(const QStringList &paths) { m_pendingEnqueue = paths; }
    Q_INVOKABLE void ytDownload(const QString &videoId, const QString &title);
    bool hdrDirect() const;
    Q_INVOKABLE void auditLibrary();   // is each file what codec says it is?
    Q_INVOKABLE void toggleHdrDirect();
    bool hdrEngaged() const { return m_hdrEngaged; }
    QVariantMap introRange() const { return m_introRange; }
    bool attract() const { return m_attract; }
    int attractMinutes() const;
    // Every cycle* takes a direction: Settings steps a value both ways with
    // Left/Right (dir -1 / +1); the old single-key callers keep the default.
    Q_INVOKABLE void cycleAttractDelay(int dir = 1); // off -> 2 -> 5 -> 10 min
    int spotlightSeconds() const;
    Q_INVOKABLE void cycleSpotlightSeconds(int dir = 1); // 10 -> 18 -> 30 -> off
    QString redactionStyle() const;
    Q_INVOKABLE void cycleRedactionStyle(int dir = 1);   // redact -> light -> type -> off
    double glassLevel() const;
    Q_INVOKABLE void cycleGlassLevel(int dir = 1);       // 1.0 -> 0.9 -> ... -> 0.4 -> wrap
    bool pointerActive() const { return m_pointerActive; }
    bool liveDvr() const { return m_liveDvr; }
    double liveWindow() const;
    double livePos() const;
    double liveBehind() const;
    double liveWatched() const;
    double liveFor() const;
    // Seek within the live DVR window: frac 0..1 of the bar (1 = live), or a
    // relative step in seconds. Caught up (< ~12 s behind) = back to live.
    Q_INVOKABLE void liveSeekFrac(double frac);
    Q_INVOKABLE void liveSeekBy(double seconds);
    Q_INVOKABLE void goLive();
    bool liveNow() const { return m_liveNow; }
    int seekStep() const;                 // small-seek size for h/l/arrows
    Q_INVOKABLE void cycleSeekStep(int dir = 1);     // 5 -> 10 -> 15 -> 30 s
    int castCaptionScale() const;         // percent; 100 = the receiver default
    bool castCaptionBg() const;
    Q_INVOKABLE void cycleCastCaptionScale(int dir = 1);
    Q_INVOKABLE void toggleCastCaptionBg();
    QString castCaptionFontLabel() const; // "MGS CODEC" / "SANS" / ...
    QString castCaptionColorName() const; // "WHITE" / "YELLOW" / ...
    QString castCaptionColorHex() const;  // "#FFFFFF" — the stored value
    Q_INVOKABLE void cycleCastCaptionFont(int dir = 1);
    Q_INVOKABLE void cycleCastCaptionColor(int dir = 1);

    QString localCaptionFontLabel() const;  // "MGS CODEC" / "SANS" / ...
    QString localCaptionFontFamily() const; // the mpv font family for the pick
    QString localCaptionColorName() const;  // "WHITE" / "YELLOW" / ...
    QString localCaptionColorHex() const;   // "#FFFFFF" — the stored value
    Q_INVOKABLE void cycleLocalCaptionFont(int dir = 1);
    Q_INVOKABLE void cycleLocalCaptionColor(int dir = 1);
    Q_INVOKABLE void toggleLocalCaptionBg();
    Q_INVOKABLE void toggleSubHonourStyle();
    Q_INVOKABLE void toggleOsdTitleLogo();
    bool osdTitleLogo() const;
    bool steadyFrames() const { return m_steadyFrames; }
    bool devMeter() const { return qEnvironmentVariableIntValue("CODEC_FPS") > 0; }
    QString frameRateMode() const;
    bool frameRatePending() const
    { return !m_frameRateLive.isEmpty() && m_frameRateLive != frameRateMode(); }
    Q_INVOKABLE void toggleFrameRate();
    void noteRenderLoop(const QString &loop);   // main.cpp: what Qt is running
    bool localCaptionBg() const;
    bool subHonourStyle() const;
    QString subTimingStatus() const { return m_subTimingStatus; }
    void applyLocalCaptions();              // push font/colour/size to the engine
    QString audioLanguageLabel() const;   // "ENGLISH" / "JAPANESE" / ...
    Q_INVOKABLE void cycleAudioLanguage(int dir = 1);
    bool autoplayNext() const;            // episode auto-chain on/off
    Q_INVOKABLE void toggleAutoplay();
    QString hdrPeakLabel() const;         // "AUTO (620 NITS)" / "600 NITS"
    Q_INVOKABLE void cycleHdrPeak(int dir = 1);      // auto -> 400 -> 600 -> 1000
    // Cycle helpers mirroring the local player's s / a / z keys.
    Q_INVOKABLE void castCycleSub();
    Q_INVOKABLE void castToggleSub();   // remote CC key: English on/off (not a full cycle)
    Q_INVOKABLE void castCycleAudio();
    Q_INVOKABLE void castCycleScreenMode();
    Q_INVOKABLE void castStepRate(int dir); // presets 0.75…2.0; 0 resets
    Q_INVOKABLE void leavePlayer();    // browse while video keeps playing (PiP)
    Q_INVOKABLE void stopPlayback();
    Q_INVOKABLE void backToChooser();
    Q_INVOKABLE void quit();
    // Hand the display back out of HDR if we put it there — called from
    // aboutToQuit so EVERY exit path restores it (window-close, SIGTERM/pkill,
    // Ctrl+C), not just the in-app mod+Q quit(). Idempotent (guards m_monitorHdrOn).
    void ensureHdrRestored();
    Q_INVOKABLE QString prettyTime(double seconds) const;
    // Async ffprobe of a local file for the detail page: video resolution +
    // codec, audio tracks (channels -> 7.1/5.1/STEREO, codec, language) and
    // subtitle tracks (language, codec). Emits mediaProbed when done; no-op
    // for non-local paths.
    Q_INVOKABLE void probeMedia(const QString &path);

    // Autoplay chain (Netflix-style)
    Q_INVOKABLE void autoplayGo();
    Q_INVOKABLE void autoplayCancel();
    // UP NEXT at the end credits (codec_credits.py): accept = advance now, the
    // same path end-of-file takes; dismiss = keep watching the credits.
    Q_INVOKABLE void creditsGo();
    Q_INVOKABLE void creditsDismiss();
    Q_INVOKABLE void setAudioDevice(const QString &name);

    // Media roots (config.json "roots") — editable from Settings so any
    // machine can carry local media and cast it wherever it goes.
    Q_INVOKABLE QVariantList mediaRoots() const;
    // kind: movies | tv — Kodi's "this folder contains", asked as a path is added
    Q_INVOKABLE void addMediaRoot(const QString &path, const QString &kind = QStringLiteral("movies"));
    Q_INVOKABLE void removeMediaRoot(int index);
    Q_INVOKABLE void toggleMediaRootKind(int index);
    // The folder browser (CHOOSE MEDIA PATHS, Settings ▸ LIBRARY ▸ ADD): where
    // to start (home, Videos, every mounted drive), a folder's subfolders, and a
    // bounded count of what's in one — all off the GUI thread.
    // browseFolder("") lists the places; both answers come back on folderListed
    // (a dead network mount can hang a listing — never on the GUI thread).
    Q_INVOKABLE void browseFolder(const QString &path);
    Q_INVOKABLE QString parentFolder(const QString &path) const;
    Q_INVOKABLE QString prettyPath(const QString &path) const;   // ~/… for the home dir
    Q_INVOKABLE void probeFolder(const QString &path);
    // Settings ▸ LIBRARY ▸ METADATA: does codec carry its own TMDB / fanart.tv
    // keys (scripts/codec_keys.py)? {codecTmdb, codecFanart} — a person's own
    // keys are plain settings (tmdbApiKey, fanartPersonalKey).
    Q_INVOKABLE QVariantMap artKeys() const;
    // First run: a machine with no media paths (and no hub to browse) is asked
    // for them after the display — CHOOSE MEDIA PATHS. Done (or skipped) once.
    Q_INVOKABLE void finishMediaPaths();
    QVariantMap pairRequest() const { return m_pairRequest; }
    QVariantList pairedDevices() const { return m_pairedDevices; }
    bool lanOpen() const;
    Q_INVOKABLE void answerPair(bool allow);
    Q_INVOKABLE void refreshPaired();
    Q_INVOKABLE void removePaired(const QString &id);
    Q_INVOKABLE void toggleLanOpen();
    QString sharing() const { return m_sharing; }
    Q_INVOKABLE void refreshSharing();
    Q_INVOKABLE void toggleSharing();
    // A satellite-to-be: hubs heard on this network (→ hubsFound), and asking
    // one to join (→ joinProgress: asking, waiting, allowed, denied, expired,
    // error, pulling, restarting). Allowed, this machine becomes the hub's
    // satellite and codec starts again browsing its library.
    Q_INVOKABLE QString machineName() const { return QSysInfo::machineHostName(); }
    Q_INVOKABLE void findHubs();
    Q_INVOKABLE void joinHub(const QString &url);

    // Pixel Forge — the in-app sprite editor. qrc is read-only, so hand-drawn
    // sprites are written as PNGs to a real filesystem dir, listed back for the
    // Asset Bay, and read in as a flat ARGB grid for re-editing.
    // live OS keyboard-modifier state (Ctrl/Shift/Alt) — queried directly, not
    // via events, so scan manual-aim/zoom work even if the compositor drops the
    // modifier out of pointer/key events
    Q_INVOKABLE int queryKbdModifiers() const;
    Q_INVOKABLE QString spritesDir() const;
    // Dev hot-reload for the hand-drawn hero art: if <base>.png exists in
    // heroDevDir(), the nameplate/bezel loads it live from disk (file:// +
    // ?v=heroDevRev cache-bust) instead of the baked qrc — an external editor's
    // save updates codec instantly, no rebuild. heroDevRev bumps on any change.
    Q_INVOKABLE QString heroDevDir() const;
    Q_INVOKABLE QString heroDevPath(const QString &rel) const;
    QString heroDevPathUncached(const QString &rel) const;
    int heroDevRev() const { return m_heroDevRev; }
    Q_INVOKABLE bool saveSprite(const QString &name, int w, int h, const QVariantList &argb);
    Q_INVOKABLE QVariantList userSprites() const;
    Q_INVOKABLE QVariantMap loadSprite(const QString &path) const;
    // Import: browse & pull in raw external asset PNGs (bought/found 8-bit art)
    // — list the pack tree, and crop ONE frame from a strip into an editable grid.
    Q_INVOKABLE QString importDir() const;
    Q_INVOKABLE QVariantList importAssets() const;
    Q_INVOKABLE QVariantMap loadSpriteFrame(const QString &path, int frames, int index) const;
    // Asset Viewer — Aseprite is the authoring tool; codec curates + integrates.
    // openInAseprite launches the external editor on a filesystem path (detached,
    // fire-and-forget). asepriteAvailable gates the "open" affordance so the
    // viewer degrades gracefully when the editor isn't installed. forkToLibrary
    // copies any asset (a file:// path, or a qrc:/ baked asset) into the editable
    // user-sprites dir so it can then be edited + hot-reloaded.
    Q_INVOKABLE bool asepriteAvailable() const;
    Q_INVOKABLE bool openInAseprite(const QString &path) const;
    Q_INVOKABLE QString forkToLibrary(const QString &path, const QString &nameHint = QString());
    QString hubStatus() const { return m_hubStatus; }
    Q_INVOKABLE void checkHub(); // async; syncs library + updates hubStatus
    // Library update controls (Settings + global F5 + Home affordance).
    bool libraryUpdating() const { return m_libraryUpdating; }
    bool libraryAuditing() const { return m_libraryAuditing; }
    QString libraryAuditResult() const { return m_libraryAuditResult; }
    int libraryNewCount() const { return m_enrichCount; }
    QString autoUpdate() const; // "off" | "launch" | "live", default "live"
    Q_INVOKABLE void cycleAutoUpdate(int dir = 1); // off -> launch -> live
    // Manual "UPDATE LIBRARY": retry every out-of-step item (clears the
    // attempted-guard so a slow/failed scrape isn't stuck out), rescan, enrich.
    // Always confirms with a toast so the button never feels dead.
    Q_INVOKABLE void updateLibrary();
    // New titles on disk (the torrent importer, over D-Bus, after it places
    // one): scan now, whatever AUTO-UPDATE says about watching folders.
    void newFilesArrived();
    Q_INVOKABLE void pullLibrary(); // satellite: fetch hub manifest + art
    // Watch party. start mints a hub-owned session from what's playing here and
    // joins it, so this screen and a TV three provinces away are equal
    // followers of one clock; join attaches to a session somebody else started;
    // end tears it down for everyone. The `w` overlay is the whole UI.
    bool partyOpen() const { return m_partyOpen; }
    void setPartyOpen(bool on);
    bool partyLive() const { return m_partyLive; }
    bool partyHosting() const { return m_partyHosting; }
    bool partyFollowing() const { return m_partyFollowing; }
    // "Am I in this session at all" — what the old partyActive meant, kept
    // because the overlay and the help screen ask exactly that question.
    bool partyActive() const {
        return m_partyHosting || m_partyFollowing || m_partyViaCast; }
    bool partyHubMode() const { return m_partyMode == QLatin1String("hub"); }
    // Transport keys drive the whole party (rather than only this screen) when
    // we're in a hub-owned session — the host is a viewer like everyone else.
    bool partyDriving() const {
        return (m_partyFollowing || m_partyViaCast) && partyHubMode(); }
    QString partyTitle() const { return m_partyTitle; }
    bool partyLoading() const { return m_partyLoading; }
    QString partyNext() const { return m_partyNext; }
    bool partyPaused() const { return m_partyPaused; }
    double partyPos() const;
    double partyDur() const { return m_partyDur; }
    bool partyHaveFile() const { return !partyLocalFile().isEmpty(); }
    QStringList partyWho() const { return m_partyWho; }
    QVariantList partyRoom() const { return m_partyRoom; }
    QVariantList partyAsks() const { return m_partyAsks; }
    QVariantList partyChat() const { return m_partyChat; }
    int partyVotes() const { return m_partyVotes; }
    int partyVotesNeed() const { return m_partyVotesNeed; }
    bool partyLocked() const { return m_partyLocked; }
    int partyRoomLagMs() const { return m_partyRoomLagMs; }
    QString partyLagWho() const { return m_partyLagWho; }
    QStringList partyWaitingFor() const { return m_partyWaitingFor; }
    QString partyInviteUrl() const { return m_partyInviteUrl; }
    QString partyReceiverUrl() const { return m_partyReceiverUrl; }
    int partyPeers() const { return m_partyPeers; }
    Q_INVOKABLE void partySay(const QString &text);
    Q_INVOKABLE void partyReact(const QString &key);
    Q_INVOKABLE void partyVoteRewind();
    Q_INVOKABLE void startWatchParty();
    Q_INVOKABLE void stopWatchParty();   // leave; ends it if we were the host
    Q_INVOKABLE void joinWatchParty();   // play along with the live session
    Q_INVOKABLE void leaveWatchParty();  // stop following, keep watching alone
    void leaveWatchPartyAs(const QString &why);   // ...with its own toast ("" = none)
    Q_INVOKABLE void endWatchParty();    // end the session for everyone
    Q_INVOKABLE void partyDrop(const QString &id);   // take a screen out of the room
    Q_INVOKABLE void partyUndrop(const QString &id); // let a removed screen back in
    Q_INVOKABLE void partyLock(bool on);             // let nobody new in
    // Take over what another screen has open, at the moment it reached. The
    // other screen stops — this is a handoff, not a second viewer.
    Q_INVOKABLE void resumeHere();

    bool nowElsewhere() const { return m_nowElsewhere; }
    QString nowWhere() const { return m_nowName; }
    QString nowTitle() const { return m_nowTitle; }
    double nowPos() const { return m_nowPos; }
    double nowDur() const { return m_nowDur; }
    bool nowPaused() const { return m_nowPaused; }
    bool nowIsYoutube() const { return !m_nowVid.isEmpty(); }
    QString playingLogo() const { return m_playingLogo; }
    QString playingLogoLine() const { return m_playingLogoLine; }
    // Transport that knows whether it is driving a party or just this screen.
    // PlayerView calls these instead of the engine directly.
    Q_INVOKABLE void playPause();
    Q_INVOKABLE void seekBy(double seconds);
    Q_INVOKABLE void seekTo(double seconds);
    Q_INVOKABLE void seekPct(double pct);   // scrub bar: drives the room in a hub party
    double subtitleScale() const;
    Q_INVOKABLE void cycleSubtitleSize(int dir = 1);
    bool nightMode() const;
    Q_INVOKABLE void toggleNightMode();

    // Mech palette (fixed colours, pywal off) — a persisted setting that drives
    // the Theme. setTheme() hands the controller the Theme so the toggle can flip
    // it live and the saved value is applied at launch.
    bool mechPalette() const;
    Q_INVOKABLE void toggleMechPalette();
    bool editorEnabled() const;
    Q_INVOKABLE void toggleEditorEnabled();
    void setTheme(Theme *theme);
    // Cross-device queue: the hub keeps a shared inbox any device can fill
    // and any device drains ("queue it downstairs, play it upstairs").
    Q_INVOKABLE void sendToHubQueue(const QVariantMap &item);
    Q_INVOKABLE void sendQueueToHub(); // whole live queue -> hub, then clear
    Q_INVOKABLE void pullHubQueue();
    // QML-side toast trigger (signals can't be emitted from QML).
    Q_INVOKABLE void notify(const QString &text) { emit toast(text); }
    // A keycap hint, clicked: press the key it shows ("d", "S", "⏎", "esc" …)
    // on the focused view, exactly as the keyboard would. keyCapKey() says
    // whether a cap names one pressable key ("J/K" doesn't) — 0 if not.
    Q_INVOKABLE int keyCapKey(const QString &cap) const;
    Q_INVOKABLE void pressKeyCap(const QString &cap);
    // Context-menu helpers.
    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE void setWatched(const QString &uri, bool watched);
    Q_INVOKABLE void setWatchedMany(const QStringList &uris, bool watched);
    // Permanently delete a local media file from disk (context-menu action,
    // confirmed in QML first). Removes the file — and its release folder if
    // that leaves only junk behind — then reconciles the library so it drops
    // out of the app immediately and off the laptop manifest. Local files
    // only; never touches http/yt sources or a cast target.
    Q_INVOKABLE void deleteMedia(const QString &path);

signals:
    // openSection("settings:<section>") while Settings is already on screen
    void settingsJumpRequested();
    void deviceRoleChanged();
    void remoteMapChanged();
    void sleepChanged();
    void partyNameChanged();
    void hubLinkChanged();
    // Remote → views (each view answers for its own selection while it is up)
    void queueAddRequested();                   // REC / return: add the selection to the queue
    void trailerRequested();                    // TRAILER spare: trailer of the selection
    void youtubeSearchRequested();              // SEARCH while in YouTube: its own search box
    void remoteQueueAction(const QString &action); // queue open: up / down / remove / clear
    void liveStateChanged();
    void garageEditingChanged();
    void detailBonusChanged();
    // Forward re-entering a bonus page Back closed: the detail page opens it.
    void detailBonusRequested(const QString &uri);
    void tiltStep(int dir); // horizontal tilt-wheel click: -1 left, +1 right
    void queuePushed(); // shared-queue POST landed (quit() flush waits on it)
    void userSpritesChanged(); // a hand-drawn sprite was saved/removed
    void heroDevRevChanged();  // a dev-override hero PNG changed on disk
    void mediaProbed(const QString &path, const QVariantMap &info);
    void stageChanged();
    void monitorsChanged();
    void modeChanged();
    void queueOpenChanged();
    void playerPromptChanged();
    void outputOpenChanged();
    void remoteOpenChanged();
    void castChaptersChanged();
    void searchOpenChanged();
    void detailUriChanged();
    void mediaRootsChanged();
    void pairRequestChanged();
    void pairedDevicesChanged();
    void lanOpenChanged();
    void sharingChanged();
    void hubsFound(const QVariantList &hubs);
    void joinProgress(const QString &state, const QString &hub, const QString &why);
    // probeFolder's answer: video files found, how many read as episodes
    // (S01E02 / 1x02), season folders, and whether the walk hit its bound
    // browseFolder's answer: [{label, path, sub}] — places for "", else subfolders
    void folderListed(const QString &path, const QVariantList &folders);
    void folderProbed(const QString &path, int videos, int episodes, int seasons, bool capped);
    void hubStatusChanged();
    void libraryUpdatingChanged();
    void libraryAuditChanged();
    void autoUpdateChanged();
    void partyOpenChanged();
    void partyChanged();
    void nowChanged();
    void playingLogoChanged();
    void osdTitleLogoChanged();
    void steadyFramesChanged();
    void frameRateChanged();
    void partyChatChanged();
    // One signal per ARRIVING line, so a view can toast it without diffing the
    // whole list against what it had a moment ago.
    void partyChatLine(const QString &who, const QString &text, const QString &kind);
    void subtitleScaleChanged();
    void nightModeChanged();
    void mechPaletteChanged();
    void editorEnabledChanged();
    void hdrDirectChanged();
    void hdrEngagedChanged();
    void introRangeChanged();
    void attractChanged();
    void attractMinutesChanged();
    void spotlightSecondsChanged();
    void redactionStyleChanged();
    void glassLevelChanged();
    void pipCornerChanged();
    void pointerActiveChanged();
    void liveNowChanged();
    void seekStepChanged();
    void castCaptionsChanged();
    void localCaptionsChanged();
    void subTimingStatusChanged();
    void audioLanguageChanged();
    void autoplayNextChanged();
    void hdrPeakChanged();
    void toast(const QString &text);
    void grabFrame(const QString &path); // QML grabs the video item to this path
    // 5s countdown to `title`; QML drives the timer then calls autoplayGo().
    void autoplayCountdown(const QString &title);
    // Chain limit reached: ask before continuing (enter=autoplayGo, esc=cancel).
    void autoplayAsk(const QString &title);
    // the credits began and something is next; `ask` = the 3-in-a-row "still watching?"
    void creditsUpNext(const QString &title, bool ask);

private:
    void refreshMonitors();
    QVariantList monitorsFromQt() const; // synchronous, instant chooser data
    QString modeForDisplay(const QString &name) const;
    void switchDisplay(const QString &name); // mode + zoom + HDR + placement, no stage change
    void reconcileScreens();                 // a screen came or went: follow it
    // The zoom a film opens with in a viewing mode: its own last choice if it
    // was made in THAT mode, else the mode's default (CRT: ZOOM, HD: FIT).
    int zoomFor(const QString &identity, const QString &mode) const;
    void applyPlacement();
    void setStage(const QString &stage);
    // Where hub calls go: the hub's LAN address, or its Tailscale address when
    // only that answers (hubLink). Cached members — it used to read config.json
    // from disk on every call, 36 sites, some per second.
    QString hubBase() const;
    void loadHubConfig();                   // syncUrl / hubTailnet / hubFunnel / hubDirect → members
    void probeHubLink(bool sync);           // LAN + tailnet reachability → applyHubLink
    void probePublicRoad();                 // no private road: does the public door answer our token?
    void applyHubLink(bool lan, bool tnet, int pub = 0); // the link word, its toast, the cached flags
    // The browse token this machine holds (the road to the hub's public door),
    // kept in ~/.cache/codec/hub-token.json with the cast worker: minted (or
    // kept alive) whenever a private road is up, used when none is.
    void loadHubToken();
    void mintHubToken();
    void saveHubTokenFile();                // token + expiry + the doors, merged, 0600
    bool publicRoad() const { return m_hubLink == QLatin1String("fastroad") || m_hubLink == QLatin1String("funnel"); }
    QString publicBase() const;             // the fast road when it answered, else the Funnel
    QString publicUrlFor(const QString &hubUrl, const QString &leaf, const QString &extra = QString()) const;
    QString osdTitleFor(const QString &path) const;   // library name + year for the OSD
    // A satellite's hub URLs point at the hub LAN IP, dead when roaming — swap
    // the host for the hub's Tailscale address (config `hubTailnet`) when the
    // LAN isn't reachable, so mpv streams the file over the tailnet instead.
    // Only the hub's OWN urls: YouTube and any other public host pass through.
    QString reachableHub(const QString &uri) const;
    // The canonical identity of what the engine plays — play()'s `path` while
    // the warm-HLS fallback lane (a `/hls/pl.m3u8?src=…` url) stands in for it,
    // so resume, completion and credits key on the title, not the lane.
    QString playbackIdentity(const QString &enginePath) const;
    bool castingNow() const;                 // a cast session with a film on it
    bool privateRoad() const { return m_hubLink == QLatin1String("hub") || m_hubLink == QLatin1String("lan") || m_hubLink == QLatin1String("tailnet"); }
    void findSubtitlesFor(const QString &path, bool casting, bool force);
    void pollSubSync();
    void onSubDelayChanged();
    // Roaming far-resume hybrid: build the seekable warm-HLS lane URL for a hub
    // title (mpv opens an adaptive HLS master that begins at the resume point),
    // and switch to it if the raw remux hasn't started playing in time.
    QString warmHlsUrl(const QString &httpUrl, double startSec, double durSec) const;
    void tryHlsResumeFallback();
    void castQueuePush();
    void castQueuePoll();
    void rcPoll();   // drain the hub /rc queue → physical-TV-remote actions (Phase 2)
    void saveNow();
    void enterAfterChooser();
    bool needsMediaPaths() const;
    // Fire-and-forget: vault note for what just started playing.
    void vaultNoteKick(const QString &path);
    // Fire-and-forget: register a YouTube watch on the account so it shows in
    // youtube.com history and resumes on other devices. Runs the worker's
    // --watch op detached; no-op for non-YouTube uris. Called at play start
    // (history) and at stop/leave/switch (resume position).
    void ytHistoryPing(const QString &uri, double pos);
    // Keeps the YouTube resume position fresh while a video plays — a real
    // client pings watchtime continuously, and a single start/stop ping often
    // isn't enough for the position to actually stick on the phone.
    QTimer m_ytPingTimer;
    // A scan found the metadata out of step with disk (new files to scrape,
    // deleted files to prune) → run codec_reconcile.sh and re-scan when it
    // lands. Only acts on paths not already attempted, so a title TMDB can't
    // match — or an orphan a failed prune left behind — never re-loops.
    void reconcileLibrary();
    class QProcess *m_artFetch = nullptr;
    QSet<QString> m_reconcileAttempted;

    // Keep the screen awake while video is actually playing (D-Bus screensaver
    // inhibitor, honored by hypridle); release when paused/idle/stopped.
    void updateIdleInhibit();
    void updateSfxQuiet();     // UI sounds quiet while a film plays locally
    void loadOcrSubtitle(int subIndex); // sideload the hub's OCR'd text sub for a bitmap track
    void loadOcrSubtitleTry(int subIndex, int attempt);
    void setInhibited(bool on);
    void acquireScreensaverInhibit();
    // Cursor auto-hides after 1s of no movement anywhere in the app.
    void showCursor();
    void hideCursor();

    // True for transient uris (trailer searches) that must not leave
    // resume/watched rows behind.
    static bool ephemeralUri(const QString &uri);
    // Credits-skippers stop before the file ends: >=90% watched counts as
    // completed. Checked whenever viewing of the current file ends early
    // (stop, quit, switching to another file).
    void maybeMarkWatched();
    // One advance path for local + cast: what plays after `finished`.
    void advanceAfter(const QString &finished);
    // Send a MediaItem-shaped map to the cast target (resume-aware).
    void castPlay(QVariantMap item);

    PlaybackEngine *m_engine;
    ResumeStore *m_store;
    Library *m_library;
    QueueModel *m_queue;
    CastManager *m_cast;
    YouTubeSource *m_youtube = nullptr;
    QString m_settingsJump;   // openSection("settings:youtube") → the view opens there
    UiSound *m_sfx = nullptr;
    int m_tiltAcc = 0;
    // Mouse back/forward (any mouse: thumb buttons and BTN_BACK/BTN_FORWARD).
    bool m_garageEditing = false;   // the garage editor uses them for its own paging
    bool m_detailBonus = false;
    // Browser-style history for Forward: each Back (mouse or remote) pushes what
    // it closed — a stage, a detail page, a bonus page — with where it LANDED.
    // Forward pops one only while you still stand exactly there.
    struct FwdStep {
        QString kind;                 // "stage" | "detail" | "bonus"
        QString target, section;      // stage (+ library section) or detail uri
        QString landStage, landDetail;
        bool landBonus = false;
    };
    QList<FwdStep> m_fwd;
    bool m_inMouseNav = false;      // setStage() keeps m_fwd only during Back/Forward
    void mouseBack();
    void remoteOk();
    void remoteWatchParty();
    void remoteSpare(int n, bool isPress, bool repeat);
    QString spareAction(int n) const;
    QString colorAction(int n) const;
    void remoteKeyAction(const QString &action, const QString &name, bool isPress, bool repeat);
    void mouseForward();
    Theme *m_theme = nullptr;
    QQuickWindow *m_window = nullptr;
    // FreeSync without the flicker (see updateSteadyFrames)
    bool m_vrrActive = false;      // adaptive sync running on our display now
    bool m_steadyFrames = false;   // presenting every refresh
    bool m_vrrProbing = false;
    QString m_frameRateLive;       // the FRAME RATE mode this run started with
    QTimer *m_vrrPoll = nullptr;
    void pollVrr();
    void updateSteadyFrames();

    QString m_stage = QStringLiteral("chooser");
    // Where esc/stop returns to after playback: the view playback started from.
    QString m_browseStage = QStringLiteral("library");
    QVariantList m_monitors;
    QString m_display;
    // The screen codec belongs on but can't be on right now (it went dark
    // under us — the Pause lock sleeps the tube — or MoveTo named one still
    // waking). Back there the moment it returns; any deliberate choice clears it.
    QString m_wantDisplay;
    int m_wantGen = 0;     // a MoveTo's wait expires; a newer want outlives it
    QTimer m_screenSettle; // lets Hyprland finish a hotplug before we act on it
    QString m_mode = QStringLiteral("hd");
    QString m_pendingPath;
    QStringList m_pendingEnqueue; // files to add to the queue once the library is up
    QTimer m_saveTimer;
    QElapsedTimer m_watchTick;   // real elapsed between watch-time credits
    class QNetworkAccessManager *m_nam = nullptr;
    QTimer m_castqPushTimer;
    QTimer m_castqPollTimer;
    QTimer m_rcPollTimer;   // Phase 2: physical-TV-remote /rc drain while casting
    QTimer m_pairTimer;     // a hub asks its own server for join requests
    QVariantMap m_pairRequest;
    QVariantList m_pairedDevices;
    QString m_sharing = QStringLiteral("unknown");
    void setSharing(const QString &s);
    void loadHubKey();
    void becomeSatellite(const QString &base, const QString &hub);
    void restartSelf();
    void pairPoll();
    // In-app HDR (0.9.3): when an HDR file plays fullscreen on an HDR panel,
    // the window recreates PQ-tagged (wp_color_management_v1 via Qt), mpv
    // targets PQ/BT.2020, and the monitor flips to 10-bit HDR scanout.
    void setMonitorHdr(bool on, bool blocking = false);
    bool m_monitorHdrOn = false;
    // Generation counter: engage/disengage async chains can overlap when the
    // player is entered and left quickly — a stale chain landing last used to
    // stick the panel in HDR while browsing. Only the newest request applies.
    int m_monitorHdrSeq = 0;
    int m_edidPeakNits = 0; // panel's advertised max luminance (0 = unknown)
    bool hdrWanted() const;       // current engage conditions
    void updateHdrEngaged();      // debounce toward hdrWanted()
    void setHdrEngaged(bool on);  // apply: mpv targets + window + monitor
    QTimer m_hdrDebounce;         // coalesces loadfile-churn flapping
    void recreateWindow(bool pq); // swap the surface colorspace in place
    void probeDisplayHdr();       // EDID: does m_display accept ST2084?
    bool m_hdrEngaged = false;
    QVariantMap m_introRange;
    // Idle -> attract. Armed only on browse screens with nothing playing;
    // any input at all disarms it (see eventFilter).
    QTimer m_attractTimer;
    bool m_attract = false;
    void armAttract();
    void setAttract(bool on);
    bool m_displayHdrCapable = false;
    QSurfaceFormat m_baseFormat;
    int m_castqRev = 0;
    qint64 m_castqLastEdit = 0;
    bool m_adoptingQueue = false; // hub adoptions must not re-push (ping-pong)
    // Adopted queue items carry the queuing device's uri form — rewrite to
    // what THIS device can play (hub: local file; satellite: hub stream URL).
    QVariantMap localizedQueueItem(QVariantMap it) const;
    // Build a MediaItem-shaped queue entry from a raw filesystem path, enriched
    // from the library when the file is known (title/art/kind), else filename.
    QVariantMap queueItemForPath(const QString &path) const;
    QTimer m_libPullTimer;
    bool m_libPullInFlight = false; // one hub-pull QProcess at a time
    // Post-chooser: hop to the chosen monitor's "Media" workspace.
    void moveToMediaWorkspace();

    QString m_autoplayNext;
    int m_autoplayChain = 0;
    bool m_queueOpen = false;
    bool m_playerPrompt = false;
    bool m_outputOpen = false;
    bool m_remoteOpen = false;
    QVariantList m_castChapters;
    QString m_chapterUri;      // what m_castChapters describes
    void fetchCastChapters(const QString &uri);
    bool m_searchOpen = false;
    QString m_detailUri;
    bool m_pipLeft = false;
    bool m_pipTop = false;

    bool m_inhibited = false;
    uint m_inhibitCookie = 0;   // org.freedesktop.ScreenSaver cookie (screen blank)
    int m_sleepInhibitFd = -1;  // logind sleep-inhibitor fd (system suspend)
    QTimer m_cursorTimer;
    bool m_cursorHidden = false;
    QPoint m_lastCursorPos{-1, -1}; // real-movement gate for cursor un-hide
    qint64 m_pointerHushUntil = 0;  // frontWindow's own warp + nudge: not a person moving
    bool m_pointerActive = false;

    // OFA remote (BLE) → codec actions, incl. tap-vs-hold on Back/Home/Guide.
    bool handleRemoteKey(QKeyEvent *ke); // true = consumed
    void remoteHoldFired();              // hold timer expired while still held
    void remoteCastToggle();            // CAST tap: fling the current title to/from the TV
    void sleepDisplays();               // SLEEP fire: blank displays (override script or dpms)
    void sendKey(int key);              // synth press+release to the focused item
    QTimer m_remoteHoldTimer;
    int m_remoteHoldAction = 0;         // which hold-capable button is down (0 = none)
    bool m_remoteHeldDone = false;      // its hold action already fired this press
    QTimer m_sleepTimer;                // SLEEP countdown-to-fire (single-shot)
    QTimer m_sleepCountTimer;           // the 3·2·1 stop countdown once it fires
    int m_sleepIdx = 0;                 // 0 = off, 1 = 30 min, 2 = 60 min
    int m_sleepCountdown = 0;           // seconds left in the 3·2·1
    void setPointerActive(bool on);
    bool m_liveNow = false;
    // End-credits UP NEXT: where this file's credits start (0 = unknown), whether
    // it has fired this load, the file it fired for, and a one-shot that lets an
    // accepted credits prompt advance without a second countdown.
    void checkCredits();
    QString peekNextTitle(const QString &path) const;   // queue head, else next episode
    // The CAST leg of the same: credits reached on the TV → "UP NEXT" held on the
    // receiver for a 10 s countdown; remote OK = now, Back = watch the credits.
    void checkCastCredits();
    void castCreditsGo();
    void castCreditsCancel(bool flash = true);
    QString m_castCreditsUri;           // cast title banked as watched at its credits
    bool m_castCreditsPending = false;  // UP NEXT countdown running on the TV
    QTimer m_castCreditsTimer;
    double m_creditsStart = 0;
    bool m_creditsFired = false;
    QString m_creditsPath;
    bool m_skipCountdownOnce = false;
    QString m_liveUri; // uri playItem/advance flagged as a live stream
    QString m_liveTitle;            // the item's real title (mpv would show the lane URL)
    QString m_liveVariant;          // YouTube's own HLS variant playlist for the DVR
    qint64 m_liveStartTs = 0;       // broadcast start (epoch s, yt-dlp release_timestamp)
    bool m_liveDvr = false;         // playing the seekable snapshot, not the live lane
    double m_dvrWindow = 0;         // window length at m_dvrWindowAtMs
    qint64 m_dvrWindowAtMs = 0;
    double m_dvrSnapDur = 0;        // the loaded snapshot's length…
    qint64 m_dvrSnapAtMs = 0;       // …and when it was taken
    int m_dvrSnapSeq = 0;
    qint64 m_liveWatchedMs = 0;
    QElapsedTimer m_liveWatchClock;
    QTimer m_liveTick;
    class QProcess *m_liveResolve = nullptr;
    void liveBegin();
    void liveReset();
    void liveEnterDvr(double behind);
    void liveFetchWindow(std::function<void(const QByteArray &)> done);
    // Stamp m_liveUri from any MediaItem-shaped map about to play.
    void rememberLive(const QVariantMap &item);

    void loadSettings();
    void saveSetting(const QString &key, const QVariant &value);
    // Write a key into a top-level section object (e.g. audio.language) rather
    // than the "settings" block saveSetting targets — same read-modify-write
    // under the config lock, preserving every other key on disk.
    void saveSectionSetting(const QString &section, const QString &key,
                            const QVariant &value);
    void saveMediaRoots(const QVariantList &roots);
    // Write config.json atomically (temp + fsync + rename) so a crash mid-write
    // can't truncate it — a truncated config parses to {} and silently resets
    // the entire mech skin, dials, and API keys to defaults.
    bool writeConfigAtomic(const QJsonObject &root);
    QString m_hubStatus = QStringLiteral("unchecked");
    // Library-update state. m_manualUpdate distinguishes a user-pressed UPDATE
    // (always enriches + always confirms) from an automatic scan-driven one
    // (skipped when AUTO-UPDATE is off).
    bool m_libraryUpdating = false;
    bool m_libraryAuditing = false;
    QString m_libraryAuditResult;
    int m_enrichCount = 0;
    bool m_manualUpdate = false;
    void setLibraryUpdating(bool on, int newCount = 0);
    void onLibraryScanned();  // manual-update fallback confirmation
    void applyAutoUpdate();   // push the setting to the live-watch
    QString hubUrl() const;
    void postHubItems(const QVariantList &items, const QString &toastText);
    void syncState();
    // Refresh the home lists only when watch-state actually moved, so an idle
    // machine's spotlight doesn't rebuild every tick. Cheap fingerprint diff.
    void maybeNotifyResume();
    QTimer m_syncTimer;              // pull/push watch-state while running
    QFileSystemWatcher m_spritesWatcher;  // user-sprite dir → hot-reload on external edit
    QTimer m_spritesReloadTimer;          // debounce the watcher's write bursts
    QFileSystemWatcher m_heroDevWatcher;  // dev/ dir → live hero-art override on external edit
    QTimer m_heroDevReloadTimer;          // debounce the dev watcher's write bursts
    QTimer m_heroDevPollTimer;            // mtime poll — fires when an editor writes IN PLACE
                                          // (dir-watch misses content-only writes); the reliable path
    qint64 m_heroDevMaxMtime = 0;         // newest png mtime seen (ms) — bump rev when it grows
    int m_heroDevRev = 0;                 // bumps on any dev-override change (QML cache-bust key)
    // basename → full dev path, rebuilt whenever m_heroDevRev moves. Lets a dev-tree PNG
    // live-edit from ANY subfolder by filename, so the art can be organised into group
    // folders without touching the flat qrc/qml paths. -1 = not yet built.
    mutable QHash<QString, QString> m_devFileIndex;
    mutable int m_devFileIndexRev = -1;
    // heroDevPath() answers, memoised per asset id for the same m_heroDevRev — every mech
    // plate asks on creation, and the uncached walk (regex + 2 stats + mkpath) was a hitch.
    mutable QHash<QString, QString> m_devPathCache;
    mutable int m_devPathCacheRev = -1;
    // Cached reachability of the hub's LAN address (roaming switch for
    // reachableHub) — probing on every play/poll would stall the UI.
    mutable qint64 m_hubProbeAt = 0;
    mutable bool m_hubLanOk = false;
    mutable bool m_hubTnetOk = true;   // default true: no probe yet -> don't block
    mutable bool m_hubProbing = false; // an async reachability probe is in flight
    // The hub's roads, read from config.json ONCE (loadHubConfig), and the link
    // the last probe found (hubLink). m_linkTimer re-probes every 30 s.
    QString m_cfgSyncUrl, m_cfgTailnet, m_cfgFunnel, m_cfgDirect;
    QString m_hubLink;
    QTimer m_linkTimer;
    QString m_hubToken;
    double m_hubTokenExp = 0;       // epoch seconds
    qint64 m_hubTokenMintAt = 0;    // ms; a mint at most hourly
    bool m_publicDirectOk = false;  // the fast road answered (else the Funnel)
    QString m_completedPath;           // path just markCompleted; skip one saveNow
    // Roaming far-resume hybrid (see warmHlsUrl/tryHlsResumeFallback): armed on
    // a roaming resume; if the raw remux hasn't started PLAYING (position past
    // the resume point) in 15s, fall back once to the pre-built warm-HLS lane,
    // replaying the same track/zoom choices. m_fallbackIdentity keeps the
    // title's own url so the lane's progress is saved under it.
    QTimer m_resumeWatchdog;
    QString m_hlsFallbackUrl;
    // What the engine is playing vs what it IS: play()'s canonical `path`
    // (the resume key, the manifest match) and the url mpv actually opened —
    // the tailnet rewrite, the public door's /raw, or the warm lane. Every
    // row-keeping site maps through playbackIdentity().
    QString m_playIdentity;
    QString m_playingLogo, m_playingLogoLine;   // the OSD's title art (see playingLogo)
    void updatePlayingLogo();
    QString m_playUrl;
    // Mid-film starvation on a remote raw file (tailnet or the public door):
    // 20 s waiting on mpv's cache hands playback to the adaptive lane at the
    // spot (the resume watchdog only covers a cold start).
    QTimer m_stallTimer;
    // subtitles: the fetch in flight, the "press again = refetch" arm, the
    // re-timing poll after a fetch, the per-film delay save
    bool m_subFindBusy = false;
    QString m_subFindArmPath;
    qint64 m_subFindArmAt = 0;
    QTimer m_subSyncTimer;
    QString m_subSyncPath;
    bool m_subSyncCast = false;
    int m_subSyncPolls = 0;
    QTimer m_subDelaySave;
    double m_subDelayQuiet = -999.0;        // a restored delay: no toast for it
    QString m_subTimingStatus;
    bool m_fallbackViaRoad = false;   // the lane is the token surface's ladder
    double m_hlsFallbackStart = 0;
    int m_hlsFallbackAid = -1, m_hlsFallbackSid = -1, m_hlsFallbackZoom = -1;
    double m_hlsFallbackSpeed = 1.0;
    bool m_resumeFellBack = false;
    class QProcess *m_syncProc = nullptr;  // one at a time; overlapping runs race the DB
    QString m_lastResumeFp;         // count|max(last_played) at last refresh
    QVariantMap m_settings;
    // Default audio-language pref (ISO code); loaded from top-level audio.language,
    // NOT the "settings" block, so it is tracked on its own.
    QString m_audioLanguage = QStringLiteral("eng");

    // ── watch party (0.9.19) ─────────────────────────────────────────────
    // partyPoll asks the hub what is running — ALWAYS, not only when we
    // started it, because a session belongs to the house. partyFollow slaves
    // local playback to the hub clock (nudging speed, never micro-seeking) and
    // registers us as a viewer. partyPublish is the older app-mode path: this
    // app's own playback IS the clock and gets pushed to /party/update.
    QString m_partyToken, m_partyInviteUrl, m_partyReceiverUrl;
    QString m_partyTitle, m_partyKey, m_partyMode;
    bool m_partyLive = false;       // something is running on the hub
    bool m_partyHosting = false;    // we publish the clock (app mode)
    bool m_partyFollowing = false;  // we play along with a hub-owned clock
    bool m_partyViaStream = false;  // joined by HLS, not our own copy
    bool m_partyViaCast = false;    // host watches on the CAST TV, not locally
                                    // (party-from-cast): our transport drives
                                    // the room, the TV follows the hub clock
    bool m_partyPaused = true;
    double m_partyClockPos = 0;     // clock at m_partyEpochMs, in HUB time
    double m_partyRate = 1.0;
    double m_partyDur = 0;
    bool m_partyLoading = false;
    QString m_partyNext;
    qint64 m_partyEpochMs = 0;
    qint64 m_partySkewMs = 0;       // hub clock minus ours
    quint64 m_partyCmdSeq = 0;      // #24/#29: drop out-of-order partyCmd replies
    qint64 m_partyLastSeek = 0;     // hard-seek cooldown while following
    int m_partyRttMs = -1;          // our round trip to the hub (-1 = unmeasured)
    QStringList m_partyWho;
    QVariantList m_partyRoom;
    QVariantList m_partyAsks;
    qint64 m_partyReloadAt = 0;   // last time the follower reloaded the room's film
    QString m_partyLoadedKey;     // the room film this screen last loaded
    int m_partyLoadSeq = -1;      // the room's film-change hold we're in (-1 = none)
    int m_partyStatusSeq = -1;    // the room seq the last /party/status described
    bool m_partyFileOk = true;    // the film this screen last loaded for the room has OPENED
    int m_partyLoadToast = -1;    // ...and the one we've already said "loading" for
    QVariantList m_partyChat;
    int m_partyChatSeq = 0;
    int m_partyVotes = 0;
    int m_partyVotesNeed = 1;
    bool m_partyLocked = false;
    int m_partyRoomLagMs = -1;      // -1 until the hub tells us
    QString m_partyLagWho;
    QStringList m_partyWaitingFor;
    bool m_partyStartPending = false;  // a scheduled start is already armed
    QString m_partyGuestId;         // presence handle; grants nothing
    QTimer m_partyFollowTimer;
    void partyFollow();             // one sync tick against the hub clock
    void partyApplyStatus(const QJsonObject &o);
    QString partyLocalFile() const;
    QString partyFilmSource(bool *viaStream = nullptr) const;
    bool isPartyStream(const QString &path) const;
    void partyStreamLoaded();
    void partySeekTo(double t); // the session's media on THIS machine
    QString partyMyName() const;
    void partySayImpl(const QString &text, const QString &react);    // who this screen appears as in the room
    void partyCmd(const QString &op, double arg = 0);
    void partyLoadMedia();          // move the whole party to a different film
    void partyAdvanceCast(const QVariantMap &nextItem);  // DV-cast host: advance the room to the next queue item (re-cast TV + op:media)
    bool m_partyOpen = false;
    int m_partyPeers = 0;
    QTimer m_partyPublishTimer;
    QTimer m_partyPollTimer;
    QTimer m_castSeekDebounce;      // #218: coalesce host DV-lane self-seeks under scrub
    double m_pendingSeekPos = -1;   // #218: final target a burst of party seeks lands on
    qint64 m_castPublishHoldUntil = 0;  // seek-fight: pause room-clock pins during a re-warm
    double m_castPublishTarget = -1;    // ...until the cast reaches this seeked target
    QTimer m_castRecoverTimer;      // Batch2 #4: fires after a PERSISTENT wedge to re-cast the lane
    static QString youtubeIdOf(const QString &uri);

    // ── presence: what's open on the other screens ──────────────────────────
    void nowPublish();              // "I have this open, here, at this spot"
    void nowBye();                  // playback ended / quitting
    void nowApply(const QJsonArray &arr);
    void nowSeekWhenLoaded(double pos);
    QTimer m_nowPublishTimer;
    QTimer m_nowSeekTimer;          // waits for the file to open, then seeks
    double m_nowSeekTo = -1;
    int m_nowSeekTries = 0;
    bool m_nowElsewhere = false;
    QString m_nowDevice, m_nowName, m_nowTitle, m_nowKey, m_nowVid;
    double m_nowPos = 0, m_nowDur = 0;
    bool m_nowPaused = false;
    // Every stop we've been handed. Echoed back on the next publish; until it
    // matches, the hub keeps this screen out of everyone's list.
    int m_nowStopAck = 0;
    bool m_nowPublished = false;    // have we ever announced? (bye is pointless otherwise)
    void partyPublish(bool withMedia);
    void partyPublishCast(); // #218: pin the room clock to the DV host's real cast position
    void castSeekDebounced(double pos); // #218: coalesce a scrub-burst into ONE DV re-warm
    void castPartyRecover(); // Batch2 #4: re-cast the SAME party lane at the room clock, past the solo-lock
    // Batch2 #5: a from-cast party's "path" can be a hub HLS/cast lane URL that
    // hides the real media in its ?src= param — normalize to a file/key that
    // partyMediaJson (and the hub's §D dur-backfill) can resolve.
    QString resolvePartyPath(const QString &uri) const;
    void partyPoll();
    // Party media doc for the current file: canonical key + duration + the
    // detail-page metadata (poster/backdrop art basenames, plot, rating,
    // runtime, genres, director, year) so a the author-hosted party shows the same
    // rich join screen the test driver does.
    QJsonObject partyMediaJson() const;
    QJsonObject partyMediaJson(const QString &path, double durationS,
                               const QString &title) const;
};
