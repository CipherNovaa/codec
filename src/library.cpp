#include "library.h"

#include "logger.h"
#include "resumestore.h"

#include <QCollator>
#include <QDate>
#include <QDir>
#include <QSet>
#include <QDirIterator>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QUrl>
#include <QJsonObject>
#include <QMutex>
#include <QRandomGenerator>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QtConcurrentRun>
#include <QFutureWatcher>
#include <QSaveFile>

#include <algorithm>

namespace {

const QStringList kVideoExts = {
    QStringLiteral("mkv"), QStringLiteral("mp4"), QStringLiteral("avi"),
    QStringLiteral("m2ts"), QStringLiteral("ts"), QStringLiteral("mov"),
    QStringLiteral("wmv"), QStringLiteral("flv"), QStringLiteral("webm"),
    QStringLiteral("mpg"), QStringLiteral("mpeg"), QStringLiteral("iso"),
};

bool isVideoFile(const QFileInfo &info)
{
    return kVideoExts.contains(info.suffix().toLower());
}

// The main movie file in a release folder = the biggest video, skipping samples.
QString primaryVideoIn(const QString &dirPath)
{
    QDirIterator it(dirPath, QDir::Files, QDirIterator::Subdirectories);
    QString best;
    qint64 bestSize = -1;
    while (it.hasNext()) {
        it.next();
        const QFileInfo info = it.fileInfo();
        if (!isVideoFile(info))
            continue;
        if (info.fileName().contains(QLatin1String("sample"), Qt::CaseInsensitive))
            continue;
        if (info.size() > bestSize) {
            bestSize = info.size();
            best = info.absoluteFilePath();
        }
    }
    return best;
}

// A clearlogo is only usable if it exists AND carries real transparency. A PNG
// with no alpha channel renders as an opaque slab over the backdrop — the
// "intense white box" bug. We read the PNG header cheaply (IHDR colour type;
// a palette image needs a tRNS chunk to be transparent) and, if it can't be
// transparent, treat the title as logo-less so the UI falls back to the clean
// text title — WITHOUT deleting the file or the DB pointer, so a good re-fetch
// just starts working. This is the single gate every logo passes through.
// #10: art remoted for a satellite is an http(s) URL, not a local file — an
// on-disk existence/transparency check would wrongly clear it. This is how
// loadManifest tells a remote art URL from a hub-local path.
static bool isRemoteArt(const QString &p)
{
    return p.startsWith(QLatin1String("http://"))
        || p.startsWith(QLatin1String("https://"));
}

// An episode takes its IDENTITY from the SHOW — the grid poster and the title
// logo — which is what fixed the mismatched-poster / wrong-logo bug (an episode
// "Bridge" no longer wears a random "Bridge" film's art). But its BACKGROUND
// stays its own: each episode's still (which arrives in its poster field from
// the TMDB still) becomes the fanart the detail page renders behind it, so an
// episode looks like itself instead of the same show backdrop as every other.
// Called from BOTH library builders (live scan + manifest load).
static void inheritShowArt(QVector<Library::Entry> &entries)
{
    QHash<QString, const Library::Entry *> showByTitle;
    for (const Library::Entry &e : entries)
        if (e.kind == QLatin1String("show"))
            showByTitle.insert(e.title, &e);
    if (showByTitle.isEmpty())
        return;
    for (Library::Entry &e : entries) {
        if (e.kind != QLatin1String("episode"))
            continue;
        if (const Library::Entry *sh = showByTitle.value(e.show, nullptr)) {
            // Per-episode background = the episode's own still (read BEFORE the
            // poster is reassigned); fall back to the show's fanart if it has none.
            e.fanart = !e.poster.isEmpty() ? e.poster : sh->fanart;
            e.poster = sh->poster;       // show poster for grid/continue/search
            e.clearlogo = sh->clearlogo; // show logo for the title
        }
    }
}

bool logoUsableUncached(const QString &path);

QMutex g_logoLock;
QHash<QString, bool> g_logoVerdicts;   // "path|size|mtime" → usable
bool g_logoVerdictsLoaded = false;
bool g_logoVerdictsDirty = false;

QString logoVerdictsPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)
        + QStringLiteral("/codec/logo-verdicts.json");
}

void loadLogoVerdictsLocked()
{
    if (g_logoVerdictsLoaded)
        return;
    g_logoVerdictsLoaded = true;
    QFile f(logoVerdictsPath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it)
        g_logoVerdicts.insert(it.key(), it.value().toBool());
}

// Memoised per file (path + size + mtime, so a replaced logo is re-judged).
// setEntries asks for EVERY entry and an episode carries its show's logo, so
// uncached this re-decoded the same PNG once per episode on every rescan — a
// ~1.4 s GUI-thread freeze as home came up. Locked: the manifest path may call
// this off the GUI thread.
bool logoUsable(const QString &path)
{
    if (path.isEmpty())
        return false;
    const QFileInfo fi(path);
    if (!fi.exists())
        return false;
    const QString key = path + QLatin1Char('|') + QString::number(fi.size())
        + QLatin1Char('|') + QString::number(fi.lastModified().toMSecsSinceEpoch());
    {
        QMutexLocker held(&g_logoLock);
        loadLogoVerdictsLocked();
        if (const auto v = g_logoVerdicts.constFind(key); v != g_logoVerdicts.constEnd())
            return v.value();
    }
    const bool ok = logoUsableUncached(path);
    QMutexLocker held(&g_logoLock);
    g_logoVerdicts.insert(key, ok);
    g_logoVerdictsDirty = true;
    return ok;
}

// Write the verdicts back (after a scan) so the NEXT launch decodes only new or
// replaced logos — the first scan of every launch used to re-decode them all.
void flushLogoVerdicts()
{
    QMutexLocker held(&g_logoLock);
    if (!g_logoVerdictsDirty)
        return;
    QJsonObject o;
    for (auto it = g_logoVerdicts.constBegin(); it != g_logoVerdicts.constEnd(); ++it)
        o.insert(it.key(), it.value());
    QDir().mkpath(QFileInfo(logoVerdictsPath()).absolutePath());
    QSaveFile f(logoVerdictsPath());
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
        if (f.commit())
            g_logoVerdictsDirty = false;
    }
}

bool logoUsableUncached(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return false;                     // missing/unreadable
    const QByteArray head = f.read(64);
    static const QByteArray kPngSig = QByteArray::fromHex(QByteArrayLiteral("89504e470d0a1a0a"));
    if (!head.startsWith(kPngSig)) {
        // Not a PNG. A JPEG CAN'T carry transparency, so a "logo" delivered as one
        // is an opaque slab over the backdrop — the pure-white-box bug (#238); treat
        // it as logo-less. Other formats (webp/gif can be transparent) are assumed ok.
        static const QByteArray kJpg = QByteArray::fromHex(QByteArrayLiteral("ffd8ff"));
        return !head.startsWith(kJpg);
    }
    if (head.size() < 26)
        return false;
    const quint8 colorType = quint8(head.at(25)); // IHDR colour type byte
    if (colorType == 0 || colorType == 2)
        return false;                     // greyscale / truecolour — no alpha, opaque
    if (colorType == 3)                   // palette: transparent only via a tRNS chunk
        return f.readAll().contains(QByteArrayLiteral("tRNS"));
    // colorType 4/6 DECLARE an alpha channel, but an all-opaque alpha (α=255 across
    // the whole image) still paints a solid slab and hides the title — exactly the
    // white box (#238). The header can't tell an opaque RGBA logo from a real one,
    // so sample the ACTUAL alpha with a cheap scaled decode: a fully-opaque source
    // stays opaque at any scale, a real logo (text on transparency) keeps α<255.
    f.close();
    QImageReader reader(path);
    reader.setScaledSize(QSize(48, 48));  // scaled decode keeps this ~1ms per logo
    QImage img = reader.read();
    if (img.isNull() || !img.hasAlphaChannel())
        return false;                     // undecodable or somehow no alpha → distrust
    img = img.convertToFormat(QImage::Format_ARGB32);
    for (int y = 0; y < img.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(img.constScanLine(y));
        for (int x = 0; x < img.width(); ++x)
            if (qAlpha(line[x]) < 250)
                return true;              // has real transparency → a proper logo
    }
    return false;                         // alpha channel present but fully opaque = slab
}

} // namespace

bool Library::isVideoSuffix(const QString &suffix)
{
    return kVideoExts.contains(suffix.toLower());
}

Library::Library(ResumeStore *store, QObject *parent)
    : QAbstractListModel(parent)
    , m_store(store)
{
    const QString cfgDir = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
        + QStringLiteral("/codec");
    QDir().mkpath(cfgDir);
    m_configPath = cfgDir + QStringLiteral("/config.json");

    if (!QFile::exists(m_configPath)) {
        // First run: no media paths. The person names their own after picking
        // a display (CHOOSE MEDIA PATHS) — this used to seed the hub's /mnt
        // drives, which on any other machine was an empty library and no way
        // to say where the films are.
        QFile f(m_configPath);
        if (f.open(QIODevice::WriteOnly))
            f.write(QJsonDocument(QJsonObject{{QStringLiteral("roots"), QJsonArray()}})
                        .toJson(QJsonDocument::Indented));
    }

    // Remote mode: a client (e.g. the laptop) points at a manifest exported by
    // the server and streams over HTTP instead of scanning a local filesystem.
    QFile cf(m_configPath);
    if (cf.open(QIODevice::ReadOnly)) {
        const QString mp = QJsonDocument::fromJson(cf.readAll())
                               .object().value(QStringLiteral("remoteLibrary")).toString();
        if (!mp.isEmpty())
            m_manifestPath = mp.startsWith(QLatin1Char('~'))
                ? QDir::home().filePath(mp.mid(2)) : mp;
    }

    // Live disk watching. A file copy fires a burst of directoryChanged events;
    // the debounce waits for it to settle (a partial file scans harmlessly, but
    // this keeps us from scanning mid-copy), then a single rescan runs. rearmWatch
    // re-derives the watched dirs after every scan so new folders start watched.
    m_watchDebounce.setSingleShot(true);
    m_watchDebounce.setInterval(3000);
    connect(&m_watchDebounce, &QTimer::timeout, this, [this] {
        if (m_liveWatch)
            rescan();
    });
    connect(&m_rootWatcher, &QFileSystemWatcher::directoryChanged, this,
            [this](const QString &) {
        if (m_liveWatch)
            m_watchDebounce.start();
    });
    loadGuides();
}

void Library::setLiveWatch(bool on)
{
    if (on == m_liveWatch)
        return;
    m_liveWatch = on;
    rearmWatch(); // arm the watches, or tear them all down
}

void Library::rearmWatch()
{
    const QStringList old = m_rootWatcher.directories();
    if (!old.isEmpty())
        m_rootWatcher.removePaths(old);
    if (!m_liveWatch)
        return;
    QFile f(m_configPath);
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonArray roots = QJsonDocument::fromJson(f.readAll())
                                 .object().value(QStringLiteral("roots")).toArray();
    QStringList paths;
    for (const QJsonValue &rootVal : roots) {
        const QString rootPath = rootVal.toObject().value(QStringLiteral("path")).toString();
        QDir dir(rootPath);
        if (!dir.exists()) // unmounted drive: nothing to watch, don't error
            continue;
        paths << rootPath; // a new movie/show folder fires on the root itself
        // One level deep: a file finishing its copy inside a release/show folder
        // fires there. Capped so a pathological root can't blow the inotify budget.
        const auto subs = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        for (const QFileInfo &sub : subs) {
            if (paths.size() >= 1500)
                break;
            paths << sub.absoluteFilePath();
        }
    }
    if (!paths.isEmpty())
        m_rootWatcher.addPaths(paths); // failed adds (races) are ignored
}

// The identity a manifest url matches on: its decoded PATH, host-agnostic
// (the cast worker's manifest_index does the same), so a url the app rewrote
// to the tailnet host still finds its index.
QString Library::manifestKey(const QString &url)
{
    if (url.contains(QLatin1String("://")))
        return QUrl(url).path(QUrl::FullyDecoded);
    return QUrl::fromPercentEncoding(url.toUtf8());
}

int Library::manifestIndexOf(const QString &url) const
{
    if (url.isEmpty() || m_manifestIdx.isEmpty())
        return -1;
    return m_manifestIdx.value(manifestKey(url), -1);
}

QVector<Library::Entry> Library::loadManifest() const
{
    QVector<Entry> out;
    QFile f(m_manifestPath);
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QJsonArray arr = QJsonDocument::fromJson(f.readAll())
                               .object().value(QStringLiteral("entries")).toArray();
    m_manifestIdx.clear();
    int mi = -1;   // position in the manifest = the hub browse surface's index
    for (const QJsonValue &v : arr) {
        ++mi;
        const QJsonObject o = v.toObject();
        Entry e;
        e.title = o.value(QStringLiteral("title")).toString();
        e.subtitle = o.value(QStringLiteral("subtitle")).toString();
        e.path = o.value(QStringLiteral("url")).toString();
        // the manifest index this title answers to on the hub's browse surface
        if (!e.path.trimmed().isEmpty())
            m_manifestIdx.insert(manifestKey(e.path), mi);
        if (e.path.trimmed().isEmpty())
            continue; // a row with no URL is unplayable — skip, don't count it
        e.kind = o.value(QStringLiteral("kind")).toString();
        e.show = o.value(QStringLiteral("show")).toString();
        e.sortKey = o.value(QStringLiteral("sortKey")).toString();
        e.plot = o.value(QStringLiteral("plot")).toString();
        e.rating = o.value(QStringLiteral("rating")).toDouble();
        e.runtimeMin = o.value(QStringLiteral("runtimeMin")).toInt();
        e.genres = o.value(QStringLiteral("genres")).toString();
        // #10: on a SATELLITE the manifest's art is remoted to http(s) /art/ URLs
        // (like `url`), which are not local files — an existence/transparency check
        // would clear every poster/fanart/logo and leave the library art-less. Only
        // local paths (the hub reading its own manifest) get the on-disk check.
        e.poster = o.value(QStringLiteral("poster")).toString();
        if (!e.poster.isEmpty() && !isRemoteArt(e.poster) && !QFile::exists(e.poster))
            e.poster.clear();
        e.fanart = o.value(QStringLiteral("fanart")).toString();
        if (!e.fanart.isEmpty() && !isRemoteArt(e.fanart) && !QFile::exists(e.fanart))
            e.fanart.clear();
        e.clearlogo = o.value(QStringLiteral("clearlogo")).toString();
        // A remote logo can't be transparency-checked on the satellite — trust the
        // exporter (it only remotes a logo it already deemed usable on the hub).
        if (!isRemoteArt(e.clearlogo) && !logoUsable(e.clearlogo))
            e.clearlogo.clear();
        e.credits = o.value(QStringLiteral("credits")).toString();
        e.director = o.value(QStringLiteral("director")).toString();
        e.similar = o.value(QStringLiteral("similar")).toString();
        e.tmdbId = o.value(QStringLiteral("tmdbId")).toString();
        // Media-flag chips arrive pre-probed: the satellite only holds URLs,
        // so the hub's ffprobe verdict in the manifest is the only source.
        const QJsonArray flags = o.value(QStringLiteral("flags")).toArray();
        for (const QJsonValue &fv : flags)
            e.flags << fv.toString();
        e.revenue = static_cast<qint64>(o.value(QStringLiteral("revenue")).toDouble());
        e.budget = static_cast<qint64>(o.value(QStringLiteral("budget")).toDouble());
        e.studio = o.value(QStringLiteral("studio")).toString();
        e.country = o.value(QStringLiteral("country")).toString();
        e.language = o.value(QStringLiteral("language")).toString();
        e.writer = o.value(QStringLiteral("writer")).toString();
        e.introStart = o.value(QStringLiteral("introStart")).toDouble();
        e.introEnd = o.value(QStringLiteral("introEnd")).toDouble();
        e.creditsStart = o.value(QStringLiteral("creditsStart")).toDouble();
        // Bonus features: the parent title's URL, page group and runtime
        // (export_library.py extra_row — the hub's own labels, never re-derived).
        e.parent = o.value(QStringLiteral("parent")).toString();
        e.group = o.value(QStringLiteral("group")).toString();
        e.durationS = o.value(QStringLiteral("durationS")).toDouble();
        // Year: prefer the exporter's explicit `year` (real metadata — the only
        // source that works for a show whose title/subtitle carries no year
        // token, which otherwise read 0). Fall back to the first 19xx/20xx token
        // in subtitle then title only when the manifest doesn't carry one.
        e.year = o.value(QStringLiteral("year")).toInt();
        if (e.year <= 0) {
            static const QRegularExpression heroYearRe(QStringLiteral("\\b(19|20)\\d\\d\\b"));
            // Take the LAST token, matching export_library.py's parse() — the
            // first can be part of the title ("Blade Runner 2049 (2017)"), which
            // diverged the satellite's year from the hub's on such titles.
            auto lastYear = [](const QString &s) {
                int y = 0;
                auto it = heroYearRe.globalMatch(s);
                while (it.hasNext()) y = it.next().captured(0).toInt();
                return y;
            };
            e.year = lastYear(e.subtitle);
            if (e.year <= 0)
                e.year = lastYear(e.title);
        }
        e.added = static_cast<qint64>(o.value(QStringLiteral("added")).toDouble());
        e.arrived = static_cast<qint64>(o.value(QStringLiteral("arrived")).toDouble());
        out.append(e);
    }
    std::sort(out.begin(), out.end(),
              [](const Entry &a, const Entry &b) { return a.sortKey < b.sortKey; });
    return out;
}

