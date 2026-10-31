#include "resumestore.h"

#include <QDate>
#include <QDir>
#include <QThread>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>
#include <QUrlQuery>

ResumeStore::ResumeStore(QObject *parent)
    : QObject(parent)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("codec"));
    m_db.setDatabaseName(dir + QStringLiteral("/codec.db"));
    if (!m_db.open()) {
        qWarning("resume store: %s", qPrintable(m_db.lastError().text()));
        return;
    }
    QSqlQuery q(m_db);
    // WAL: this file is shared with codec-serve / the sync scripts; the
    // default DELETE journal made every writer exclusive, so a background
    // sync could hold the app's GUI-thread queries for the full 5s busy
    // timeout. WAL lets readers and one writer overlap (persists in-file).
    q.exec(QStringLiteral("PRAGMA journal_mode=WAL"));
    q.exec(QStringLiteral("PRAGMA synchronous=NORMAL"));
    q.exec(QStringLiteral("PRAGMA busy_timeout=2000"));
    q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS media_state ("
        " path TEXT PRIMARY KEY,"
        " position REAL DEFAULT 0,"
        " duration REAL DEFAULT 0,"
        " aid INTEGER DEFAULT -1,"
        " sid INTEGER DEFAULT -1,"
        " speed REAL DEFAULT 1.0,"
        " zoom_mode INTEGER DEFAULT -1,"
        " watch_count INTEGER DEFAULT 0,"
        " completed INTEGER DEFAULT 0,"
        " last_played TEXT)"));
    // Dev-era migration: older DBs lack last_mode (fails harmlessly if present).
    q.exec(QStringLiteral("ALTER TABLE media_state ADD COLUMN last_mode TEXT DEFAULT ''"));
    // Real play counter (STATS "PLAYS") + its cooldown timestamp. Seed play_count from
    // watch_count so the number continues from existing history instead of resetting to
    // zero; the guard makes the seed effectively one-time (rows keep play_count>0 after).
    q.exec(QStringLiteral("ALTER TABLE media_state ADD COLUMN play_count INTEGER DEFAULT 0"));
    q.exec(QStringLiteral("ALTER TABLE media_state ADD COLUMN last_play_at TEXT DEFAULT ''"));
    // The subtitle nudge (X/C) a film needed, remembered per film (v1.41).
    q.exec(QStringLiteral("ALTER TABLE media_state ADD COLUMN sub_delay REAL DEFAULT 0"));
    q.exec(QStringLiteral("UPDATE media_state SET play_count=watch_count"
                          " WHERE play_count=0 AND watch_count>0"));
    q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS watch_log ("
        " day TEXT PRIMARY KEY, seconds REAL DEFAULT 0)"));
    q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS metadata ("
        " path TEXT PRIMARY KEY, title TEXT, year INTEGER, plot TEXT,"
        " rating REAL, votes INTEGER, runtime_min INTEGER, genres TEXT,"
        " premiered TEXT, imdb_id TEXT, tmdb_id TEXT,"
        " poster TEXT, fanart TEXT, poster_url TEXT, fanart_url TEXT,"
        " clearlogo TEXT, clearlogo_url TEXT,"
        " revenue INTEGER, budget INTEGER, studio TEXT, country TEXT,"
        " language TEXT, writer TEXT,"
        " credits TEXT, director TEXT, similar TEXT,"
        " source TEXT, updated TEXT)"));
    // Opening-title ranges found by scripts/codec_intro.py (audio fingerprint).
    // A row with start==end==0 means "checked, no intro" — that is a result,
    // not a gap, and it keeps the detector from re-scanning the show.
    q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS intros ("
        " path TEXT PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL,"
        " method TEXT, updated TEXT)"));
    // Older databases predate the credits columns (note: `cast` is a reserved
    // SQL keyword — the column is `credits`).
    for (const QString &col : {QStringLiteral("credits"), QStringLiteral("director"),
                               QStringLiteral("similar"), QStringLiteral("clearlogo"),
                               QStringLiteral("clearlogo_url"), QStringLiteral("revenue"),
                               QStringLiteral("budget"), QStringLiteral("studio"),
                               QStringLiteral("country"), QStringLiteral("language"),
                               QStringLiteral("writer")}) {
        QSqlQuery chk(m_db);
        chk.exec(QStringLiteral("SELECT %1 FROM metadata LIMIT 1").arg(col));
        if (chk.lastError().isValid()) {
            // Match the CREATE affinity: revenue/budget are INTEGER there, so an
            // upgraded DB must not add them as TEXT (which sorts/compares as
            // strings — "9" > "1000000").
            const QString type = (col == QLatin1String("revenue")
                                  || col == QLatin1String("budget"))
                ? QStringLiteral("INTEGER") : QStringLiteral("TEXT");
            q.exec(QStringLiteral("ALTER TABLE metadata ADD COLUMN %1 %2")
                       .arg(col, type));
        }
    }

    // Media root to strip when forming canonical keys (matches codec-serve's
    // --dir). Configurable so a re-homed library keeps stable keys.
    m_serveRoot = QStringLiteral("/mnt");
    QFile cf(QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
             + QStringLiteral("/codec/config.json"));
    if (cf.open(QIODevice::ReadOnly)) {
        const QString sr = QJsonDocument::fromJson(cf.readAll())
                               .object().value(QStringLiteral("serveRoot")).toString();
        if (!sr.isEmpty())
            m_serveRoot = sr;
    }

    // One-time migration: rewrite legacy rows (keyed by full /mnt path or URL)
    // to canonical keys so this device's history joins the shared namespace.
    QSqlQuery sel(m_db);
    if (sel.exec(QStringLiteral("SELECT path FROM media_state"))) {
        QStringList olds;
        while (sel.next())
            olds << sel.value(0).toString();
        for (const QString &old : olds) {
            const QString key = mediaKey(old);
            if (key == old)
                continue;
            QSqlQuery up(m_db);
            up.prepare(QStringLiteral("UPDATE media_state SET path=? WHERE path=?"));
            up.addBindValue(key);
            up.addBindValue(old);
            if (!up.exec()) { // canonical row already exists — drop the legacy dup
                QSqlQuery del(m_db);
                del.prepare(QStringLiteral("DELETE FROM media_state WHERE path=?"));
                del.addBindValue(old);
                del.exec();
            }
        }
    }
}

