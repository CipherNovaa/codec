#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QStringList>
#include <QVariantMap>

// Per-file playback memory: position, tracks, speed, zoom — forever.
// SQLite at ~/.local/share/codec/codec.db.
class ResumeStore : public QObject
{
    Q_OBJECT

public:
    explicit ResumeStore(QObject *parent = nullptr);

    Q_INVOKABLE QVariantMap state(const QString &path) const;
    // Stats: watch-time accumulates per day (fed by play/cast ticks).
    void addWatchTime(double seconds);
    Q_INVOKABLE QVariantList watchDays(int days) const;
    Q_INVOKABLE QVariantMap statsSummary() const;
    Q_INVOKABLE double resumePct(const QString &path) const;
    Q_INVOKABLE bool isCompleted(const QString &path) const;
    // Whole media_state table in ONE query: canonical key -> (pct, completed).
    // Screens that annotate thousands of rows (stats, home, show pages) went
    // through the per-path calls above — two prepared queries per row was the
    // measured stats-screen freeze.
    QHash<QString, QPair<double, bool>> allWatchState() const;
    // Per-path aggregate for TOP WATCHED: times watched (×N), estimated total seconds
    // watched (watch_count*duration + current position), and last-played timestamp
    // (recency tie-break). One scan; summed per title in Library::topShows.
    struct WatchAgg { int count = 0; double seconds = 0.0; QString lastPlayed; };
    QHash<QString, WatchAgg> allWatchAgg() const;
    // Mid-watch rows (past the resume floor, short of the watched zone),
    // newest first: [{key, pct}] — feeds the home Continue Watching row.
    QVariantList inProgress(int limit) const;
    // The most recently played rows, FINISHED ones included (newest first):
    // {key, position, duration, completed}. Continue Watching decides a
    // show's card from its latest-touched episode, finished or not.
    QVariantList recentlyPlayed(int limit) const;
    // The single most-recently-played row REGARDLESS of `completed` — the seed
    // for the remote's hold-CAST "resume the last thing". inProgress() hides
    // finished rows on purpose (they've left Continue Watching), but a
    // just-finished episode is exactly what hold-CAST steps past, so this one
    // keeps them. -> {key, position, duration, completed}, or empty if nothing.
    Q_INVOKABLE QVariantMap lastTouched() const;
    // Canonical keys played within the last `days` (media_state.last_played) —
    // the raw list the library joins to count this-week episodes / titles.
    QStringList playsSince(int days) const;
    // Cheap "has anything been watched since last time?" signature: row count
    // and the newest last_played. Either moves whenever a watch is recorded or
    // a sync pulls one in.
    QString stateFingerprint() const;

    // Full metadata table (small): path -> {title, year, plot, rating, ...}.
    // Populated by scripts/kodi_import.py (and future scrapers).
    QHash<QString, QVariantMap> allMetadata() const;
    // Opening-title ranges: path -> {start, end} seconds. Keyed by raw path,
    // like metadata. Rows recording "no intro" are left out.
    QHash<QString, QVariantMap> allIntros() const;
    // path → where the end credits begin (codec_credits.py); found rows only
    QHash<QString, double> allCredits() const;

    void saveProgress(const QString &path, double position, double duration,
                      int aid, int sid, double speed, int zoomMode,
                      const QString &mode);
    void markCompleted(const QString &path);
    void saveSubDelay(const QString &path, double seconds);   // the X/C nudge, per film
    // Count a real play-start (STATS "PLAYS"), with a cooldown so stopping and
    // restarting the same title in quick succession doesn't inflate the number.
    void registerPlayStart(const QString &path);
    void clearWatched(const QString &path);

    // Canonical, device-independent media id: the path relative to the media
    // root (e.g. "Movies/UHD Media/Akira…/Akira….mkv"). Identical whether the
    // caller has a local /mnt path (desktop) or an http://…:8200 URL (laptop),
    // so watch state syncs across devices by this key.
    QString mediaKey(const QString &path) const;
    QString serveRoot() const { return m_serveRoot; }

signals:
    void updated();

private:
    QSqlDatabase m_db;
    QString m_serveRoot; // local prefix stripped to form the canonical key
};