// ── what the FILE is, not what its name claims ──────────────────────────────
// A release name is a claim, and it is often silent: 26 films in this library
// are real HDR10 — PQ transfer, bt2020 primaries, 10-bit — and say nothing
// about it in the filename, so they showed as plain "4K". That label is what
// you read when deciding which copy of a film to keep, and it nearly cost a
// better Interstellar during a drive import.
//
// Cached by path|size|mtime in a file SHARED with export_library.py, so
// whichever runs first pays for the probe and the other gets it free. Runs on
// the scan thread (QtConcurrent::run), never on the GUI thread.
namespace {

QString probeCachePath()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)
           + QStringLiteral("/codec/videoprobe.json");
}

struct ProbeCache {
    QJsonObject obj;
    bool dirty = false;

    void load()
    {
        QFile f(probeCachePath());
        if (f.open(QIODevice::ReadOnly))
            obj = QJsonDocument::fromJson(f.readAll()).object();
    }
    void save()
    {
        if (!dirty)
            return;
        QDir().mkpath(QFileInfo(probeCachePath()).absolutePath());
        // Atomic write: videoprobe.json is shared with export_library.py, so a
        // reader must never catch a half-written truncation. QSaveFile writes to
        // a temp file and renames into place on commit().
        QSaveFile f(probeCachePath());
        if (f.open(QIODevice::WriteOnly)) {
            f.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
            f.commit();
        }
    }
};

// Picture + sound properties read from the file's OWN streams (never the name).
// w == 0 means the file could not be read.
struct Probe {
    int w = 0, h = 0;
    bool hdr = false;   // PQ (smpte2084) or HLG (arib-std-b67) transfer
    bool dv = false;    // a Dolby Vision configuration record rides the stream
    int channels = 0;   // primary audio layout (6 = 5.1, 8 = 7.1)
    bool atmos = false; // object audio (TrueHD / E-AC-3 + Atmos)
    int year = 0;       // release year from a container release-date TAG (real
                        // metadata) — NOT creation_time, which is the encode date
};

Probe probeVideo(const QString &path, ProbeCache &cache)
{
    const QFileInfo fi(path);
    if (!fi.exists())
        return {};
    const QString key = QStringLiteral("%1|%2|%3").arg(path)
                            .arg(fi.size()).arg(fi.lastModified().toSecsSinceEpoch());
    if (cache.obj.contains(key)) {
        const QJsonObject o = cache.obj.value(key).toObject();
        // Re-probe entries cached before the audio/DV fields existed. A missing
        // "yr" is NOT cause to re-probe (that would re-scan the whole library) —
        // year just reads 0 from old cache entries and the name fallbacks cover it.
        if (o.contains(QStringLiteral("ch"))) {
            Probe c{o.value(QStringLiteral("w")).toInt(),
                    o.value(QStringLiteral("h")).toInt(),
                    o.value(QStringLiteral("hdr")).toBool(),
                    o.value(QStringLiteral("dv")).toBool(),
                    o.value(QStringLiteral("ch")).toInt(),
                    o.value(QStringLiteral("atmos")).toBool()};
            c.year = o.value(QStringLiteral("yr")).toInt();
            return c;
        }
    }
    Probe p;
    QProcess ff;
    ff.start(QStringLiteral("/usr/bin/ffprobe"),
             {QStringLiteral("-v"), QStringLiteral("error"),
              QStringLiteral("-show_streams"), QStringLiteral("-show_format"),
              QStringLiteral("-of"), QStringLiteral("json"), path});
    if (ff.waitForFinished(45000)) {
        const QJsonObject root = QJsonDocument::fromJson(ff.readAllStandardOutput()).object();
        // release year from a real date TAG (date / DATE_RELEASED / originalyear);
        // creation_time is deliberately ignored — it's the ENCODE date, not release.
        const QJsonObject ftags = root.value(QStringLiteral("format")).toObject()
                                      .value(QStringLiteral("tags")).toObject();
        static const QRegularExpression tagYearRe(QStringLiteral("\\b(19[3-9]\\d|20[0-4]\\d)\\b"));
        const QStringList dateKeys{QStringLiteral("DATE_RELEASED"), QStringLiteral("date_released"),
                                   QStringLiteral("RELEASE_DATE"), QStringLiteral("date"),
                                   QStringLiteral("DATE"), QStringLiteral("originalyear"),
                                   QStringLiteral("ORIGINALYEAR"), QStringLiteral("year"),
                                   QStringLiteral("YEAR")};
        for (const QString &k : dateKeys) {
            const auto m = tagYearRe.match(ftags.value(k).toString());
            if (m.hasMatch()) { p.year = m.captured(1).toInt(); break; }
        }
        const QJsonArray streams = root.value(QStringLiteral("streams")).toArray();
        for (const QJsonValue &sv : streams) {
            const QJsonObject s = sv.toObject();
            const QString type = s.value(QStringLiteral("codec_type")).toString();
            if (type == QLatin1String("video") && p.w == 0) {
                p.w = s.value(QStringLiteral("width")).toInt();
                p.h = s.value(QStringLiteral("height")).toInt();
                const QString trc = s.value(QStringLiteral("color_transfer")).toString();
                p.hdr = trc == QLatin1String("smpte2084")
                        || trc == QLatin1String("arib-std-b67");
                const QJsonArray sd = s.value(QStringLiteral("side_data_list")).toArray();
                for (const QJsonValue &d : sd) {
                    const QString t = d.toObject().value(QStringLiteral("side_data_type")).toString();
                    if (t.contains(QLatin1String("DOVI"), Qt::CaseInsensitive)
                        || t.contains(QLatin1String("Dolby Vision"), Qt::CaseInsensitive))
                        p.dv = true;
                }
            } else if (type == QLatin1String("audio") && p.channels == 0) {
                p.channels = s.value(QStringLiteral("channels")).toInt();
                if (s.value(QStringLiteral("profile")).toString()
                        .contains(QLatin1String("Atmos"), Qt::CaseInsensitive))
                    p.atmos = true;
            }
        }
    }
    cache.obj[key] = QJsonObject{{QStringLiteral("w"), p.w},
                                 {QStringLiteral("h"), p.h},
                                 {QStringLiteral("hdr"), p.hdr},
                                 {QStringLiteral("dv"), p.dv},
                                 {QStringLiteral("ch"), p.channels},
                                 {QStringLiteral("atmos"), p.atmos},
                                 {QStringLiteral("yr"), p.year}};
    cache.dirty = true;
    return p;
}

// ⚠ NEITHER dimension alone is enough, and both mistakes are real here. Judge
// on height and a 4K scope film (3840x1600) reads as 1080p; judge on WIDTH and
// a pillarboxed 1080p transfer reads as 720p — this library has four of those
// (Ninja Scroll 1460x1080, Macross Plus 1512x1080). Take whichever dimension
// claims the higher class.
QString qualityForFrame(int w, int h)
{
    if (w >= 3200 || h >= 1700) return QStringLiteral("2160p");
    if (w >= 1700 || h >= 950)  return QStringLiteral("1080p");
    if (w >= 1200 || h >= 650)  return QStringLiteral("720p");
    return (w > 0 || h > 0) ? QStringLiteral("480p") : QString();
}

// Media-flag chips from the probe alone: 4K (only 2160p is badged, matching the
// old design), dynamic range (DV supersedes HDR10), and the audio layout.
// Empty when the file couldn't be read — a missing badge beats a guessed one.
QStringList probeFlags(const Probe &p)
{
    QStringList f;
    if (p.w <= 0)
        return f;
    // Badge 1080p explicitly, not just 4K. The old design left 1080p unbadged and
    // let the ABSENCE of a 4K chip mean "not 4K" — which reads fine while the
    // library is overwhelmingly 4K and stops working the moment it is not. With
    // large titles moving to good 1080p encodes to fit the disks, "no badge" now
    // covers both "1080p" and "we could not read it", and those must not look
    // alike. 720p/480p stay unbadged: rare enough that a chip is noise.
    const QString q = qualityForFrame(p.w, p.h);
    if (q == QLatin1String("2160p"))
        f << QStringLiteral("4K");
    else if (q == QLatin1String("1080p"))
        f << QStringLiteral("1080p");
    if (p.dv)
        f << QStringLiteral("DV");
    else if (p.hdr)
        f << QStringLiteral("HDR10");
    if (p.atmos)
        f << QStringLiteral("ATMOS");
    else if (p.channels >= 8)
        f << QStringLiteral("7.1");
    else if (p.channels >= 6)
        f << QStringLiteral("5.1");
    return f;
}

// Directories whose contents are ABOUT the show rather than part of it. One
// boxed set arrived with 181 featurettes sitting next to 226 episodes.
// ⚠ Matched on the DIRECTORY, never on "this file has no episode number" —
// plenty of real episodes don't (Berserk numbers its files "Berserk - 01"),
// and dropping those would delete a third of the shows in this library.
bool inExtrasDir(const QString &relPath)
{
    static const QRegularExpression re(
        QStringLiteral("/(featurettes?|extras?|behind[ .]the[ .]scenes"
                       "|deleted[ .]scenes|bonus|interviews?|trailers?|making[ .]of)/"),
        QRegularExpression::CaseInsensitiveOption);
    return re.match(QLatin1Char('/') + relPath).hasMatch();
}

// ── Bonus features: title, group, order ─────────────────────────────────────
// ⚠ MIRROR of export_library.py (extra_title / extra_group / extra_sort_key).
// The hub labels extras here; the laptop reads the exporter's labels from the
// manifest. Both must agree or the two machines show different pages.
static QString tidyExtraName(QString s)
{
    // U+A789 is the "colon" Windows-safe rips put in file names.
    s.replace(QChar(0xA789), QLatin1Char(':')).replace(QChar(0xFF1A), QLatin1Char(':'));
    static const QRegularExpression dotsRe(QStringLiteral("[._]"));
    static const QRegularExpression dotRunRe(QStringLiteral("[._]+"));
    if (!s.contains(QLatin1Char(' ')) && s.contains(dotsRe))
        s.replace(dotRunRe, QStringLiteral(" "));
    static const QRegularExpression junkRe(
        QStringLiteral("\\s*[\\[(][^\\[\\]()]*\\b(?:2160p|1080p|720p|480p|x26[45]|hevc"
                       "|bluray|web-?dl|webrip)\\b[^\\[\\]()]*[\\])]"),
        QRegularExpression::CaseInsensitiveOption);
    s.remove(junkRe);
    return s.simplified();
}

QString extraTitle(const QString &stem)
{
    // "01) Clarice Meets Lecter" -> "01 Clarice Meets Lecter"
    static const QRegularExpression numRe(QStringLiteral("^(\\d{1,3})\\)\\s*"));
    QString t = tidyExtraName(stem);
    t.replace(numRe, QStringLiteral("\\1 "));
    return t.isEmpty() ? stem : t;
}