void ResumeStore::addWatchTime(double seconds)
{
    if (!m_db.isOpen() || seconds <= 0)
        return;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral(
        "INSERT INTO watch_log (day, seconds) VALUES (date('now','localtime'), ?)"
        " ON CONFLICT(day) DO UPDATE SET seconds = seconds + excluded.seconds"));
    q.addBindValue(seconds);
    q.exec();
}

QVariantList ResumeStore::watchDays(int days) const
{
    // Last N days, oldest first, zero-filled — graph-ready.
    QVariantList out;
    QHash<QString, double> have;
    if (m_db.isOpen()) {
        QSqlQuery q(m_db);
        q.prepare(QStringLiteral(
            "SELECT day, seconds FROM watch_log"
            " WHERE day >= date('now','localtime', ?)"));
        q.addBindValue(QStringLiteral("-%1 days").arg(days - 1));
        q.exec();
        while (q.next())
            have.insert(q.value(0).toString(), q.value(1).toDouble());
    }
    const QDate today = QDate::currentDate();
    for (int i = days - 1; i >= 0; --i) {
        const QDate d = today.addDays(-i);
        const QString key = d.toString(QStringLiteral("yyyy-MM-dd"));
        out.append(QVariantMap{{QStringLiteral("day"), key},
                               {QStringLiteral("dow"), d.toString(QStringLiteral("ddd"))},
                               {QStringLiteral("seconds"), have.value(key, 0.0)}});
    }
    return out;
}