// The folders BELOW the extras folder name the group; with none, the extras
// folder itself does ("Featurettes"). Folders above it are the release name —
// except on a show, where they carry the season ("Season 3 / Deleted Scenes").
QString extraGroup(const QString &relDir, bool tv, int *seasonOut = nullptr,
                   bool *rootOut = nullptr)
{
    static const QRegularExpression keyRe(
        QStringLiteral("^(featurettes?|extras?|behind[ .]the[ .]scenes|deleted[ .]scenes"
                       "|bonus|interviews?|trailers?|making[ .]of)$"),
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression seasonRe(
        QStringLiteral("(?:^|[^a-z0-9])s(\\d{1,2})(?:e\\d+)?(?=$|[^a-z0-9])"
                       "|season[\\s._-]*(\\d{1,2})"),
        QRegularExpression::CaseInsensitiveOption);
    const QStringList comps = QString(relDir).replace(QLatin1Char('\\'), QLatin1Char('/'))
                                  .split(QLatin1Char('/'), Qt::SkipEmptyParts);
    int k = -1;
    for (int i = 0; i < comps.size(); ++i)
        if (keyRe.match(comps[i]).hasMatch()) { k = i; break; }
    if (k < 0) {
        if (seasonOut) *seasonOut = 0;
        if (rootOut) *rootOut = true;
        return QStringLiteral("Bonus");
    }
    QStringList post;
    for (int i = k + 1; i < comps.size(); ++i)
        post << tidyExtraName(comps[i]);
    QString label = post.isEmpty() ? tidyExtraName(comps[k]) : post.join(QStringLiteral(" / "));
    int season = 0;
    if (tv)
        for (int i = 0; i < k; ++i) {
            const auto m = seasonRe.match(comps[i]);
            if (m.hasMatch())
                season = (m.captured(1).isEmpty() ? m.captured(2) : m.captured(1)).toInt();
        }
    if (season > 0)
        label = QStringLiteral("Season %1 / %2").arg(season).arg(label);
    if (seasonOut) *seasonOut = season;
    if (rootOut) *rootOut = post.isEmpty();
    return label;
}

QString extraSortKey(const QString &parentSort, const QString &relDir,
                     const QString &stem, bool tv)
{
    int season = 0;
    bool root = true;
    const QString label = extraGroup(relDir, tv, &season, &root);
    return QStringLiteral("%1 ~%2%3 %4 | %5")
        .arg(parentSort)
        .arg(season, 3, 10, QLatin1Char('0'))
        .arg(root ? 0 : 1)
        .arg(label.toLower(), stem.toLower());
}

// codec_extras.py's index: {path: {dur, thumb}} — the frame grab and runtime
// for each extra. Read once per scan; an extra it hasn't reached yet simply
// has no thumbnail until the next one.
struct ExtraInfo { double dur = 0; QString thumb; };
static QHash<QString, ExtraInfo> loadExtrasIndex()
{
    QHash<QString, ExtraInfo> out;
    QFile f(QDir::homePath() + QStringLiteral("/.cache/codec/extras.json"));
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    for (auto it = o.constBegin(); it != o.constEnd(); ++it) {
        const QJsonObject v = it.value().toObject();
        ExtraInfo x;
        x.dur = v.value(QStringLiteral("dur")).toDouble();
        x.thumb = v.value(QStringLiteral("thumb")).toString();
        if (!x.thumb.isEmpty() && !QFile::exists(x.thumb))
            x.thumb.clear();
        out.insert(it.key(), x);
    }
    return out;
}

static Library::Entry makeExtra(const QFileInfo &file, const QString &parentPath,
                                const QString &relDir, const QString &parentTitle,
                                const QString &parentSort, bool tv,
                                const QHash<QString, ExtraInfo> &index)
{
    Library::Entry e;
    e.kind = QStringLiteral("extra");
    e.title = extraTitle(file.completeBaseName());
    e.show = parentTitle;
    e.parent = parentPath;
    e.group = extraGroup(relDir, tv);
    e.sortKey = extraSortKey(parentSort, relDir, file.completeBaseName(), tv);
    e.path = file.absoluteFilePath();
    e.added = file.lastModified().toSecsSinceEpoch();
    const ExtraInfo x = index.value(e.path);
    e.durationS = x.dur;
    e.poster = x.thumb;
    return e;
}

// Episode numbers that aren't SxxExx. Plenty of shows use "Berserk - 01" or
// "Patlabor ... Episode.01", and codec_tmdb.py has understood those all along
// — so the SCRAPER knew they were episodes 1..25 while this scanner and the
// manifest builder labelled them by filename. Three walkers, three notions of
// what an episode is.
//
// ⚠ ANCHORED on purpose. "a dash then a number" also matches "Implanted
// Memories - 25 Years of The X-Files" and files a featurette as S01E25. The
// number must END the name or be followed by a bracket, never by another
// word. "Episode N" keeps its keyword form, which is unambiguous.
bool looseEpisode(const QString &stem, const QString &dirPath,
                  int *season, int *episode)
{
    static const QRegularExpression kw(QStringLiteral("\\bEpisode\\s+(\\d{1,3})\\b"),
                                       QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression dash(QStringLiteral("-\\s+(\\d{1,3})\\s*(?=[\\[(]|$)"));
    QString flat = stem;
    flat.replace(QRegularExpression(QStringLiteral("[._]")), QStringLiteral(" "));
    auto m = kw.match(flat);
    if (!m.hasMatch())
        m = dash.match(flat);
    if (!m.hasMatch())
        return false;
    // #33: derive the season from an enclosing "Season N" / "S0N" folder rather
    // than pinning 1 — two loose-numbered episodes in different seasons otherwise
    // produce byte-identical sortKeys and identical "S01Exx" titles (they collide
    // and next/prev walks the wrong one). A component that IS a season label only,
    // deepest (closest to the file) wins; default 1 when there's no season folder.
    static const QRegularExpression seasonDir(
        QStringLiteral("^s(?:eason)?[\\s._]*0*(\\d{1,2})$"),
        QRegularExpression::CaseInsensitiveOption);
    int s = 1;
    const auto comps = dirPath.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    for (const QString &comp : comps) {
        const auto sm = seasonDir.match(comp.trimmed());
        if (sm.hasMatch())
            s = sm.captured(1).toInt();   // deepest match wins (loop runs root→leaf)
    }
    *season = s;
    *episode = m.captured(1).toInt();
    return true;
}

// Rewrite a subtitle's resolution and dynamic-range tokens from the probe,
// keeping the two things only the NAME can tell us: the year and REMUX.
// `sub` ("1993 · 1080p") with its year token replaced by `year`, or the year
// put first when it carries none. Mirrors export_library._with_year.
static QString withYear(const QString &sub, int year)
{
    QStringList parts = sub.split(QStringLiteral(" · "), Qt::SkipEmptyParts);
    for (QString &t : parts)
        if (t.size() == 4 && t.toInt() > 1800) {
            t = QString::number(year);
            return parts.join(QStringLiteral(" · "));
        }
    parts.prepend(QString::number(year));
    return parts.join(QStringLiteral(" · "));
}

QString subtitleWithProbe(const QString &sub, const Probe &p)
{
    if (p.w <= 0)
        return sub;
    QString year;
    bool remux = false;
    const auto parts = sub.split(QStringLiteral(" · "), Qt::SkipEmptyParts);
    for (const QString &t : parts) {
        if (t.compare(QLatin1String("REMUX"), Qt::CaseInsensitive) == 0)
            remux = true;
        else if (t.size() == 4 && t.toInt() > 1800)
            year = t;
    }
    const QString q = qualityForFrame(p.w, p.h);
    QStringList out;
    if (!year.isEmpty())
        out << year;
    if (!q.isEmpty())
        out << (q == QLatin1String("2160p") ? QStringLiteral("4K") : q);
    if (p.hdr)
        out << QStringLiteral("HDR");
    if (remux)
        out << QStringLiteral("REMUX");
    return out.join(QStringLiteral(" · "));
}

} // namespace

Library::Entry Library::parseName(const QString &rawName, const QString &kind,
                                  const QString &show)
{
    QString s = rawName;
    s.replace(QLatin1Char('.'), QLatin1Char(' '));
    s.replace(QLatin1Char('_'), QLatin1Char(' '));
    // Quality/HDR tags often live INSIDE bracket chunks — detect on a copy
    // that keeps their contents.
    QString flat = s;
    flat.replace(QRegularExpression(QStringLiteral("[\\[\\]()]")), QStringLiteral(" "));
    // [Bracketed] chunks are release junk (group tags, "[Dual Audio]",
    // "[1080p]") — drop them whole for the title. Parens keep contents: "(1997)".
    s.remove(QRegularExpression(QStringLiteral("\\[[^\\]]*\\]")));
    s.replace(QRegularExpression(QStringLiteral("[()]")), QStringLiteral(" "));

    // Year = the LAST plausible year token ("Blade Runner 2049 2017" -> 2017).
    static const QRegularExpression yearRe(QStringLiteral("\\b(19[3-9]\\d|20[0-4]\\d)\\b"));
    QString year;
    qsizetype yearPos = -1;
    auto it = yearRe.globalMatch(s);
    while (it.hasNext()) {
        const auto m = it.next();
        year = m.captured(1);
        yearPos = m.capturedStart(1);
    }

    // #36: an implausibly-FUTURE year token is part of the TITLE, not a release
    // year — "Blade Runner 2049" (even as "Blade.Runner.2049.1080p.BluRay", where a
    // release token follows it) ends in a title-number. Trusting it truncated the
    // title AND set a wrong year that then blocked the real container/scraped year.
    // Drop such a token: the title keeps its number and the container/scrape fills
    // the year. A real release year is never meaningfully in the future.
    if (yearPos >= 0 && year.toInt() > QDate::currentDate().year() + 1) {
        year.clear();
        yearPos = -1;
    }

    static const QRegularExpression qualityRe(QStringLiteral("\\b(2160p|1080p|720p|480p)\\b"),
                                              QRegularExpression::CaseInsensitiveOption);
    const auto qualityMatch = qualityRe.match(flat);
    const QString quality = qualityMatch.hasMatch() ? qualityMatch.captured(1).toLower() : QString();

    const bool hdr = flat.contains(QRegularExpression(
        QStringLiteral("\\b(HDR|HDR10\\+?|DV|DoVi|Dolby ?Vision)\\b"),
        QRegularExpression::CaseInsensitiveOption));
    const bool remux = flat.contains(QLatin1String("remux"), Qt::CaseInsensitive);

    // Title = everything before the year (or the first release token).
    qsizetype cut = yearPos > 0 ? yearPos : -1;
    if (cut < 0) {
        static const QRegularExpression tokenRe(QStringLiteral(
            "\\b(2160p|1080p|720p|480p|UHD|BluRay|Blu-Ray|BDRip|WEB-?DL|WEBRip|WEB|HDTV|"
            "REMUX|x26[45]|H ?26[45]|HEVC|AVC|DTS|DDP?|AAC|AC3|TrueHD|Atmos|10bit|8bit|"
            "HDR10?|DV|YTS|YIFY|RARBG)\\b"),
            QRegularExpression::CaseInsensitiveOption);
        const auto tm = tokenRe.match(s);
        if (tm.hasMatch())
            cut = tm.capturedStart(0);
    }
    QString title = (cut > 0 ? s.left(cut) : s).simplified();
    title.remove(QRegularExpression(QStringLiteral("[-–—\\s]+$")));
    if (title.isEmpty())
        title = rawName;

    Entry e;
    e.kind = kind;
    e.show = show;
    e.title = title;
    e.year = year.toInt();
    QStringList sub;
    if (!year.isEmpty())
        sub << year;
    if (!quality.isEmpty())
        sub << (quality == QLatin1String("2160p") ? QStringLiteral("4K") : quality);
    if (hdr)
        sub << QStringLiteral("HDR");
    if (remux)
        sub << QStringLiteral("REMUX");
    e.subtitle = sub.join(QStringLiteral(" · "));
    e.sortKey = title.toLower();
    return e;
}

QString Library::prettyTitle(const QString &path)
{
    const Entry e = parseName(QFileInfo(path).completeBaseName(),
                              QStringLiteral("movie"));
    return e.year > 0
        ? QStringLiteral("%1 (%2)").arg(e.title).arg(e.year)
        : e.title;
}

// The last episode number a double-episode name carries ("S09E19-E20",
// "S06E14E15" → 20, 15); 0 for a single episode.
static int lastEpisodeIn(const QString &code)
{
    static const QRegularExpression re(QStringLiteral("E(\\d{1,3})"),
                                       QRegularExpression::CaseInsensitiveOption);
    int last = 0, n = 0;
    for (auto it = re.globalMatch(code); it.hasNext(); ++n)
        last = it.next().captured(1).toInt();
    return n > 1 ? last : 0;
}

// "The Truth (1)" → "The Truth": the name TMDB gives the first half of a
// two-part episode that lives in one file.
static QString withoutPartOne(const QString &name)
{
    static const QRegularExpression re(QStringLiteral("\\s*\\((?:1|Part 1|I)\\)\\s*$"),
                                       QRegularExpression::CaseInsensitiveOption);
    QString out = name;
    out.remove(re);
    return out.isEmpty() ? name : out;
}

QVector<Library::Entry> Library::scanRoots() const
{
    QVector<Entry> out;
    QFile f(m_configPath);
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QJsonArray roots =
        QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("roots")).toArray();

    // A double episode (S06E14E15, S01E01-E02) keys off the FIRST number, as
    // codec_tmdb.py and export_library.py do — without the E-tail the trailing
    // \b failed and the file sorted after every numbered episode.
    static const QRegularExpression episodeRe(
        QStringLiteral("\\b(?:S(\\d{1,2})E(\\d{1,3})(?:[-_. ]?E\\d{1,3})*|(\\d{1,2})x(\\d{2,3}))\\b"),
        QRegularExpression::CaseInsensitiveOption);

    // One probe per file, ever, unless the file changes. The first scan after
    // this landed pays for the whole library; every scan after it is free.
    ProbeCache probes;
    probes.load();
    const QHash<QString, ExtraInfo> extrasIx = loadExtrasIndex();

    for (const QJsonValue &rootVal : roots) {
        const QJsonObject root = rootVal.toObject();
        const QString rootPath = root.value(QStringLiteral("path")).toString();
        const QString kind = root.value(QStringLiteral("kind")).toString(QStringLiteral("movies"));
        const QDir dir(rootPath);
        if (!dir.exists())
            continue;

        if (kind == QLatin1String("tv")) {
            // Each subdir is a show; episodes are video files inside it.
            const auto shows = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
            for (const QFileInfo &showDir : shows) {
                Entry showMeta = parseName(showDir.fileName(), QStringLiteral("show"));
                // A show folder is not a file, so its quality is read off the
                // biggest episode in it.
                const QString showVid = primaryVideoIn(showDir.absoluteFilePath());
                if (!showVid.isEmpty()) {
                    const Probe sp = probeVideo(showVid, probes);
                    showMeta.subtitle = subtitleWithProbe(showMeta.subtitle, sp);
                    showMeta.flags = probeFlags(sp);
                    // Year, real-data first: a container release-date TAG beats the
                    // folder-name guess (some folders carry no year at all).
                    if (sp.year > 0)
                        showMeta.year = sp.year;
                }
                showMeta.path = showDir.absoluteFilePath();
                showMeta.show = showMeta.title;
                const int showIdx = out.size();
                out.append(showMeta); // one selectable row per show
                int minEpYear = 0;    // earliest year seen in the episode FILES
                QDirIterator it(showDir.absoluteFilePath(), QDir::Files,
                                QDirIterator::Subdirectories);
                QVector<Entry> episodes;
                while (it.hasNext()) {
                    it.next();
                    const QFileInfo info = it.fileInfo();
                    if (!isVideoFile(info)
                        || info.fileName().contains(QLatin1String("sample"), Qt::CaseInsensitive))
                        continue;
                    // Featurettes and deleted scenes: never episodes, never in
                    // the grid — they hang off the show for its BONUS FEATURES
                    // page (parent = the show folder, i.e. the show row's path).
                    const QString rel = QDir(showDir.absoluteFilePath())
                                            .relativeFilePath(info.absoluteFilePath());
                    if (inExtrasDir(rel)) {
                        episodes.append(makeExtra(info, showMeta.path,
                                                  QFileInfo(rel).path(), showMeta.title,
                                                  showMeta.sortKey, true, extrasIx));
                        continue;
                    }
                    Entry e = parseName(info.completeBaseName(),
                                        QStringLiteral("episode"), showMeta.title);
                    const auto em = episodeRe.match(info.fileName());
                    if (em.hasMatch()) {
                        const int season = em.captured(1).isEmpty() ? em.captured(3).toInt()
                                                                    : em.captured(1).toInt();
                        const int episode = em.captured(2).isEmpty() ? em.captured(4).toInt()
                                                                     : em.captured(2).toInt();
                        e.title = QStringLiteral("S%1E%2")
                                      .arg(season, 2, 10, QLatin1Char('0'))
                                      .arg(episode, 2, 10, QLatin1Char('0'));
                        // one file, two episodes (S09E19-E20 "The Truth"): the
                        // code says so — "S09E19-20" — and the join drops
                        // TMDB's "(1)" from the first half's name
                        if (const int last = lastEpisodeIn(em.captured(0)); last > episode)
                            e.title += QStringLiteral("-%1").arg(last, 2, 10, QLatin1Char('0'));
                        e.sortKey = showMeta.sortKey
                            + QStringLiteral(" %1 %2")
                                  .arg(season, 4, 10, QLatin1Char('0'))
                                  .arg(episode, 4, 10, QLatin1Char('0'));
                    } else if (int se = 0, ep = 0;
                               looseEpisode(info.completeBaseName(),
                                            info.absolutePath(), &se, &ep)) {
                        e.title = QStringLiteral("S%1E%2")
                                      .arg(se, 2, 10, QLatin1Char('0'))
                                      .arg(ep, 2, 10, QLatin1Char('0'));
                        e.sortKey = showMeta.sortKey
                            + QStringLiteral(" %1 %2")
                                  .arg(se, 4, 10, QLatin1Char('0'))
                                  .arg(ep, 4, 10, QLatin1Char('0'));
                    } else {
                        e.sortKey = showMeta.sortKey + QLatin1Char(' ') + e.sortKey;
                    }
                    // e.year came from the episode FILE name (parseName) — e.g.
                    // "Invincible.2021.S04E05…" → 2021, even when the folder has none.
                    if (e.year >= 1930 && e.year <= 2049 && (minEpYear == 0 || e.year < minEpYear))
                        minEpYear = e.year;
                    // #35: probe THIS episode's own file (cache-backed + persisted,
                    // so slow only on the first scan) for its OWN HDR/DV/4K flags and
                    // quality line, instead of copying the show's biggest-episode
                    // probe onto every episode — that mislabeled per-episode badges
                    // and made the format facet filter the wrong episodes.
                    const Probe epp = probeVideo(info.absoluteFilePath(), probes);
                    e.subtitle = subtitleWithProbe(showMeta.subtitle, epp);
                    e.flags = probeFlags(epp);
                    e.path = info.absoluteFilePath();
                    e.added = info.lastModified().toSecsSinceEpoch();
                    episodes.append(e);
                }
                // Fall back to the earliest episode-file year only if neither the
                // container tag nor the folder name gave us one.
                if (out[showIdx].year == 0 && minEpYear > 0)
                    out[showIdx].year = minEpYear;
                out += episodes;
            }
        } else {
            const auto entries =
                dir.entryInfoList(QDir::Dirs | QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
            for (const QFileInfo &info : entries) {
                if (info.fileName() == QLatin1String("$RECYCLE.BIN")
                    || info.fileName() == QLatin1String("System Volume Information")
                    || info.fileName().endsWith(QLatin1String(".tmp"), Qt::CaseInsensitive)
                    // codec_qbit_import's staging name: a multi-file title is
                    // copied into "<Title>.importing/" and renamed when its
                    // size checks out — until then it's a partial, not a title
                    || info.fileName().endsWith(QLatin1String(".importing"), Qt::CaseInsensitive)
                    || info.fileName() == QLatin1String("Config.Msi"))
                    continue;
                QString video;
                QString rawName;
                if (info.isDir()) {
                    video = primaryVideoIn(info.absoluteFilePath());
                    rawName = info.fileName();
                } else if (isVideoFile(info)) {
                    video = info.absoluteFilePath();
                    rawName = info.completeBaseName();
                }
                if (video.isEmpty())
                    continue;
                Entry e = parseName(rawName, QStringLiteral("movie"));
                const Probe mp = probeVideo(video, probes);
                e.subtitle = subtitleWithProbe(e.subtitle, mp);
                e.flags = probeFlags(mp);
                if (e.year == 0 && mp.year > 0)   // real container tag over a name with no year
                    e.year = mp.year;
                e.path = video;
                e.added = QFileInfo(video).lastModified().toSecsSinceEpoch();
                out.append(e);
                // The film's bonus features: anything under an extras folder
                // inside its release folder (a loose file in the root has none).
                if (info.isDir()) {
                    const QDir movieDir(info.absoluteFilePath());
                    QDirIterator xit(movieDir.absolutePath(), QDir::Files,
                                     QDirIterator::Subdirectories);
                    while (xit.hasNext()) {
                        xit.next();
                        const QFileInfo xf = xit.fileInfo();
                        if (!isVideoFile(xf) || xf.absoluteFilePath() == video
                            || xf.fileName().contains(QLatin1String("sample"),
                                                      Qt::CaseInsensitive))
                            continue;
                        const QString rel = movieDir.relativeFilePath(xf.absoluteFilePath());
                        if (inExtrasDir(rel))
                            out.append(makeExtra(xf, video, QFileInfo(rel).path(), e.title,
                                                 e.sortKey, false, extrasIx));
                    }
                }
            }
        }
    }

    probes.save();
    std::sort(out.begin(), out.end(),
              [](const Entry &a, const Entry &b) { return a.sortKey < b.sortKey; });
    return out;
}

Library::~Library()
{
    // Block until any in-flight background scan finishes: scanRoots() runs on a
    // pool thread and dereferences `this`, so tearing down before it completes
    // would let the worker touch freed members (UAF on shutdown mid-scan).
    m_scanFuture.waitForFinished();
}

// ── Warm-start cache ────────────────────────────────────────────────────────
// The home reads m_all (spotlight/posters/continue/recent), so it stays empty
// until the first disk walk finishes — seconds on cold NTFS. Cache the fully
// processed entry set after each local scan and paint the home from it at
// launch; the normal background rescan then reconciles. Hub (local) only — a
// satellite already streams its manifest.
static QString libraryCachePath()
{
    const QString dir =
        QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return dir.isEmpty() ? QString() : dir + QStringLiteral("/library-cache.json");
}

static QJsonObject entryToJson(const Library::Entry &e)
{
    return QJsonObject{
        {QStringLiteral("title"), e.title},
        {QStringLiteral("subtitle"), e.subtitle},
        {QStringLiteral("flags"), QJsonArray::fromStringList(e.flags)},
        {QStringLiteral("path"), e.path},
        {QStringLiteral("kind"), e.kind},
        {QStringLiteral("show"), e.show},
        {QStringLiteral("sortKey"), e.sortKey},
        {QStringLiteral("plot"), e.plot},
        {QStringLiteral("rating"), e.rating},
        {QStringLiteral("runtimeMin"), e.runtimeMin},
        {QStringLiteral("genres"), e.genres},
        {QStringLiteral("poster"), e.poster},
        {QStringLiteral("fanart"), e.fanart},
        {QStringLiteral("clearlogo"), e.clearlogo},
        {QStringLiteral("year"), e.year},
        {QStringLiteral("added"), double(e.added)},
        {QStringLiteral("credits"), e.credits},
        {QStringLiteral("director"), e.director},
        {QStringLiteral("similar"), e.similar},
        {QStringLiteral("tmdbId"), e.tmdbId},
        {QStringLiteral("revenue"), double(e.revenue)},
        {QStringLiteral("budget"), double(e.budget)},
        {QStringLiteral("studio"), e.studio},
        {QStringLiteral("country"), e.country},
        {QStringLiteral("language"), e.language},
        {QStringLiteral("writer"), e.writer},
        {QStringLiteral("introStart"), e.introStart},
        {QStringLiteral("introEnd"), e.introEnd},
        {QStringLiteral("creditsStart"), e.creditsStart},
        {QStringLiteral("parent"), e.parent},
        {QStringLiteral("group"), e.group},
        {QStringLiteral("durationS"), e.durationS},
    };
}

static Library::Entry entryFromJson(const QJsonObject &o)
{
    Library::Entry e;
    e.title = o.value(QStringLiteral("title")).toString();
    e.subtitle = o.value(QStringLiteral("subtitle")).toString();
    const QJsonArray fl = o.value(QStringLiteral("flags")).toArray();
    for (const QJsonValue &v : fl)
        e.flags << v.toString();
    e.path = o.value(QStringLiteral("path")).toString();
    e.kind = o.value(QStringLiteral("kind")).toString();
    e.show = o.value(QStringLiteral("show")).toString();
    e.sortKey = o.value(QStringLiteral("sortKey")).toString();
    e.plot = o.value(QStringLiteral("plot")).toString();
    e.rating = o.value(QStringLiteral("rating")).toDouble();
    e.runtimeMin = o.value(QStringLiteral("runtimeMin")).toInt();
    e.genres = o.value(QStringLiteral("genres")).toString();
    e.poster = o.value(QStringLiteral("poster")).toString();
    e.fanart = o.value(QStringLiteral("fanart")).toString();
    e.clearlogo = o.value(QStringLiteral("clearlogo")).toString();
    e.year = o.value(QStringLiteral("year")).toInt();
    e.added = qint64(o.value(QStringLiteral("added")).toDouble());
    e.credits = o.value(QStringLiteral("credits")).toString();
    e.director = o.value(QStringLiteral("director")).toString();
    e.similar = o.value(QStringLiteral("similar")).toString();
    e.tmdbId = o.value(QStringLiteral("tmdbId")).toString();
    e.revenue = qint64(o.value(QStringLiteral("revenue")).toDouble());
    e.budget = qint64(o.value(QStringLiteral("budget")).toDouble());
    e.studio = o.value(QStringLiteral("studio")).toString();
    e.country = o.value(QStringLiteral("country")).toString();
    e.language = o.value(QStringLiteral("language")).toString();
    e.writer = o.value(QStringLiteral("writer")).toString();
    e.introStart = o.value(QStringLiteral("introStart")).toDouble();
    e.introEnd = o.value(QStringLiteral("introEnd")).toDouble();
    e.creditsStart = o.value(QStringLiteral("creditsStart")).toDouble();
    e.parent = o.value(QStringLiteral("parent")).toString();
    e.group = o.value(QStringLiteral("group")).toString();
    e.durationS = o.value(QStringLiteral("durationS")).toDouble();
    return e;
}

void Library::saveCache() const
{
    if (!m_manifestPath.isEmpty())
        return; // satellite streams its manifest; nothing to cache here
    const QString path = libraryCachePath();
    if (path.isEmpty())
        return;
    QJsonArray arr;
    for (const Entry &e : m_all)
        arr.append(entryToJson(e));
    QSaveFile f(path); // atomic: a crash mid-write can't leave a torn cache
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(arr).toJson(QJsonDocument::Compact));
        f.commit();
    }
}

QVector<Library::Entry> Library::loadCache() const
{
    QVector<Entry> out;
    const QString path = libraryCachePath();
    if (path.isEmpty())
        return out;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QJsonArray arr = QJsonDocument::fromJson(f.readAll()).array();
    out.reserve(arr.size());
    for (const QJsonValue &v : arr)
        out.append(entryFromJson(v.toObject()));
    return out;
}

void Library::warmStart()
{
    // Hub only, and only when we have nothing yet — never clobber a live set.
    if (!m_all.isEmpty() || !m_manifestPath.isEmpty())
        return;
    QVector<Entry> cached = loadCache();
    if (cached.isEmpty())
        return;
    std::sort(cached.begin(), cached.end(),
              [](const Entry &a, const Entry &b) { return a.sortKey < b.sortKey; });
    applyGuides(cached);
    applyArrivals(cached);
    beginResetModel();
    m_all = std::move(cached);
    m_newStale = true;
    // The extras index too (setEntries builds it from a scan): without it the
    // EXTRAS badges, the HAS EXTRAS filter and the BONUS count read empty until
    // the real scan landed — seconds on a cold ntfs3 drive.
    m_extrasByParent.clear();
    for (const Entry &e : m_all)
        if (e.kind == QLatin1String("extra") && !e.parent.isEmpty())
            m_extrasByParent[e.parent]++;
    applyFilter();
    endResetModel();
    ++m_scanRev;
    emit scanned(); // let the home rebuild from the cached set immediately
}

void Library::rescan()
{
    if (m_scanning)
        return;
    if (m_all.isEmpty())
        warmStart(); // paint a cached home instantly; the scan below reconciles it
    m_scanning = true;
    emit scanningChanged();
    auto *watcher = new QFutureWatcher<QVector<Entry>>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher] {
        // Local roots and a remote manifest COEXIST: a satellite (laptop)
        // carries its own media alongside the hub's streamed library.
        QVector<Entry> merged = watcher->result();
        if (!m_manifestPath.isEmpty())
            merged += loadManifest();
        std::sort(merged.begin(), merged.end(),
                  [](const Entry &a, const Entry &b) { return a.sortKey < b.sortKey; });
        setEntries(merged);
        rearmWatch(); // new folders since last scan start being watched
        watcher->deleteLater();
        m_scanning = false;
        emit scanningChanged();
    });
    m_scanFuture = QtConcurrent::run([this] { return scanRoots(); });
    watcher->setFuture(m_scanFuture);
}