QVariantMap ResumeStore::statsSummary() const
{
    QVariantMap out{{QStringLiteral("totalHours"), 0.0},
                    {QStringLiteral("weekHours"), 0.0},
                    {QStringLiteral("daysWatched"), 0},
                    {QStringLiteral("completed"), 0},
                    {QStringLiteral("plays"), 0}};
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    if (q.exec(QStringLiteral("SELECT COALESCE(SUM(seconds),0), COUNT(*)"
                              " FROM watch_log")) && q.next()) {
        out[QStringLiteral("totalHours")] = q.value(0).toDouble() / 3600.0;
        out[QStringLiteral("daysWatched")] = q.value(1).toInt();
    }
    if (q.exec(QStringLiteral("SELECT COALESCE(SUM(seconds),0) FROM watch_log"
                              " WHERE day >= date('now','localtime','-6 days')"))
        && q.next())
        out[QStringLiteral("weekHours")] = q.value(0).toDouble() / 3600.0;
    if (q.exec(QStringLiteral("SELECT COUNT(*) FROM media_state WHERE completed=1"))
        && q.next())
        out[QStringLiteral("completed")] = q.value(0).toInt();
    // PLAYS = real play-starts (registerPlayStart), NOT gated on completion.
    if (q.exec(QStringLiteral("SELECT COALESCE(SUM(play_count),0) FROM media_state"))
        && q.next())
        out[QStringLiteral("plays")] = q.value(0).toInt();
    return out;
}

QStringList ResumeStore::playsSince(int days) const
{
    QStringList out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    // last_played is UTC ISO text (datetime('now')); compare in the same frame.
    q.prepare(QStringLiteral("SELECT path FROM media_state WHERE last_played != ''"
                             " AND last_played >= datetime('now', ?)"));
    q.addBindValue(QStringLiteral("-%1 days").arg(days));
    if (q.exec())
        while (q.next())
            out << q.value(0).toString();
    return out;
}

QString ResumeStore::mediaKey(const QString &path) const
{
    QString p = path;
    // YouTube plays by watch-URL; the canonical cross-device key is yt:<id>
    // (checked before the generic http branch, which would mangle it).
    if (p.contains(QLatin1String("youtube.com/watch"))) {
        const QString id = QUrlQuery(QUrl(p).query()).queryItemValue(QStringLiteral("v"));
        if (!id.isEmpty())
            return QStringLiteral("yt:") + id;
    }
    if (p.contains(QLatin1String("youtu.be/"))) {
        const QString id = QUrl(p).path().mid(1).section(QLatin1Char('/'), 0, 0);
        if (!id.isEmpty())
            return QStringLiteral("yt:") + id;
    }
    if (p.startsWith(QLatin1String("http://")) || p.startsWith(QLatin1String("https://"))) {
        const int schemeEnd = p.indexOf(QLatin1String("://")) + 3;
        const int slash = p.indexOf(QLatin1Char('/'), schemeEnd);
        p = slash >= 0 ? p.mid(slash + 1) : QString();
        p = QUrl::fromPercentEncoding(p.toUtf8());
    } else if (p.startsWith(m_serveRoot + QLatin1Char('/'))) {
        p = p.mid(m_serveRoot.length() + 1);
    }
    return p;
}

QHash<QString, QVariantMap> ResumeStore::allMetadata() const
{
    QHash<QString, QVariantMap> out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    q.exec(QStringLiteral("SELECT path, title, year, plot, rating, runtime_min,"
                          " genres, poster, fanart, credits, director, similar,"
                          " tmdb_id, clearlogo, revenue, budget, studio, country,"
                          " language, writer, premiered FROM metadata"));
    while (q.next()) {
        out.insert(q.value(0).toString(),
                   QVariantMap{
                       {QStringLiteral("title"), q.value(1).toString()},
                       {QStringLiteral("year"), q.value(2).toInt()},
                       {QStringLiteral("plot"), q.value(3).toString()},
                       {QStringLiteral("rating"), q.value(4).toDouble()},
                       {QStringLiteral("runtimeMin"), q.value(5).toInt()},
                       {QStringLiteral("genres"), q.value(6).toString()},
                       {QStringLiteral("poster"), q.value(7).toString()},
                       {QStringLiteral("fanart"), q.value(8).toString()},
                       {QStringLiteral("credits"), q.value(9).toString()},
                       {QStringLiteral("director"), q.value(10).toString()},
                       {QStringLiteral("similar"), q.value(11).toString()},
                       {QStringLiteral("tmdbId"), q.value(12).toString()},
                       {QStringLiteral("clearlogo"), q.value(13).toString()},
                       {QStringLiteral("revenue"), q.value(14).toLongLong()},
                       {QStringLiteral("budget"), q.value(15).toLongLong()},
                       {QStringLiteral("studio"), q.value(16).toString()},
                       {QStringLiteral("country"), q.value(17).toString()},
                       {QStringLiteral("language"), q.value(18).toString()},
                       {QStringLiteral("writer"), q.value(19).toString()},
                       {QStringLiteral("premiered"), q.value(20).toString()},
                   });
    }
    return out;
}