void Library::setEntries(QVector<Entry> entries)
{
    m_watchStale = true;
    // Remote manifests already carry metadata; only the local scan needs the
    // DB join.
    const QHash<QString, QVariantMap> meta =
        (m_store && m_manifestPath.isEmpty()) ? m_store->allMetadata()
                                              : QHash<QString, QVariantMap>();
    // The join can rename a show ("Mr Robot" → "Mr. Robot", "Invincible" →
    // "INVINCIBLE") while its episodes still carry the parsed dir name; the
    // show page filters episodes by exact show string, so remap them below.
    QHash<QString, QString> showRenames;
    // Files with no metadata row = never scraped (dropped in since the last
    // TMDB run). Collected ONLY in local mode — a manifest satellite has an
    // empty meta map, so every item would look "new" and it has no key to
    // scrape with anyway. The controller fetches art for these.
    const bool localMode = (m_store && m_manifestPath.isEmpty());
    QStringList unscraped;
    QSet<QString> livePaths;
    for (Entry &e : entries) {
        if (localMode)
            livePaths.insert(e.path);
        const auto it = meta.constFind(e.path);
        if (it == meta.constEnd()) {
            // Extras (featurettes, kind "extra") are never scraped — codec_tmdb
            // skips them by design — so counting them as "new" re-ran the
            // reconcile job + a second full rescan on every launch.
            if (localMode && e.kind != QLatin1String("extra"))
                unscraped.append(e.path);
            continue;
        }
        const QVariantMap &m = *it;
        // The scraped TMDB year is the most authoritative source — apply it over
        // any name/container guess (the join previously dropped it on the floor).
        const int metaYear = m.value(QStringLiteral("year")).toInt();
        if (metaYear >= 1930 && metaYear <= 2049)
            e.year = metaYear;
        // An episode's OWN air year (its TMDB first-air date) — the subtitle was
        // the SHOW's, so every X-Files season read "1993". Mirrors
        // export_library.py so the laptop agrees.
        if (e.kind == QLatin1String("episode")) {
            const int epYear = m.value(QStringLiteral("premiered")).toString().left(4).toInt();
            if (epYear >= 1930 && epYear <= 2049) {
                e.year = epYear;
                e.subtitle = withYear(e.subtitle, epYear);
            }
        }
        const QString title = m.value(QStringLiteral("title")).toString();
        if (!title.isEmpty()) {
            if (e.kind == QLatin1String("movie")) {
                e.title = title;
                e.sortKey = title.toLower();
            } else if (e.kind == QLatin1String("episode")) {
                // "S01E01 · War's End"; a double episode's name without its "(1)"
                static const QRegularExpression twoPart(QStringLiteral("^S\\d+E\\d+-\\d+$"));
                e.title += QStringLiteral(" · ")
                    + (twoPart.match(e.title).hasMatch() ? withoutPartOne(title) : title);
            } else if (e.kind == QLatin1String("show")) {
                if (e.show != title)
                    showRenames.insert(e.show, title);
                e.title = title;
                e.show = title;
            }
        }
        e.plot = m.value(QStringLiteral("plot")).toString();
        e.rating = m.value(QStringLiteral("rating")).toDouble();
        e.runtimeMin = m.value(QStringLiteral("runtimeMin")).toInt();
        e.genres = m.value(QStringLiteral("genres")).toString();
        e.poster = m.value(QStringLiteral("poster")).toString();
        if (!e.poster.isEmpty() && !QFile::exists(e.poster))
            e.poster.clear();
        e.fanart = m.value(QStringLiteral("fanart")).toString();
        if (!e.fanart.isEmpty() && !QFile::exists(e.fanart))
            e.fanart.clear();
        e.clearlogo = m.value(QStringLiteral("clearlogo")).toString();
        if (!logoUsable(e.clearlogo)) // exists + real transparency, else text title
            e.clearlogo.clear();
        e.revenue = m.value(QStringLiteral("revenue")).toLongLong();
        e.budget = m.value(QStringLiteral("budget")).toLongLong();
        e.studio = m.value(QStringLiteral("studio")).toString();
        e.country = m.value(QStringLiteral("country")).toString();
        e.language = m.value(QStringLiteral("language")).toString();
        e.writer = m.value(QStringLiteral("writer")).toString();
        e.credits = m.value(QStringLiteral("credits")).toString();
        e.director = m.value(QStringLiteral("director")).toString();
        e.similar = m.value(QStringLiteral("similar")).toString();
        e.tmdbId = m.value(QStringLiteral("tmdbId")).toString();
    }
    if (!showRenames.isEmpty())
        for (Entry &e : entries)
            if (e.kind == QLatin1String("episode") && showRenames.contains(e.show))
                e.show = showRenames.value(e.show);

    // Episodes carry the SHOW's art, never their own. An episode's DB poster is a
    // per-episode still — or worse, stale by-title scrape data ("Bridge" matched
    // some random film "Bridge of ..."). detail() already resolves an episode to
    // its show, but the grid / continue-watching / search / episode rows render the
    // episode's own poster; inherit the show's here so EVERY view agrees. (an
    // episode should just show the TV show.) Runs after the rename pass so e.show
    // matches the show row's title.
    inheritShowArt(entries);

    // Bonus features follow their title: carry its FINAL name (the TMDB title,
    // not the folder's) for the player and the page header, and count them per
    // title for the EXTRAS badge, the BONUS plate and the HAS EXTRAS filter.
    // Keyed by path, so it holds on the laptop too (both sides are URLs there).
    {
        QHash<QString, QString> titleByPath;
        for (const Entry &e : entries)
            if (e.kind == QLatin1String("movie") || e.kind == QLatin1String("show"))
                titleByPath.insert(e.path, e.title);
        m_extrasByParent.clear();
        for (Entry &e : entries) {
            if (e.kind != QLatin1String("extra") || e.parent.isEmpty())
                continue;
            const auto it = titleByPath.constFind(e.parent);
            if (it == titleByPath.constEnd())
                continue;
            e.show = it.value();
            m_extrasByParent[e.parent]++;
        }
    }

    // Intros join separately: an episode can have a detected intro without a
    // metadata row, and the loop above skips entries the metadata join misses.
    if (m_store && m_manifestPath.isEmpty()) {
        const QHash<QString, QVariantMap> intros = m_store->allIntros();
        if (!intros.isEmpty()) {
            int joined = 0;
            for (Entry &e : entries) {
                const auto it = intros.constFind(e.path);
                if (it == intros.constEnd())
                    continue;
                e.introStart = it->value(QStringLiteral("start")).toDouble();
                e.introEnd = it->value(QStringLiteral("end")).toDouble();
                ++joined;
            }
            // Both sides key on the raw path; a count far below the table size
            // means the scanner and the detector disagree about path spelling.
            Logger::log(QStringLiteral("intro"),
                        QStringLiteral("joined %1 of %2 stored ranges")
                            .arg(joined).arg(intros.size()));
        }
        // End credits (codec_credits.py) join the same way — the UP NEXT trigger.
        const QHash<QString, double> credits = m_store->allCredits();
        for (Entry &e : entries)
            e.creditsStart = credits.value(e.path, 0.0);
    }
    // the shows' viewing guides (qrc) — the same join on both machines
    applyGuides(entries);
    applyArrivals(entries);   // the hub's ledger; a satellite's came in the manifest

    std::sort(entries.begin(), entries.end(),
              [](const Entry &a, const Entry &b) { return a.sortKey < b.sortKey; });

    beginResetModel();
    m_all = std::move(entries);
    m_newStale = true;
    applyFilter();
    endResetModel();
    ++m_scanRev;   // #45: mark this scan so the home view can skip a redundant walk
    emit scanned();

    m_unscraped = unscraped;
    // Orphans: metadata rows whose file is gone (deleted outside codec). Only
    // trusted when every root is intact — an unmounted drive makes the scan
    // return nothing for it, which would flag all its rows as orphaned.
    m_orphans.clear();
    if (localMode && rootsIntact())
        for (auto it = meta.constBegin(); it != meta.constEnd(); ++it)
            if (!livePaths.contains(it.key()))
                m_orphans.append(it.key());

    if (!m_unscraped.isEmpty() || !m_orphans.isEmpty())
        emit reconcileNeeded();

    // Refresh the warm-start cache from this scan (hub only) — but NEVER from a
    // degraded scan: if a root is unmounted (boot race / power-loss aftermath on
    // the ntfs3/exFAT drives) the scan returns a partial/empty set, and writing
    // that over the good cache would warm-start a blank home next launch.
    if (!m_all.isEmpty() && rootsIntact())
        saveCache();
    flushLogoVerdicts();
}

bool Library::rootsIntact() const
{
    // Every configured root must be present. A root with content is fine; an
    // EMPTY root is fine only if its drive is genuinely mounted (a legit empty
    // root like an unused TV dir) — empty AND not on a mount = a drive fell out.
    QFile cf(m_configPath.isEmpty()
                 ? QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                       + QStringLiteral("/codec/config.json")
                 : m_configPath);
    if (!cf.open(QIODevice::ReadOnly))
        return false;
    const QJsonArray roots =
        QJsonDocument::fromJson(cf.readAll()).object().value(QStringLiteral("roots")).toArray();
    for (const QJsonValue &v : roots) {
        const QString path = v.toObject().value(QStringLiteral("path")).toString();
        QDir d(path);
        if (!d.exists())
            return false;
        if (d.isEmpty(QDir::NoDotAndDotDot | QDir::AllEntries)) {
            const QStorageInfo si(path);
            if (!si.isValid() || !si.isReady() || si.rootPath() == QLatin1String("/"))
                return false;
        }
    }
    return true;
}

void Library::setQuery(const QString &q)
{
    if (q == m_query)
        return;
    m_query = q;
    beginResetModel();
    applyFilter();
    endResetModel();
    emit queryChanged();
}

// An episode's season, from its "S03E07 · …" title; -1 when it has no number.
static int seasonOf(const Library::Entry &e)
{
    static const QRegularExpression re(QStringLiteral("^S(\\d{1,3})E\\d+"));
    const auto m = re.match(e.title);
    return m.hasMatch() ? m.captured(1).toInt() : -1;
}

QString Library::seasonLabel(int season) const
{
    if (season < 0)
        return QStringLiteral("OTHER");
    if (season == 0)
        return QStringLiteral("SPECIALS");
    return QStringLiteral("SEASON %1").arg(season);
}

int Library::addHeading(const QString &label, const QString &count)
{
    m_headings.append(Heading{label, count});
    ++m_headerRows;
    return -m_headings.size();   // the row's marker: -(index + 1)
}

// An opened show's episodes, in season order, get a heading row before each
// season ("SEASON 3 // 22") — the BONUS FEATURES page's grouping, in the grid.
// Only when the rows ARE in season order (no search, title sort) and at least
// one episode is numbered; a heading in a rating-sorted list would lie.
void Library::insertSeasonHeaders()
{
    QHash<int, int> counts;
    bool numbered = false;
    for (const int idx : std::as_const(m_visible)) {
        const int s = seasonOf(m_all[idx]);
        counts[s]++;
        numbered = numbered || s >= 0;
    }
    if (!numbered)
        return;
    QVector<int> out;
    out.reserve(m_visible.size() + counts.size());
    int cur = -2;
    for (const int idx : std::as_const(m_visible)) {
        const int s = seasonOf(m_all[idx]);
        if (s != cur) {
            out.append(addHeading(seasonLabel(s), QString::number(counts.value(s))));
            cur = s;
        }
        out.append(idx);
    }
    m_visible = out;
}

void Library::applyFilter()
{
    m_visible.clear();
    const int prevHeaders = m_headerRows;
    m_headerRows = 0;
    m_headings.clear();

    // Section predicate: movies -> movie rows; tv -> show rows, or the
    // filtered show's episodes once one is opened. Genre narrows both.
    auto inSection = [this](const Entry &e) {
        // Episodes carry empty genres (the genre lives on the show), so a
        // lingering genre filter must NOT be applied to them — otherwise
        // drilling into a show while a genre is selected renders zero episodes.
        // Genre narrows movies + shows only.
        if (!m_genreFilter.isEmpty()
            && e.kind != QLatin1String("episode")
            && !e.genres.contains(m_genreFilter, Qt::CaseInsensitive))
            return false;
        // Format facet narrows every kind — unlike genre, shows AND episodes
        // carry the probed flags, so a DV filter holds when drilling into a show.
        // HAS EXTRAS is a fact about the TITLE, not the file: it narrows films
        // and shows, and a show's episodes pass so drilling in still works.
        if (m_flagFilter == QLatin1String("EXTRAS")) {
            if (e.kind != QLatin1String("episode") && !m_extrasByParent.contains(e.path))
                return false;
        } else if (!m_flagFilter.isEmpty() && !e.flags.contains(m_flagFilter)) {
            return false;
        }
        if (m_section == QLatin1String("tv")) {
            if (m_showFilter.isEmpty())
                return e.kind == QLatin1String("show");
            return e.kind == QLatin1String("episode") && e.show == m_showFilter;
        }
        return e.kind == QLatin1String("movie");
    };

    const QString q = m_query.trimmed().toLower();
    // An opened show cut the guide's way: its kept episodes, the film where
    // the guide puts it, a heading for each season and the film.
    if (q.isEmpty() && m_section == QLatin1String("tv") && !m_showFilter.isEmpty()
        && m_sortMode == QLatin1String("title") && !guideMode().isEmpty()) {
        if (const auto g = m_guides.constFind(m_showFilter); g != m_guides.constEnd()) {
            QVector<Heading> heads;
            m_visible = guideOrder(*g, guideMode(), &heads);
            if (!m_flagFilter.isEmpty() && m_flagFilter != QLatin1String("EXTRAS"))
                m_visible.removeIf([this](int v) {
                    return v >= 0 && !m_all[v].flags.contains(m_flagFilter);
                });
            m_headings = heads;
            m_headerRows = int(std::count_if(m_visible.cbegin(), m_visible.cend(),
                                             [](int v) { return v < 0; }));
            if (m_headerRows != prevHeaders)
                emit headerRowsChanged();
            return;
        }
    }
    if (q.isEmpty()) {
        m_visible.reserve(m_all.size());
        for (int i = 0; i < m_all.size(); ++i)
            if (inSection(m_all[i]))
                m_visible.append(i);
        // m_all is title-ordered; rating/year re-rank the visible slice.
        // (Search results stay relevance-ranked instead.)
        if (m_sortMode == QLatin1String("rating")) {
            std::stable_sort(m_visible.begin(), m_visible.end(),
                             [this](int a, int b) {
                                 return m_all[a].rating > m_all[b].rating;
                             });
        } else if (m_sortMode == QLatin1String("year")) {
            std::stable_sort(m_visible.begin(), m_visible.end(),
                             [this](int a, int b) {
                                 return m_all[a].year > m_all[b].year;
                             });
        }
        if (m_section == QLatin1String("tv") && !m_showFilter.isEmpty()
            && m_sortMode == QLatin1String("title"))
            insertSeasonHeaders();
        if (m_headerRows != prevHeaders)
            emit headerRowsChanged();
        return;
    }
    // Rank: prefix > substring > in-order subsequence.
    QVector<QPair<int, int>> ranked; // (rank, index)
    for (int i = 0; i < m_all.size(); ++i) {
        if (!inSection(m_all[i]))
            continue;
        const QString hay = (m_all[i].show.isEmpty() ? m_all[i].title
                                                     : m_all[i].show + QLatin1Char(' ')
                                    + m_all[i].title)
                                .toLower();
        int rank = -1;
        if (hay.startsWith(q)) {
            rank = 0;
        } else if (hay.contains(q)) {
            rank = 1;
        } else {
            qsizetype pos = 0;
            bool all = true;
            for (const QChar c : q) {
                pos = hay.indexOf(c, pos);
                if (pos < 0) {
                    all = false;
                    break;
                }
                ++pos;
            }
            if (all)
                rank = 2;
        }
        if (rank >= 0)
            ranked.append({rank, i});
    }
    std::stable_sort(ranked.begin(), ranked.end(),
                     [](const auto &a, const auto &b) { return a.first < b.first; });
    for (const auto &r : ranked)
        m_visible.append(r.second);
    if (m_headerRows != prevHeaders)
        emit headerRowsChanged();
}

int Library::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_visible.size();
}

QVariant Library::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_visible.size())
        return {};
    if (const int v = m_visible[index.row()]; v < 0) {
        // A heading row: its label and count, and typed blanks for everything
        // else (delegates declare these as required properties). Every
        // heading is kind "season": never selected.
        const Heading h = m_headings.value(-v - 1);
        switch (role) {
        case TitleRole: return h.label;
        case SubtitleRole: return h.count;
        case KindRole: return QStringLiteral("season");
        case ShowRole: return m_showFilter;
        case ResumePctRole: case RatingRole: return 0.0;
        case CompletedRole: return false;
        case RuntimeMinRole: case WatchCountRole: case YearRole: case ExtrasCountRole: return 0;
        case FlagsRole: return QStringList();
        default: return QString();
        }
    }
    const Entry &e = m_all[m_visible[index.row()]];
    switch (role) {
    case TitleRole:
        // a guide's film among an opened show's episodes, in the episode
        // grammar: "FILM · The X-Files"
        if (e.kind == QLatin1String("movie") && !m_showFilter.isEmpty())
            return QStringLiteral("FILM · ") + e.title;
        return e.title;
    case SubtitleRole:
        return e.subtitle;
    case PathRole:
        return e.path;
    case KindRole:
        return e.kind;
    case ShowRole:
        return e.show;
    case ResumePctRole:
        return watchFor(e.path).first;
    case CompletedRole:
        return watchFor(e.path).second;
    case PlotRole:
        return e.plot;
    case RatingRole:
        return e.rating;
    case RuntimeMinRole:
        return e.runtimeMin;
    case GenresRole:
        return e.genres;
    case PosterRole:
        return e.poster;
    case FanartRole:
        return e.fanart;
    case ClearLogoRole:
        return e.clearlogo;
    case FlagsRole:
        return e.flags;
    case WatchCountRole:
        return watchCountFor(e.path);
    case YearRole:               // #3: authoritative year for the grid plate
        return e.year;
    case ExtrasCountRole:
        return m_extrasByParent.value(e.path);
    case VerdictRole:
        return e.verdict;
    case IsNewRole:
        return isNew(e);
    default:
        return {};
    }
}

QHash<int, QByteArray> Library::roleNames() const
{
    return {
        {TitleRole, "title"},
        {SubtitleRole, "subtitle"},
        {PathRole, "path"},
        {KindRole, "kind"},
        {ShowRole, "show"},
        {ResumePctRole, "resumePct"},
        {CompletedRole, "completed"},
        {PlotRole, "plot"},
        {RatingRole, "rating"},
        {RuntimeMinRole, "runtimeMin"},
        {GenresRole, "genres"},
        {PosterRole, "poster"},
        {FanartRole, "fanart"},
        {ClearLogoRole, "clearlogo"},
        {FlagsRole, "flags"},
        {WatchCountRole, "watchCount"},
        {YearRole, "year"},
        {ExtrasCountRole, "extrasCount"},
        {VerdictRole, "verdict"},
        {IsNewRole, "isNew"},
    };
}

int Library::randomRow() const
{
    if (m_visible.isEmpty())
        return -1;
    const int r = QRandomGenerator::global()->bounded(m_visible.size());
    // a season heading is never a pick: take the episode under it
    return m_visible[r] < 0 && r + 1 < m_visible.size() ? r + 1 : r;
}

QString Library::pathAt(int row) const
{
    if (row < 0 || row >= m_visible.size() || m_visible[row] < 0)
        return {};   // a season heading has no file
    return m_all[m_visible[row]].path;
}

QPair<double, bool> Library::watchFor(const QString &path) const
{
    if (m_watchStale) {
        m_watch = m_store ? m_store->allWatchState()
                          : QHash<QString, QPair<double, bool>>();
        // Pull the completed-play COUNT in the same refresh (one extra query,
        // only when the table is dirty) so the browse hero can show "WATCHED ×N".
        m_watchCount.clear();
        if (m_store) {
            const auto agg = m_store->allWatchAgg();
            for (auto it = agg.constBegin(); it != agg.constEnd(); ++it)
                m_watchCount.insert(it.key(), it.value().count);
        }
        m_watchStale = false;
    }
    return m_watch.value(m_store ? m_store->mediaKey(path) : path,
                         {0.0, false});
}

int Library::watchCountFor(const QString &path) const
{
    watchFor(path); // ensures both caches are fresh (shared m_watchStale gate)
    return m_watchCount.value(m_store ? m_store->mediaKey(path) : path, 0);
}

void Library::refreshResume()
{
    m_watchStale = true; // next read re-pulls the table in one query
    m_newStale = true;   // starting a title takes its NEW away
    if (!m_visible.isEmpty())
        emit dataChanged(index(0), index(m_visible.size() - 1),
                         {ResumePctRole, CompletedRole, WatchCountRole, IsNewRole});
}

void Library::notifyResumeSynced()
{
    refreshResume();
    // `scanned` is what the home screen listens to when its derived rows may
    // have changed (StatsView too, guarded on visibility). A watch-state sync
    // is exactly that, so reuse it rather than thread a second signal through
    // the same wiring.
    ++m_scanRev;   // #45: mark this scan so the home view can skip a redundant walk
    emit scanned();
}

void Library::setSection(const QString &s)
{
    if (s == m_section)
        return;
    m_section = s;
    m_showFilter.clear();
    m_query.clear();
    beginResetModel();
    applyFilter();
    endResetModel();
    emit sectionChanged();
    emit queryChanged();
}

void Library::setShowFilter(const QString &s)
{
    if (s == m_showFilter)
        return;
    m_showFilter = s;
    m_query.clear();
    beginResetModel();
    applyFilter();
    endResetModel();
    emit sectionChanged();
    emit guideModeChanged();   // the mode is per show
    emit queryChanged();
}

void Library::setSortMode(const QString &m)
{
    if (m == m_sortMode)
        return;
    m_sortMode = m;
    beginResetModel();
    applyFilter();
    endResetModel();
    emit filtersChanged();
}

void Library::setGenreFilter(const QString &g)
{
    if (g == m_genreFilter)
        return;
    m_genreFilter = g;
    beginResetModel();
    applyFilter();
    endResetModel();
    emit filtersChanged();
}

void Library::setFlagFilter(const QString &f)
{
    if (f == m_flagFilter)
        return;
    m_flagFilter = f;
    beginResetModel();
    applyFilter();
    endResetModel();
    emit filtersChanged();
}

QStringList Library::availableFormats() const
{
    // Fixed display order; only the flags actually present in the library show
    // in the menu. Video tiers first, then object audio.
    static const QStringList order = {QStringLiteral("DV"), QStringLiteral("HDR10"),
                                      QStringLiteral("4K"), QStringLiteral("ATMOS")};
    QSet<QString> present;
    for (const Entry &e : m_all)
        for (const QString &f : e.flags)
            present.insert(f);
    QStringList out;
    for (const QString &f : order)
        if (present.contains(f))
            out << f;
    if (!m_extrasByParent.isEmpty())
        out << QStringLiteral("EXTRAS");
    return out;
}

QStringList Library::allGenres() const
{
    QSet<QString> seen;
    for (const Entry &e : m_all) {
        const QStringList parts = e.genres.split(QLatin1Char('/'), Qt::SkipEmptyParts);
        for (const QString &p : parts) {
            const QString g = p.trimmed();
            if (!g.isEmpty())
                seen.insert(g);
        }
    }
    QStringList out = seen.values();
    std::sort(out.begin(), out.end(), [](const QString &a, const QString &b) {
        return a.localeAwareCompare(b) < 0;
    });
    return out;
}

QVariantList Library::continueWatching(int limit) const
{
    QVariantList out;
    if (!m_store)
        return out;
    // Canonical watch-state keys -> library entries (both machines share the
    // keys, so this works on the hub and on satellites alike).
    QHash<QString, int> byKey;
    // Bonus features stay on their BONUS page (with their own resume bars) —
    // a half-watched featurette is not what Continue Watching is for.
    for (int i = 0; i < m_all.size(); ++i)
        if (m_all[i].kind != QLatin1String("show") && m_all[i].kind != QLatin1String("extra"))
            byKey.insert(m_store->mediaKey(m_all[i].path), i);
    // An episode's spotlight art/metadata lives on its SHOW row, not the episode
    // — so focusing an episode poster shows the series in the spotlight.
    QHash<QString, int> showByTitle;
    for (int i = 0; i < m_all.size(); ++i)
        if (m_all[i].kind == QLatin1String("show"))
            showByTitle.insert(m_all[i].title, i);
    // ONE card per show, decided by the show's MOST RECENTLY PLAYED episode
    // (rows arrive newest first) — watching out of order (a few X-Files here and
    // there) filled the row with identical posters. That episode unfinished →
    // resume it, however briefly it was played; finished → the next episode not
    // already watched (none left → no card). Only in-progress rows used to count
    // (past a minute, not finished), so a just-started or just-finished episode
    // didn't count and the card fell back to an OLDER half-watched one.
    // Films: in progress only. Fetch EVERYTHING (a thousand-odd small rows; the
    // loop stops at `limit` cards): a window of limit*12 rows meant a binge —
    // a couple of hundred episodes — pushed a half-watched film off the row.
    // YouTube rows (yt:<id>) are never library cards and stay out of it.
    QSet<QString> showsSeen;
    const QVariantList rows = m_store->recentlyPlayed(-1);
    for (const QVariant &v : rows) {
        const QVariantMap row = v.toMap();
        const auto it = byKey.constFind(row.value(QStringLiteral("key")).toString());
        if (it == byKey.constEnd())
            continue;
        const double pos = row.value(QStringLiteral("position")).toDouble();
        const double dur = row.value(QStringLiteral("duration")).toDouble();
        const bool unfinished = !row.value(QStringLiteral("completed")).toBool()
                                && dur > 0 && pos < dur * 0.9;
        int pick = *it;
        double pct = dur > 0 ? pos / dur : 0;
        if (m_all[pick].kind == QLatin1String("episode")) {
            const QString show = m_all[pick].show;
            if (showsSeen.contains(show))
                continue;
            showsSeen.insert(show);
            if (!unfinished) {
                // the next episode of this show you haven't finished
                int next = -1;
                for (int i = pick + 1; i < m_all.size() && next < 0; ++i)
                    if (m_all[i].kind == QLatin1String("episode") && m_all[i].show == show
                        && !m_store->isCompleted(m_all[i].path))
                        next = i;
                if (next < 0)
                    continue;
                pick = next;
                const QVariantMap st = m_store->state(m_all[pick].path);
                const double nd = st.value(QStringLiteral("duration")).toDouble();
                pct = nd > 0 ? st.value(QStringLiteral("position")).toDouble() / nd : 0;
            }
        } else if (!unfinished || pos <= 60) {
            continue;   // a film: in progress only
        }
        const Entry &e = m_all[pick];
        const Entry *hero = &e;
        if (e.kind == QLatin1String("episode")) {
            const auto sit = showByTitle.constFind(e.show);
            if (sit != showByTitle.constEnd())
                hero = &m_all[*sit];
        }
        out.append(QVariantMap{
            {QStringLiteral("title"),
             e.kind == QLatin1String("episode") && !e.title.startsWith(e.show)
                 ? e.show + QStringLiteral("  ") + e.title : e.title},
            {QStringLiteral("subtitle"), e.subtitle},
            {QStringLiteral("path"), e.path},
            {QStringLiteral("poster"), e.poster},
            {QStringLiteral("kind"), e.kind},
            {QStringLiteral("pct"), pct},
            // Hero = what the spotlight becomes when this poster is focused.
            {QStringLiteral("heroTitle"), hero->title},
            {QStringLiteral("flags"), hero->flags},
            {QStringLiteral("fanart"), hero->fanart},
            {QStringLiteral("clearlogo"), hero->clearlogo},
            {QStringLiteral("year"), hero->year},
            {QStringLiteral("genres"), hero->genres},
            {QStringLiteral("rating"), hero->rating},
            {QStringLiteral("runtimeMin"), hero->runtimeMin},
        });
        if (out.size() >= limit)
            break;
    }
    return out;
}

QVariantList Library::recentlyAdded(int limit) const
{
    // Newest files first, Netflix-style; a show appears once (its newest
    // episode). pct keeps the delegate shape shared with Continue Watching.
    QVector<const Entry *> pool;
    pool.reserve(m_all.size());
    for (const Entry &e : m_all)
        if (e.kind != QLatin1String("show") && e.kind != QLatin1String("extra")
            && e.added > 0)
            pool.append(&e);
    std::sort(pool.begin(), pool.end(),
              [](const Entry *a, const Entry *b) { return a->added > b->added; });
    QSet<QString> shows;
    QVariantList out;
    for (const Entry *e : pool) {
        if (e->kind == QLatin1String("episode")) {
            if (shows.contains(e->show))
                continue;
            shows.insert(e->show);
        }
        out.append(QVariantMap{
            {QStringLiteral("title"),
             e->kind == QLatin1String("episode") && !e->title.startsWith(e->show)
                 ? e->show + QStringLiteral("  ") + e->title : e->title},
            {QStringLiteral("subtitle"), e->subtitle},
            {QStringLiteral("path"), e->path},
            {QStringLiteral("poster"), e->poster},
            {QStringLiteral("kind"), e->kind},
            {QStringLiteral("pct"), 0.0},
        });
        if (out.size() >= limit)
            break;
    }
    return out;
}

QVariantList Library::topShows(int limit) const
{
    // TOP WATCHED, ranked by estimated total TIME watched (watch_count*duration +
    // current position, summed over a show's episodes). Time dissolves the ties that
    // raw counts produced; recency (last_played) breaks any remaining exact ties.
    // Labels are unchanged: shows show done/total, movies show ×N.
    QHash<QString, int> done, total;
    QHash<QString, QString> poster;
    QHash<QString, int> yearOf;
    QHash<QString, double> showSecs;    // per-show summed watch time
    QHash<QString, QString> showLast;   // per-show most-recent play
    const QHash<QString, ResumeStore::WatchAgg> agg =
        m_store ? m_store->allWatchAgg() : QHash<QString, ResumeStore::WatchAgg>();

    struct Ranked { double secs; QString last; QVariantMap data; };
    QList<Ranked> rows;

    for (const Entry &e : m_all) {
        if (e.kind == QLatin1String("show")) {
            poster.insert(e.title, e.poster);
            yearOf.insert(e.title, e.year);
        } else if (e.kind == QLatin1String("episode") && !e.show.isEmpty()) {
            total[e.show]++;
            const ResumeStore::WatchAgg a =
                agg.value(m_store ? m_store->mediaKey(e.path) : e.path);
            if (a.seconds > 0 || a.count > 0) {
                if (watchFor(e.path).second)
                    done[e.show]++;
                showSecs[e.show] += a.seconds;
                if (a.lastPlayed > showLast.value(e.show))
                    showLast[e.show] = a.lastPlayed;
            }
        } else if (e.kind == QLatin1String("movie")) {
            const ResumeStore::WatchAgg a =
                agg.value(m_store ? m_store->mediaKey(e.path) : e.path);
            if (a.count > 0) {   // a watched movie earns a TOP WATCHED slot
                rows.append({a.seconds, a.lastPlayed, QVariantMap{
                    {QStringLiteral("show"), e.title},
                    {QStringLiteral("kind"), QStringLiteral("movie")},
                    {QStringLiteral("count"), a.count},
                    {QStringLiteral("pct"), watchFor(e.path).first},
                    {QStringLiteral("done"), 0},
                    {QStringLiteral("total"), 0},
                    {QStringLiteral("poster"), e.poster},
                    {QStringLiteral("year"), e.year}}});
            }
        }
    }
    for (auto it = showSecs.constBegin(); it != showSecs.constEnd(); ++it) {
        if (it.value() <= 0)
            continue;
        rows.append({it.value(), showLast.value(it.key()), QVariantMap{
            {QStringLiteral("show"), it.key()},
            {QStringLiteral("kind"), QStringLiteral("show")},
            {QStringLiteral("done"), done.value(it.key())},
            {QStringLiteral("total"), total.value(it.key())},
            {QStringLiteral("poster"), poster.value(it.key())},
            {QStringLiteral("year"), yearOf.value(it.key())}}});
    }
    std::sort(rows.begin(), rows.end(),
              [](const Ranked &a, const Ranked &b) {
                  if (a.secs != b.secs)
                      return a.secs > b.secs;         // most total time watched
                  return a.last > b.last;             // ties → most recently played
              });
    QVariantList out;
    for (const Ranked &r : rows) {
        out.append(r.data);
        if (out.size() >= limit)
            break;
    }
    return out;
}

QVariantMap Library::weekActivity() const
{
    // Episodes + distinct titles played in the last 7 days. media_state stores
    // the canonical (serve-root-relative) key, so key the library the same way
    // to join; episodes collapse to their show, movies count as their title.
    QVariantMap out{{QStringLiteral("episodes"), 0}, {QStringLiteral("titles"), 0}};
    if (!m_store)
        return out;
    const QStringList keys = m_store->playsSince(7);
    if (keys.isEmpty())
        return out;
    QHash<QString, const Entry *> byKey;
    byKey.reserve(m_all.size());
    for (const Entry &e : m_all)
        byKey.insert(m_store->mediaKey(e.path), &e);
    int eps = 0;
    QSet<QString> titles;
    for (const QString &k : keys) {
        const auto it = byKey.constFind(k);
        if (it == byKey.constEnd())
            continue;
        const Entry *e = it.value();
        if (e->kind == QLatin1String("episode")) {
            ++eps;
            titles.insert(e->show);
        } else if (e->kind == QLatin1String("movie")) {
            titles.insert(e->title);   // a movie is a TITLE, not an episode
        }
    }
    out[QStringLiteral("episodes")] = eps;
    out[QStringLiteral("titles")] = titles.size();
    return out;
}