QHash<QString, QVariantMap> ResumeStore::allIntros() const
{
    QHash<QString, QVariantMap> out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    q.exec(QStringLiteral("SELECT path, start, end FROM intros WHERE end - start >= 5"));
    while (q.next()) {
        out.insert(q.value(0).toString(),
                   QVariantMap{{QStringLiteral("start"), q.value(1).toDouble()},
                               {QStringLiteral("end"), q.value(2).toDouble()}});
    }
    return out;
}

QHash<QString, double> ResumeStore::allCredits() const
{
    QHash<QString, double> out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    // A missing table (codec_credits.py never run) just fails the exec → empty.
    if (!q.exec(QStringLiteral("SELECT path, start FROM credits WHERE start > 0")))
        return out;
    while (q.next())
        out.insert(q.value(0).toString(), q.value(1).toDouble());
    return out;
}

QVariantMap ResumeStore::state(const QString &path) const
{
    QVariantMap out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral("SELECT position, duration, aid, sid, speed, zoom_mode,"
                             " watch_count, completed, last_mode, sub_delay"
                             " FROM media_state WHERE path = ?"));
    q.addBindValue(mediaKey(path));
    if (q.exec() && q.next()) {
        out.insert(QStringLiteral("position"), q.value(0).toDouble());
        out.insert(QStringLiteral("duration"), q.value(1).toDouble());
        out.insert(QStringLiteral("aid"), q.value(2).toInt());
        out.insert(QStringLiteral("sid"), q.value(3).toInt());
        out.insert(QStringLiteral("speed"), q.value(4).toDouble());
        out.insert(QStringLiteral("zoomMode"), q.value(5).toInt());
        out.insert(QStringLiteral("watchCount"), q.value(6).toInt());
        out.insert(QStringLiteral("completed"), q.value(7).toInt() != 0);
        out.insert(QStringLiteral("lastMode"), q.value(8).toString());
        out.insert(QStringLiteral("subDelay"), q.value(9).toDouble());
    }
    return out;
}

void ResumeStore::saveSubDelay(const QString &path, double seconds)
{
    if (!m_db.isOpen())
        return;
    QSqlQuery q(m_db);
    // a row of its own when the film has none yet (no position, no
    // last_played: it is not a watch)
    q.prepare(QStringLiteral(
        "INSERT INTO media_state (path, sub_delay) VALUES (?, ?)"
        " ON CONFLICT(path) DO UPDATE SET sub_delay=excluded.sub_delay"));
    q.addBindValue(mediaKey(path));
    q.addBindValue(seconds);
    q.exec();
}

double ResumeStore::resumePct(const QString &path) const
{
    const QVariantMap s = state(path);
    const double dur = s.value(QStringLiteral("duration")).toDouble();
    if (dur <= 0)
        return 0;
    return qBound(0.0, s.value(QStringLiteral("position")).toDouble() / dur, 1.0);
}

bool ResumeStore::isCompleted(const QString &path) const
{
    return state(path).value(QStringLiteral("completed")).toBool();
}

QHash<QString, QPair<double, bool>> ResumeStore::allWatchState() const
{
    QHash<QString, QPair<double, bool>> out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    if (!q.exec(QStringLiteral(
            "SELECT path, position, duration, completed FROM media_state")))
        return out;
    while (q.next()) {
        const double dur = q.value(2).toDouble();
        const double pct =
            dur > 0 ? qBound(0.0, q.value(1).toDouble() / dur, 1.0) : 0.0;
        out.insert(q.value(0).toString(), {pct, q.value(3).toInt() != 0});
    }
    return out;
}