QVariantList Library::searchAll(const QString &q, int limit) const
{
    // Global fuzzy search across movies, shows and episodes: prefix beats
    // word-start beats substring; shows outrank their own episodes.
    QVariantList out;
    const QString needle = q.trimmed().toLower();
    if (needle.isEmpty())
        return out;
    struct Hit { int score; const Entry *e; };
    QVector<Hit> hits;
    for (const Entry &e : m_all) {
        if (e.kind == QLatin1String("extra"))
            continue;   // reached through their title's BONUS page
        const QString title = e.title.toLower();
        const QString show = e.show.toLower();
        int score = -1;
        if (title.startsWith(needle))
            score = 100;
        else if (title.contains(QStringLiteral(" ") + needle))
            score = 80;
        else if (title.contains(needle))
            score = 60;
        else if (!show.isEmpty() && show.contains(needle))
            score = 40; // episode reachable via its show's name
        if (score < 0)
            continue;
        if (e.kind == QLatin1String("show"))
            score += 15;
        else if (e.kind == QLatin1String("movie"))
            score += 10;
        hits.append({score, &e});
    }
    std::sort(hits.begin(), hits.end(), [](const Hit &a, const Hit &b) {
        if (a.score != b.score)
            return a.score > b.score;
        return a.e->title < b.e->title;
    });
    for (const Hit &h : hits) {
        const Entry &e = *h.e;
        out.append(QVariantMap{
            {QStringLiteral("title"), e.title},
            {QStringLiteral("subtitle"), e.subtitle},
            {QStringLiteral("path"), e.path},
            {QStringLiteral("kind"), e.kind},
            {QStringLiteral("show"), e.show},
            {QStringLiteral("poster"), e.poster},
        });
        if (out.size() >= limit)
            break;
    }
    return out;
}

QVariantList Library::spotlight(int limit) const
{
    // Hero pool: anything with a backdrop and a plot. Unwatched first so the
    // hero stays a discovery surface; order reshuffles every call.
    // New arrivals lead the loop — the room's first look at what just came in.
    QVector<const Entry *> arrived, fresh, seen;
    for (const Entry &e : m_all) {
        if (e.fanart.isEmpty() || e.plot.isEmpty())
            continue;
        if (e.kind != QLatin1String("movie") && e.kind != QLatin1String("show"))
            continue;
        if (isNew(e)) {
            arrived.append(&e);
            continue;
        }
        const auto w = watchFor(e.path);
        const bool watched = w.second || w.first > 0.9;
        (watched ? seen : fresh).append(&e);
    }
    std::shuffle(arrived.begin(), arrived.end(), *QRandomGenerator::global());
    std::shuffle(fresh.begin(), fresh.end(), *QRandomGenerator::global());
    std::shuffle(seen.begin(), seen.end(), *QRandomGenerator::global());
    fresh = arrived + fresh + seen;
    QVariantList out;
    for (const Entry *e : fresh) {
        out.append(QVariantMap{
            {QStringLiteral("title"), e->title},
            {QStringLiteral("subtitle"), e->subtitle},
            {QStringLiteral("flags"), e->flags},
            {QStringLiteral("path"), e->path},
            {QStringLiteral("kind"), e->kind},
            {QStringLiteral("show"), e->show},
            {QStringLiteral("fanart"), e->fanart},
            {QStringLiteral("clearlogo"), e->clearlogo},
            {QStringLiteral("poster"), e->poster},
            {QStringLiteral("plot"), e->plot},
            {QStringLiteral("rating"), e->rating},
            {QStringLiteral("runtimeMin"), e->runtimeMin},
            {QStringLiteral("genres"), e->genres},
            {QStringLiteral("year"), e->year},
            {QStringLiteral("isNew"), isNew(*e)},
        });
        if (out.size() >= limit)
            break;
    }
    return out;
}

QStringList Library::episodePaths(const QString &show) const
{
    // m_all is sortKey-ordered, which for episodes is show + S/E order.
    QStringList out;
    for (const Entry &e : m_all)
        if (e.kind == QLatin1String("episode") && e.show == show)
            out.append(e.path);
    return out;
}

QVariantList Library::bonusFeatures(const QString &parentPath) const
{
    QVector<const Entry *> rows;
    for (const Entry &e : m_all)
        if (e.kind == QLatin1String("extra") && e.parent == parentPath)
            rows.append(&e);
    // Numbers compare as numbers: "Deleted Scenes #2" before "#10", "Season 2"
    // before "Season 10" (the sort key zero-pads the season anyway).
    // Order: season, then the extras folder's own files, then each group A-Z
    // (a group before its own sub-groups: "Deleted Scenes" before "Deleted
    // Scenes / VHS Workprint"), then the file. Season and the own-files flag
    // are the "~SSSR" token extraSortKey writes; the rest compares by field.
    QCollator coll;
    coll.setNumericMode(true);
    coll.setCaseSensitivity(Qt::CaseInsensitive);
    static const QRegularExpression rankRe(QStringLiteral(" ~(\\d{4}) "));
    auto rank = [](const Entry *e) {
        const auto m = rankRe.match(e->sortKey);
        return m.hasMatch() ? m.captured(1) : QString();
    };
    std::sort(rows.begin(), rows.end(), [&](const Entry *a, const Entry *b) {
        const QString ra = rank(a), rb = rank(b);
        if (ra != rb)
            return ra < rb;
        if (const int g = coll.compare(a->group, b->group))
            return g < 0;
        return coll.compare(a->sortKey, b->sortKey) < 0;
    });
    QVariantList out;
    out.reserve(rows.size());
    for (const Entry *e : rows) {
        const auto w = watchFor(e->path);
        out.append(QVariantMap{
            {QStringLiteral("path"), e->path},
            {QStringLiteral("title"), e->title},
            {QStringLiteral("group"), e->group},
            {QStringLiteral("durationS"), e->durationS},
            {QStringLiteral("thumb"), e->poster},
            {QStringLiteral("pct"), w.first},
            {QStringLiteral("watched"), w.second},
        });
    }
    return out;
}

int Library::countOf(const QString &kind, const QString &show) const
{
    int n = 0;
    for (const Entry &e : m_all)
        n += e.kind == kind && (show.isEmpty() || e.show == show);
    return n;
}

QString Library::showLogo(const QString &show) const
{
    for (const Entry &e : m_all)
        if (e.kind == QLatin1String("show") && e.title == show)
            return e.clearlogo;
    return QString();
}

int Library::movieCount() const
{
    int n = 0;
    for (const Entry &e : m_all)
        n += e.kind == QLatin1String("movie");
    return n;
}

QStringList Library::moviePosters() const
{
    QStringList out;
    for (const Entry &e : m_all)
        if (e.kind == QLatin1String("movie") && !e.poster.isEmpty())
            out.append(e.poster);
    return out;
}

int Library::showCount() const
{
    int n = 0;
    for (const Entry &e : m_all)
        n += e.kind == QLatin1String("show");
    return n;
}

QString Library::kindAt(int row) const
{
    if (row < 0 || row >= m_visible.size())
        return {};
    if (m_visible[row] < 0)
        return QStringLiteral("season");
    return m_all[m_visible[row]].kind;
}

QString Library::titleAt(int row) const
{
    if (row < 0 || row >= m_visible.size())
        return {};
    if (m_visible[row] < 0)
        return m_headings.value(-m_visible[row] - 1).label;
    return m_all[m_visible[row]].title;
}

// #2: find an entry by its CANONICAL media key, not the raw string. On a ROAMING
// satellite the played path is the tailnet-reachable URL while entries store the
// LAN-baked URL, so a raw `==` misses — which silently broke next/prev-episode,
// skip-intro and the resume/party lookups away from home. mediaKey() strips the
// host/root so both forms collapse to one identity (empty store → raw compare).
int Library::entryIndexFor(const QString &path) const
{
    const QString key = m_store ? m_store->mediaKey(path) : path;
    for (int i = 0; i < m_all.size(); ++i)
        if ((m_store ? m_store->mediaKey(m_all[i].path) : m_all[i].path) == key)
            return i;
    return -1;
}

QVariantMap Library::introFor(const QString &path) const
{
    const int idx = entryIndexFor(path);
    if (idx < 0)
        return {};
    const Entry &e = m_all[idx];
    if (e.introEnd - e.introStart < 5)
        return {};
    return QVariantMap{{QStringLiteral("start"), e.introStart},
                       {QStringLiteral("end"), e.introEnd}};
}

double Library::creditsFor(const QString &path) const
{
    const int idx = entryIndexFor(path);
    return idx < 0 ? 0.0 : m_all[idx].creditsStart;
}

// What's playing, as a title: a bonus feature carries its film/show, since
// "01 Clarice Meets Lecter" alone says nothing on the OSD, the TV or a party.
static QString displayTitle(const Library::Entry &e)
{
    return e.kind == QLatin1String("extra") && !e.show.isEmpty()
        ? e.show + QStringLiteral(" / ") + e.title : e.title;
}

QVariantMap Library::entryInfo(const QString &path) const
{
    auto info = [this](const Entry &e) -> QVariantMap {
        return {{QStringLiteral("title"), displayTitle(e)},
                {QStringLiteral("show"), e.show},
                {QStringLiteral("kind"), e.kind},
                {QStringLiteral("subtitle"), e.subtitle},
                {QStringLiteral("poster"), e.poster},
                {QStringLiteral("year"), e.year}};
    };
    for (const Entry &e : m_all)
        if (e.path == path)
            return info(e);
    // A satellite's hub url can wear another host (the tailnet rewrite, a
    // queue item built while roaming): the same title by its path.
    if (path.contains(QLatin1String("://"))) {
        const QString key = manifestKey(path);
        for (const Entry &e : m_all)
            if (e.path.contains(QLatin1String("://")) && manifestKey(e.path) == key)
                return info(e);
    }
    return {};
}

QVariantMap Library::entryForKey(const QString &pathOrKey) const
{
    const int i = entryIndexFor(pathOrKey);   // canonical, roaming-safe
    if (i < 0)
        return {};
    const Entry &e = m_all[i];
    return {{QStringLiteral("path"), e.path},
            {QStringLiteral("kind"), e.kind},
            {QStringLiteral("title"), displayTitle(e)},
            {QStringLiteral("show"), e.show},
            {QStringLiteral("subtitle"), e.subtitle},
            {QStringLiteral("poster"), e.poster},
            // an episode's is its show's (setEntries hands it down)
            {QStringLiteral("clearlogo"), e.clearlogo},
            {QStringLiteral("year"), e.year}};
}

QVariantList Library::moreLikeThis(const Entry &page, int limit) const
{
    QVariantList out;
    QSet<QString> taken{page.path};

    auto card = [](const Entry &e, const QString &why) {
        return QVariantMap{
            {QStringLiteral("path"), e.path},
            {QStringLiteral("title"), e.title},
            {QStringLiteral("poster"), e.poster},
            {QStringLiteral("year"), e.year},
            {QStringLiteral("kind"), e.kind},
            {QStringLiteral("rating"), e.rating},
            {QStringLiteral("why"), why},
        };
    };
    auto browsable = [](const Entry &e) {
        return e.kind == QLatin1String("movie") || e.kind == QLatin1String("show");
    };

    // 1. TMDB recommendations, in TMDB's order, kept only if they're on our disks.
    const QStringList ids = page.similar.split(QLatin1Char(','), Qt::SkipEmptyParts);
    for (const QString &id : ids) {
        if (out.size() >= limit)
            break;
        for (const Entry &e : m_all) {
            if (!browsable(e) || taken.contains(e.path) || e.tmdbId != id)
                continue;
            taken.insert(e.path);
            out.append(card(e, QStringLiteral("RECOMMENDED")));
            break;
        }
    }
    if (out.size() >= limit)
        return out;

    // 2. Fill with shared genres — most genres in common first, then rating.
    // Split ONCE: begin()/end() taken from two separate temporaries are
    // iterators into different containers — UB, and it crashed on first use.
    const QStringList myGenres =
        page.genres.split(QStringLiteral(" / "), Qt::SkipEmptyParts);
    const QSet<QString> mine(myGenres.begin(), myGenres.end());
    if (mine.isEmpty())
        return out;
    QVector<QPair<int, const Entry *>> pool;
    for (const Entry &e : m_all) {
        if (!browsable(e) || taken.contains(e.path) || e.genres.isEmpty())
            continue;
        int shared = 0;
        for (const QString &g : e.genres.split(QStringLiteral(" / "), Qt::SkipEmptyParts))
            if (mine.contains(g))
                ++shared;
        if (shared > 0)
            pool.append({shared, &e});
    }
    std::sort(pool.begin(), pool.end(), [](const auto &a, const auto &b) {
        if (a.first != b.first)
            return a.first > b.first;            // more genres in common wins
        return a.second->rating > b.second->rating;
    });
    for (const auto &pr : pool) {
        if (out.size() >= limit)
            break;
        out.append(card(*pr.second, pr.second->genres.section(QStringLiteral(" / "), 0, 0).toUpper()));
    }
    return out;
}

QVariantMap Library::detail(const QString &path) const
{
    // Everything the full-bleed detail page needs in one call. An episode
    // path resolves to its SHOW's page with that episode preselected.
    const Entry *hit = nullptr;
    for (const Entry &e : m_all)
        if (e.path == path) { hit = &e; break; }
    if (!hit)
        return {};
    const Entry *page = hit;
    if (hit->kind == QLatin1String("episode")) {
        for (const Entry &e : m_all)
            if (e.kind == QLatin1String("show") && e.title == hit->show) {
                page = &e;
                break;
            }
    }
    QVariantMap out{
        {QStringLiteral("title"), page->title},
        {QStringLiteral("kind"), page->kind},
        {QStringLiteral("path"), page->path},
        {QStringLiteral("plot"), page->plot},
        {QStringLiteral("rating"), page->rating},
        {QStringLiteral("runtimeMin"), page->runtimeMin},
        {QStringLiteral("genres"), page->genres},
        {QStringLiteral("year"), page->year},
        {QStringLiteral("poster"), page->poster},
        {QStringLiteral("fanart"), page->fanart},
        {QStringLiteral("clearlogo"), page->clearlogo},
        {QStringLiteral("focusPath"), hit->path},
        {QStringLiteral("director"), page->director},
        {QStringLiteral("writer"), page->writer},
        {QStringLiteral("studio"), page->studio},
        {QStringLiteral("country"), page->country},
        {QStringLiteral("language"), page->language},
        {QStringLiteral("revenue"), QVariant::fromValue(page->revenue)},
        {QStringLiteral("budget"), QVariant::fromValue(page->budget)},
    };
    // Cast strip: "Name|Character;…" -> [{name, role}].
    QVariantList cast;
    const QStringList people = page->credits.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    for (const QString &p : people) {
        const int bar = p.indexOf(QLatin1Char('|'));
        const QString name = bar < 0 ? p : p.left(bar);
        if (name.isEmpty())
            continue;
        cast.append(QVariantMap{
            {QStringLiteral("name"), name},
            {QStringLiteral("role"), bar < 0 ? QString() : p.mid(bar + 1)}});
    }
    out.insert(QStringLiteral("cast"), cast);
    out.insert(QStringLiteral("moreLike"), moreLikeThis(*page, 12));
    out.insert(QStringLiteral("extrasCount"), m_extrasByParent.value(page->path));
    // Quality/HDR ride the FOCUSED file's subtitle ("4K · HDR · REMUX"), not
    // the show row — resolution is per-file. Split into a resolution token and
    // an HDR flag so the detail page can badge them.
    QString quality, res;
    bool hdr = false;
    const QStringList qtok = hit->subtitle.split(QStringLiteral(" · "), Qt::SkipEmptyParts);
    for (const QString &t : qtok) {
        if (t == QLatin1String("4K") || t.endsWith(QLatin1String("p")))
            res = t;
        else if (t == QLatin1String("HDR"))
            hdr = true;
    }
    out.insert(QStringLiteral("resolution"), res);
    out.insert(QStringLiteral("hdr"), hdr);
    out.insert(QStringLiteral("qualityLine"), hit->subtitle);
    // The FOCUSED file's truthful probe flags (["4K","DV","ATMOS"…] from
    // probeFlags — stream metadata, never the filename), the SAME array the grid
    // and hero spotlight badge from. The detail page's DV/ATMOS badges read this
    // instead of a filename regex on the path (which missed hidden-DV films).
    out.insert(QStringLiteral("flags"), hit->flags);
    if (page->kind != QLatin1String("show") && m_store) {
        const QVariantMap st = m_store->state(page->path);
        const double dur = st.value(QStringLiteral("duration")).toDouble();
        const double pos = st.value(QStringLiteral("position")).toDouble();
        out.insert(QStringLiteral("position"), pos);
        out.insert(QStringLiteral("duration"), dur);
        out.insert(QStringLiteral("pct"), dur > 0 ? qBound(0.0, pos / dur, 1.0) : 0.0);
        out.insert(QStringLiteral("watchCount"), st.value(QStringLiteral("watchCount"), 0));
        out.insert(QStringLiteral("watched"), m_store->isCompleted(page->path));
    }
    if (page->kind == QLatin1String("show")) {
        QVariantList eps;
        for (const Entry &e : m_all) {
            if (e.kind != QLatin1String("episode") || e.show != page->title)
                continue;
            const auto w = watchFor(e.path);
            const double pct = w.first;
            const bool watched = w.second;
            eps.append(QVariantMap{
                {QStringLiteral("path"), e.path},
                {QStringLiteral("title"), e.title},
                {QStringLiteral("subtitle"), e.subtitle},
                {QStringLiteral("watched"), watched},
                {QStringLiteral("pct"), pct},
                // the EPISODES list's section heading (same labels as the grid)
                {QStringLiteral("season"), seasonLabel(seasonOf(e))},
            });
        }
        out.insert(QStringLiteral("episodes"), eps);
    }
    return out;
}