QHash<QString, ResumeStore::WatchAgg> ResumeStore::allWatchAgg() const
{
    QHash<QString, WatchAgg> out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    // seconds = watch_count*duration + position → est. total time in the title
    // (N full watches + the current partial). Ties (rare) fall to last_played.
    if (!q.exec(QStringLiteral(
            "SELECT path, watch_count, watch_count*duration + position, last_played"
            " FROM media_state")))
        return out;
    while (q.next())
        out.insert(q.value(0).toString(),
                   WatchAgg{q.value(1).toInt(), q.value(2).toDouble(),
                            q.value(3).toString()});
    return out;
}

void ResumeStore::saveProgress(const QString &path, double position, double duration,
                               int aid, int sid, double speed, int zoomMode,
                               const QString &mode)
{
    if (!m_db.isOpen() || path.isEmpty())
        return;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral(
        "INSERT INTO media_state (path, position, duration, aid, sid, speed, zoom_mode,"
        " last_mode, last_played)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))"
        // Preserve per-file track/speed/zoom prefs when the write carries a
        // sentinel (aid/sid/zoom < 0, speed <= 0): the cast-status poll and the
        // TV->machine handoff save POSITION but pass placeholders for these, so
        // an unconditional overwrite wiped the audio/sub/speed/zoom the user set
        // during local playback. Only a write with a real value updates them.
        " ON CONFLICT(path) DO UPDATE SET position=excluded.position,"
        " duration=excluded.duration,"
        " aid=CASE WHEN excluded.aid<0 THEN media_state.aid ELSE excluded.aid END,"
        " sid=CASE WHEN excluded.sid<0 THEN media_state.sid ELSE excluded.sid END,"
        " speed=CASE WHEN excluded.speed<=0 THEN media_state.speed ELSE excluded.speed END,"
        " zoom_mode=CASE WHEN excluded.zoom_mode<0 THEN media_state.zoom_mode ELSE excluded.zoom_mode END,"
        " last_mode=excluded.last_mode, last_played=excluded.last_played,"
        // Watching a FINISHED title again: once it's genuinely under way (past a
        // minute, short of the 90% watched line) it's in progress again — the
        // stale flag kept a re-watch out of Continue Watching for good. The
        // watch count (the WATCHED ×N history) is untouched.
        " completed=CASE WHEN excluded.position>60 AND excluded.duration>0"
        "   AND excluded.position<excluded.duration*0.9 THEN 0 ELSE media_state.completed END"));
    q.addBindValue(mediaKey(path));
    q.addBindValue(position);
    q.addBindValue(duration);
    q.addBindValue(aid);
    q.addBindValue(sid);
    q.addBindValue(speed);
    q.addBindValue(zoomMode);
    q.addBindValue(mode);
    if (!q.exec()) {
        // The final save-on-quit can collide with codec_sync_state.py's write
        // and lose to the 2s busy timeout. That save is the one that matters
        // most (it banks where you stopped), so retry once before giving up.
        qWarning("resume store save: %s — retrying", qPrintable(q.lastError().text()));
        QThread::msleep(120);
        if (!q.exec())
            qWarning("resume store save (retry): %s", qPrintable(q.lastError().text()));
    }
    emit updated();
}

void ResumeStore::markCompleted(const QString &path)
{
    if (!m_db.isOpen() || path.isEmpty())
        return;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral(
        "INSERT INTO media_state (path, position, completed, watch_count, last_played)"
        " VALUES (?, 0, 1, 1, datetime('now'))"
        " ON CONFLICT(path) DO UPDATE SET position=0, completed=1,"
        " watch_count=media_state.watch_count+1, last_played=excluded.last_played"));
    q.addBindValue(mediaKey(path));
    q.exec();
    emit updated();
}

// A title re-counts as a new PLAY only after this cooldown, so stop/start churn
// (pausing, backing out, re-opening the same thing) doesn't inflate the number.
static constexpr int kPlayCooldownSecs = 3 * 3600;   // 3 hours