QVariantMap Library::chainEntry(int idx) const
{
    const Entry &e = m_all[idx];
    // a guide's film in the chain reads as part of the show: "The X-Files
    // The Movie (1998)", not the show's name twice
    if (e.kind == QLatin1String("movie"))
        if (const Guide *g = guideFor(e)) {
            QString name = e.title == g->show ? QStringLiteral("The Movie") : e.title;
            if (name.startsWith(g->show + QStringLiteral(": ")))   // "...: I Want to Believe"
                name = name.mid(g->show.size() + 2);
            if (e.year > 0)
                name += QStringLiteral(" (%1)").arg(e.year);
            return {{QStringLiteral("path"), e.path},
                    {QStringLiteral("title"), name},
                    {QStringLiteral("show"), g->show}};
        }
    return {{QStringLiteral("path"), e.path},
            {QStringLiteral("title"), e.title},
            {QStringLiteral("show"), e.show}};
}

QVariantMap Library::nextEpisode(const QString &path) const
{
    const int idx = entryIndexFor(path);   // #2: canonical, roaming-safe
    if (idx < 0)
        return {};
    // A show cut the guide's way chains the guide's way: the next item the
    // cut keeps (the film where the guide puts it). An item the cut doesn't
    // keep (played by hand) still chains on from its place in the show.
    if (const Guide *g = guideFor(m_all[idx])) {
        const QString mode = m_guideModes.value(g->show);
        if (!mode.isEmpty()) {
            const QVector<int> all = guideOrder(*g, QString());
            const int p = all.indexOf(idx);
            if (p >= 0) {
                for (int i = p + 1; i < all.size(); ++i)
                    if (guideAccepts(mode, m_all[all[i]]))
                        return chainEntry(all[i]);
                return {};   // the end of the road
            }
        }
    }
    if (m_all[idx].kind != QLatin1String("episode"))
        return {};
    // Episodes of a show are contiguous in sortKey order within m_all.
    const QString show = m_all[idx].show;
    for (int i = idx + 1; i < m_all.size(); ++i) {
        const Entry &e = m_all[i];
        if (e.kind == QLatin1String("episode") && e.show == show)
            return chainEntry(i);
    }
    return {};
}

QVariantMap Library::prevEpisode(const QString &path) const
{
    const int idx = entryIndexFor(path);   // #2: canonical, roaming-safe
    if (idx < 0)
        return {};
    if (const Guide *g = guideFor(m_all[idx])) {
        const QString mode = m_guideModes.value(g->show);
        if (!mode.isEmpty()) {
            const QVector<int> all = guideOrder(*g, QString());
            const int p = all.indexOf(idx);
            if (p >= 0) {
                for (int i = p - 1; i >= 0; --i)
                    if (guideAccepts(mode, m_all[all[i]]))
                        return chainEntry(all[i]);
                return {};
            }
        }
    }
    if (m_all[idx].kind != QLatin1String("episode"))
        return {};
    const QString show = m_all[idx].show;
    for (int i = idx - 1; i >= 0; --i) {
        const Entry &e = m_all[i];
        if (e.kind == QLatin1String("episode") && e.show == show)
            return chainEntry(i);
    }
    return {};
}

// ── Viewing guides ─────────────────────────────────────────────────────────
// A guide is a fan's map of a show (assets/guides/<show>.json, written by
// scripts/codec_guide_import.py from the guide's own spreadsheet): in its
// order, the episodes it calls part of the STORY or TOP-tier, and the films
// it places between seasons. Shipped in the qrc, so the laptop joins it
// exactly as the hub does; nothing rides the manifest.

static int episodeOf(const Library::Entry &e)
{
    static const QRegularExpression re(QStringLiteral("^S\\d{1,3}E(\\d+)"));
    const auto m = re.match(e.title);
    return m.hasMatch() ? m.captured(1).toInt() : -1;
}

static QString guideModesPath()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return dir.isEmpty() ? QString() : dir + QStringLiteral("/guide-modes.json");
}

void Library::loadGuides()
{
    const QDir dir(QStringLiteral(":/guides"));
    const QStringList files = dir.entryList({QStringLiteral("*.json")}, QDir::Files);
    for (const QString &name : files) {
        QFile f(dir.filePath(name));
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
        Guide g;
        g.show = o.value(QStringLiteral("show")).toString();
        g.name = o.value(QStringLiteral("name")).toString();
        g.shortName = o.value(QStringLiteral("short")).toString();
        g.author = o.value(QStringLiteral("author")).toString();
        g.site = o.value(QStringLiteral("site")).toString();
        const QJsonArray secs = o.value(QStringLiteral("sections")).toArray();
        for (const QJsonValue &sv : secs) {
            const QJsonObject so = sv.toObject();
            GuideSection sec;
            sec.type = so.value(QStringLiteral("type")).toString();
            sec.season = so.value(QStringLiteral("season")).toInt(-1);
            sec.tmdbId = so.value(QStringLiteral("tmdbId")).toString();
            const QJsonArray items = so.value(QStringLiteral("items")).toArray();
            for (const QJsonValue &iv : items) {
                const QJsonObject io = iv.toObject();
                sec.items.append(GuideItem{io.value(QStringLiteral("verdict")).toString(),
                                           io.value(QStringLiteral("episode")).toInt(-1)});
            }
            g.sections.append(sec);
        }
        if (!g.show.isEmpty())
            m_guides.insert(g.show, g);
    }
    // the cut each show was last walked in
    QFile mf(guideModesPath());
    if (mf.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(mf.readAll()).object();
        for (auto it = o.constBegin(); it != o.constEnd(); ++it)
            if (m_guides.contains(it.key()) && it.value().toString() == QLatin1String("best"))
                m_guideModes.insert(it.key(), it.value().toString());
    }
}

void Library::saveGuideModes() const
{
    const QString path = guideModesPath();
    if (path.isEmpty())
        return;
    QJsonObject o;
    for (auto it = m_guideModes.constBegin(); it != m_guideModes.constEnd(); ++it)
        o.insert(it.key(), it.value());
    QSaveFile f(path);
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
        f.commit();
    }
}

// ── NEW ────────────────────────────────────────────────────────────────────
// When the torrent importer PLACED each title (arrivals.json, written by
// codec_qbit_import.py). File times can't say: the subtitle strip and the DV
// normalizer rewrite old files, and rsync keeps the download's own times. A
// key is the placed file or folder; anything at or under it arrived then. A
// satellite has no ledger — its manifest carries `arrived` (export_library.py
// applies the same rule).
void Library::applyArrivals(QVector<Entry> &entries) const
{
    QFile f(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
            + QStringLiteral("/arrivals.json"));
    if (!f.open(QIODevice::ReadOnly))
        return;
    const QJsonObject led = QJsonDocument::fromJson(f.readAll()).object();
    if (led.isEmpty())
        return;
    for (Entry &e : entries) {
        if (e.path.isEmpty() || e.kind == QLatin1String("show")
            || e.kind == QLatin1String("extra"))
            continue;
        for (auto it = led.constBegin(); it != led.constEnd(); ++it)
            if (e.path == it.key() || e.path.startsWith(it.key() + QLatin1Char('/')))
                e.arrived = qMax(e.arrived, qint64(it.value().toDouble()));
    }
}

// NEW for 14 days, or until it's started — whichever comes first.
bool Library::freshArrival(const Entry &e) const
{
    static constexpr qint64 kNewSecs = 14 * 24 * 3600;
    if (e.arrived <= 0 || QDateTime::currentSecsSinceEpoch() - e.arrived > kNewSecs)
        return false;
    const auto w = watchFor(e.path);
    return !w.second && w.first <= 0.0;
}

// A show is NEW while any episode that just arrived is still unstarted (a new
// season lights the show it joined).
bool Library::isNew(const Entry &e) const
{
    if (e.kind != QLatin1String("show"))
        return freshArrival(e);
    if (m_newStale) {
        m_newShows.clear();
        for (const Entry &x : m_all)
            if (x.kind == QLatin1String("episode") && x.arrived > 0 && freshArrival(x))
                m_newShows.insert(x.show);
        m_newStale = false;
    }
    return m_newShows.contains(e.show);
}

void Library::applyGuides(QVector<Entry> &entries) const
{
    if (m_guides.isEmpty())
        return;
    QHash<QString, QString> marks;   // show|season|episode, or "film|<tmdbId>" → verdict
    for (const Guide &g : m_guides)
        for (const GuideSection &sec : g.sections)
            for (const GuideItem &it : sec.items)
                marks.insert(sec.type == QLatin1String("movie")
                                 ? QStringLiteral("film|") + sec.tmdbId
                                 : QStringLiteral("%1|%2|%3").arg(g.show).arg(sec.season).arg(it.episode),
                             it.verdict);
    for (Entry &e : entries) {
        if (e.kind == QLatin1String("episode") && m_guides.contains(e.show))
            e.verdict = marks.value(QStringLiteral("%1|%2|%3").arg(e.show).arg(seasonOf(e)).arg(episodeOf(e)));
        else if (e.kind == QLatin1String("movie") && !e.tmdbId.isEmpty())
            e.verdict = marks.value(QStringLiteral("film|") + e.tmdbId);
        else
            e.verdict.clear();
    }
}

const Library::Guide *Library::guideFor(const Entry &e) const
{
    if (e.kind == QLatin1String("episode")) {
        const auto g = m_guides.constFind(e.show);
        return g == m_guides.constEnd() ? nullptr : &*g;
    }
    if (e.kind == QLatin1String("movie") && !e.tmdbId.isEmpty())
        for (const Guide &g : m_guides)
            for (const GuideSection &sec : g.sections)
                if (sec.type == QLatin1String("movie") && sec.tmdbId == e.tmdbId)
                    return &g;
    return nullptr;
}

// What each cut keeps. "" is every episode — the plain list, and the order
// the chain walks from (see nextEpisode). A film the guide places is always
// on the road (only guideOrder ever offers one).
bool Library::guideAccepts(const QString &mode, const Entry &e)
{
    if (e.kind == QLatin1String("movie"))
        return true;
    if (mode == QLatin1String("best"))      // the myth arc and the top-tier rest
        return e.verdict == QLatin1String("story") || e.verdict == QLatin1String("top");
    return true;
}

QVector<int> Library::guideOrder(const Guide &g, const QString &mode, QVector<Heading> *heads) const
{
    // the show's episodes by season, in library (sortKey) order, and the
    // films the guide places
    QSet<QString> placed;
    for (const GuideSection &sec : g.sections)
        if (sec.type == QLatin1String("movie"))
            placed.insert(sec.tmdbId);
    QMap<int, QVector<int>> bySeason;
    QHash<QString, int> filmIdx;
    for (int i = 0; i < m_all.size(); ++i) {
        const Entry &e = m_all[i];
        if (e.kind == QLatin1String("episode") && e.show == g.show)
            bySeason[seasonOf(e)].append(i);
        else if (e.kind == QLatin1String("movie") && placed.contains(e.tmdbId))
            filmIdx.insert(e.tmdbId, i);
    }
    QVector<int> out;
    auto season = [&](int s) {
        const QVector<int> eps = bySeason.take(s);
        QVector<int> kept;
        for (const int i : eps)
            if (guideAccepts(mode, m_all[i]))
                kept.append(i);
        if (kept.isEmpty())
            return;
        if (heads) {
            heads->append(Heading{seasonLabel(s), kept.size() == eps.size()
                                      ? QString::number(eps.size())
                                      : QStringLiteral("%1 OF %2").arg(kept.size()).arg(eps.size())});
            out.append(-heads->size());
        }
        out += kept;
    };
    // the guide's order: its seasons, a film where it puts one
    for (const GuideSection &sec : g.sections) {
        if (sec.type == QLatin1String("season")) {
            season(sec.season);
        } else if (sec.type == QLatin1String("movie")) {
            const int i = filmIdx.value(sec.tmdbId, -1);
            if (i < 0 || !guideAccepts(mode, m_all[i]))
                continue;
            if (heads) {
                heads->append(Heading{QStringLiteral("THE MOVIE"),
                                      m_all[i].year > 0 ? QString::number(m_all[i].year) : QString()});
                out.append(-heads->size());
            }
            out.append(i);
        }
    }
    // seasons the guide never names (specials, a later season) keep their place
    for (const int s : bySeason.keys())
        season(s);
    return out;
}

void Library::setGuideMode(const QString &mode)
{
    if (!m_guides.contains(m_showFilter) || mode == guideMode())
        return;
    if (mode.isEmpty())
        m_guideModes.remove(m_showFilter);
    else
        m_guideModes.insert(m_showFilter, mode);
    saveGuideModes();
    beginResetModel();
    applyFilter();
    endResetModel();
    emit guideModeChanged();
}

QVariantMap Library::guideInfo(const QString &show) const
{
    const auto g = m_guides.constFind(show.isEmpty() ? m_showFilter : show);
    if (g == m_guides.constEnd())
        return {};
    const QVector<int> all = guideOrder(*g, QString());
    const QList<QPair<QString, QString>> modes{
        {QString(), QStringLiteral("EVERY EPISODE")},
        {QStringLiteral("best"), QStringLiteral("MYTH + TOP")},
    };
    QVariantList ml;
    for (const auto &m : modes) {
        // episodes only: the films ride along under their own headings
        const int n = int(std::count_if(all.cbegin(), all.cend(), [&](int i) {
            return m_all[i].kind == QLatin1String("episode") && guideAccepts(m.first, m_all[i]);
        }));
        ml.append(QVariantMap{{QStringLiteral("mode"), m.first},
                              {QStringLiteral("label"), m.second},
                              {QStringLiteral("count"), n}});
    }
    return {{QStringLiteral("show"), g->show},
            {QStringLiteral("name"), g->name},
            {QStringLiteral("short"), g->shortName},
            {QStringLiteral("author"), g->author},
            {QStringLiteral("site"), g->site},
            {QStringLiteral("modes"), ml}};
}