void ResumeStore::registerPlayStart(const QString &path)
{
    if (!m_db.isOpen() || path.isEmpty())
        return;
    QSqlQuery q(m_db);
    // New path → first play. Existing path → +1 only if the last counted play was
    // before now-cooldown (WHERE on the upsert skips the increment inside the window).
    q.prepare(QStringLiteral(
        "INSERT INTO media_state (path, play_count, last_play_at)"
        " VALUES (?, 1, datetime('now'))"
        " ON CONFLICT(path) DO UPDATE SET"
        " play_count = media_state.play_count + 1,"
        " last_play_at = datetime('now')"
        " WHERE media_state.last_play_at = ''"
        " OR media_state.last_play_at <= datetime('now', ?)"));
    q.addBindValue(mediaKey(path));
    q.addBindValue(QStringLiteral("-%1 seconds").arg(kPlayCooldownSecs));
    q.exec();
    emit updated();
}

QVariantList ResumeStore::inProgress(int limit) const
{
    QVariantList out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral(
        "SELECT path, position/duration FROM media_state"
        " WHERE completed=0 AND position>60 AND duration>0"
        " AND position < duration*0.9"
        " ORDER BY last_played DESC LIMIT ?"));
    q.addBindValue(limit);
    q.exec();
    while (q.next())
        out.append(QVariantMap{{QStringLiteral("key"), q.value(0).toString()},
                               {QStringLiteral("pct"), q.value(1).toDouble()}});
    return out;
}

QVariantList ResumeStore::recentlyPlayed(int limit) const
{
    QVariantList out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral(
        "SELECT path, position, duration, completed FROM media_state"
        " WHERE last_played != '' AND path NOT LIKE 'yt:%'"
        " ORDER BY last_played DESC LIMIT ?"));
    q.addBindValue(limit);   // -1 = all (SQLite)
    q.exec();
    while (q.next())
        out.append(QVariantMap{{QStringLiteral("key"), q.value(0).toString()},
                               {QStringLiteral("position"), q.value(1).toDouble()},
                               {QStringLiteral("duration"), q.value(2).toDouble()},
                               {QStringLiteral("completed"), q.value(3).toInt() != 0}});
    return out;
}

QVariantMap ResumeStore::lastTouched() const
{
    QVariantMap out;
    if (!m_db.isOpen())
        return out;
    QSqlQuery q(m_db);
    // No completed filter — the whole point is to catch the finished row that
    // inProgress() drops. last_played is ISO UTC text, so a string sort is
    // chronological.
    q.prepare(QStringLiteral(
        "SELECT path, position, duration, completed FROM media_state"
        " WHERE last_played != '' ORDER BY last_played DESC LIMIT 1"));
    if (q.exec() && q.next()) {
        out.insert(QStringLiteral("key"), q.value(0).toString());
        out.insert(QStringLiteral("position"), q.value(1).toDouble());
        out.insert(QStringLiteral("duration"), q.value(2).toDouble());
        out.insert(QStringLiteral("completed"), q.value(3).toInt() != 0);
    }
    return out;
}

QString ResumeStore::stateFingerprint() const
{
    if (!m_db.isOpen())
        return QString();
    QSqlQuery q(m_db);
    // COUNT catches a new row or a deletion; MAX(last_played) catches a
    // position change on an existing row (last_played is ISO text, so a plain
    // string MAX sorts chronologically).
    q.exec(QStringLiteral(
        "SELECT count(*), COALESCE(MAX(last_played),'') FROM media_state"));
    if (q.next())
        return q.value(0).toString() + QLatin1Char('|') + q.value(1).toString();
    return QString();
}

void ResumeStore::clearWatched(const QString &path)
{
    // "Mark unwatched": back to a fresh state — no tick, no resume point.
    if (!m_db.isOpen() || path.isEmpty())
        return;
    QSqlQuery q(m_db);
    // Truly fresh: also zero the counts, else a "mark unwatched" title still
    // carries its accumulated watch_count/play_count. (watch_count is max()'d on
    // sync, so the cluster copy can re-grow it — this at least resets locally.)
    q.prepare(QStringLiteral(
        "UPDATE media_state SET position=0, completed=0, watch_count=0,"
        " play_count=0, last_played=datetime('now') WHERE path=?"));
    q.addBindValue(mediaKey(path));
    q.exec();
    emit updated();
}
