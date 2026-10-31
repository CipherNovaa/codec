#pragma once

#include <QHash>
#include <QAbstractListModel>
#include <QFileSystemWatcher>
#include <QFuture>
#include <QStorageInfo>
#include <QStringList>
#include <QTimer>
#include <QVector>

class ResumeStore;

// Scans configured media roots (config: ~/.config/codec/config.json),
// parses scene-style names into clean titles, and exposes a flat,
// fuzzy-filterable model. Fast and in-memory — a few hundred entries.
class Library : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
    Q_PROPERTY(QString section READ section WRITE setSection NOTIFY sectionChanged)
    Q_PROPERTY(QString showFilter READ showFilter WRITE setShowFilter NOTIFY sectionChanged)
    Q_PROPERTY(QString sortMode READ sortMode WRITE setSortMode NOTIFY filtersChanged)
    Q_PROPERTY(QString genreFilter READ genreFilter WRITE setGenreFilter NOTIFY filtersChanged)
    Q_PROPERTY(QString flagFilter READ flagFilter WRITE setFlagFilter NOTIFY filtersChanged)
    Q_PROPERTY(int totalCount READ totalCount NOTIFY scanned)
    // Season heading rows mixed into an opened show's episodes (kind "season");
    // views subtract this from the row count when they mean "episodes".
    Q_PROPERTY(int headerRows READ headerRows NOTIFY headerRowsChanged)
    Q_PROPERTY(int movieCount READ movieCount NOTIFY scanned)
    Q_PROPERTY(int showCount READ showCount NOTIFY scanned)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)
    // A viewing guide for the opened show (assets/guides/*.json — Andrew
    // Carl's X-Files roadmap is the first): guideMode "best" cuts the show to
    // its STORY (myth arc) and TOP episodes, "" is every episode. Remembered
    // per show; the episode chain (autoplay, UP NEXT, the remote's resume)
    // follows it.
    Q_PROPERTY(bool hasGuide READ hasGuide NOTIFY sectionChanged)
    Q_PROPERTY(QString guideMode READ guideMode WRITE setGuideMode NOTIFY guideModeChanged)

public:
    enum Roles {
        TitleRole = Qt::UserRole + 1,
        SubtitleRole,
        PathRole,
        KindRole,     // "movie" | "episode"
        ShowRole,
        ResumePctRole,
        CompletedRole,
        PlotRole,
        RatingRole,
        RuntimeMinRole,
        GenresRole,
        PosterRole,
        FanartRole,   // backdrop — the library grid paints it behind the wall
        ClearLogoRole,  // dynamic title art (fanart.tv) — replaces the text title
        FlagsRole,      // format flags ["4K","HDR","DV","ATMOS"…] for textured badges
        WatchCountRole, // times watched (completed plays) — for the "WATCHED ×N" badge
        YearRole,       // #3: authoritative release/first-air year (TMDB > tag > name),
                        // so the grid plate stops deriving it from the subtitle token
        ExtrasCountRole, // bonus features under this film/show — the EXTRAS badge
        VerdictRole,     // the show's guide on this episode: story | top ("" = neither)
        IsNewRole,       // arrived in the last 14 days and not started yet (NEW plate)
    };

    struct Entry {
        QString title;
        QString subtitle;
        // Media-flag chips (4K/HDR10/DV/ATMOS/…) derived from the file's OWN
        // embedded streams via ffprobe — never from the release name.
        QStringList flags;
        QString path;
        QString kind;
        QString show;
        QString sortKey;
        // Enriched from the metadata table when available.
        QString plot;
        double rating = 0;
        int runtimeMin = 0;
        QString genres;
        QString poster;
        QString fanart; // backdrop image — Spotlight hero
        QString clearlogo; // dynamic title art (fanart.tv) — replaces the text title
        int year = 0;
        qint64 added = 0; // file mtime (epoch s) — Recently Added row
        // When the torrent importer PLACED it (arrivals.json / the manifest's
        // `arrived`), epoch s; 0 = not known to have just arrived. The NEW mark.
        qint64 arrived = 0;
        // Detail-page extras (TMDB): "Name|Character;…", director/creator,
        // and recommended TMDB ids resolved against our OWN library.
        QString credits;
        QString director;
        QString similar;
        QString tmdbId;
        // Full-detail extras (TMDB): finances, studio, origin, language, writer.
        qint64 revenue = 0;
        qint64 budget = 0;
        QString studio;
        QString country;
        QString language;
        QString writer;
        // Opening titles, seconds (0/0 = none known). Detected offline by
        // scripts/codec_intro.py; arrives from the DB on the machine that holds
        // the media and from the manifest on the laptop.
        double introStart = 0;
        double introEnd = 0;
        double creditsStart = 0; // end credits begin here (s); 0 = unknown
        // Bonus features (kind "extra"): the path of the film's main video or
        // the show folder they belong to, their group on the BONUS FEATURES page
        // ("Deleted Scenes", "Season 3 / Featurettes") and their runtime.
        // Mirrored in export_library.py — see extraGroup in library.cpp.
        QString parent;
        QString group;
        double durationS = 0;
        // The show's viewing guide on this item (applyGuides; never cached or
        // exported — both machines join it from the qrc guide). A film the
        // guide places in the show (Fight the Future) is marked too.
        QString verdict;
    };

    explicit Library(ResumeStore *store, QObject *parent = nullptr);
    ~Library() override;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString query() const { return m_query; }
    void setQuery(const QString &q);
    QString section() const { return m_section; }
    void setSection(const QString &s);
    QString showFilter() const { return m_showFilter; }
    void setShowFilter(const QString &s);
    int totalCount() const { return m_all.size(); }
    int headerRows() const { return m_headerRows; }
    int movieCount() const;
    // How many entries of a kind ("movie", "show", "episode") — episodes of one
    // show when `show` is given. The library header's "23 OF 373 FILMS".
    Q_INVOKABLE int countOf(const QString &kind, const QString &show = QString()) const;
    // The show's clearlogo ("" if it has none) — the TV drill-in header shows it.
    Q_INVOKABLE QString showLogo(const QString &show) const;
    int showCount() const;
    bool scanning() const { return m_scanning; }
    // Manifest-fed satellite (laptop) vs local-roots hub (desktop).
    bool remoteMode() const { return !m_manifestPath.isEmpty(); }
    // a file suffix the scanner takes for video (mkv, mp4, m2ts, iso …)
    static bool isVideoSuffix(const QString &suffix);
    QString manifestPath() const { return m_manifestPath; }
    // A hub title's url → its position in the manifest (the index the hub's
    // browse surface resolves: /r/<tok>/…?i=), host-agnostic — a roaming app
    // rewrites the hub host before playing; the path is the identity. -1 if
    // the title isn't in the manifest.
    int manifestIndexOf(const QString &url) const;
    // The identity a manifest url matches on: its decoded PATH, host-agnostic.
    static QString manifestKey(const QString &url);

    Q_INVOKABLE void rescan();
    // Live disk watching: when on (AUTO-UPDATE = Live), a QFileSystemWatcher on
    // the roots + their immediate children fires a debounced rescan the moment
    // a file lands — no relaunch. Off tears the watches down.
    Q_INVOKABLE void setLiveWatch(bool on);
    Q_INVOKABLE int randomRow() const;
    Q_INVOKABLE QString pathAt(int row) const;
    Q_INVOKABLE QString kindAt(int row) const;
    Q_INVOKABLE QString titleAt(int row) const;
    Q_INVOKABLE void refreshResume();
    // A cross-device watch-state sync just landed. Recompute the grid's resume
    // bars AND tell the home screen to rebuild its Continue Watching row.
    void notifyResumeSynced();
    // Autoplay support: the episode that follows `path` within its show.
    Q_INVOKABLE QVariantMap nextEpisode(const QString &path) const;
    Q_INVOKABLE QVariantMap prevEpisode(const QString &path) const;
    Q_INVOKABLE QVariantMap entryInfo(const QString &path) const;
    // Like entryInfo, but resolves a CANONICAL watch-state key (or a full path)
    // through the roaming-safe index — so a media_state key round-trips to its
    // real, playable entry.path. Empty if the key isn't a library item (e.g. a
    // YouTube URL). Used by the remote's resume-last engine.
    Q_INVOKABLE QVariantMap entryForKey(const QString &pathOrKey) const;
    // {start,end} of this file's opening titles, or empty. Single source for
    // both machines: the local scan joins the intros table, the laptop's
    // manifest carries the numbers.
    QVariantMap introFor(const QString &path) const;
    // Where this file's end credits begin (s), or 0 — same two sources as introFor.
    double creditsFor(const QString &path) const;
    Q_INVOKABLE QVariantMap detail(const QString &path) const; // detail page
    // Library paths that had no metadata row on the last scan (newly-added
    // files). The controller scrapes art for any it hasn't already tried.
    QStringList unscrapedPaths() const { return m_unscraped; }
    // Metadata rows whose file is gone (deleted outside codec). Empty unless
    // every root is intact — see rootsIntact().
    QStringList orphanPaths() const { return m_orphans; }
    QString sortMode() const { return m_sortMode; }
    void setSortMode(const QString &m);
    QString genreFilter() const { return m_genreFilter; }
    void setGenreFilter(const QString &g);
    Q_INVOKABLE QStringList allGenres() const;
    // Format/quality facet filter (DV/HDR10/4K/ATMOS) — narrows the wall to
    // films whose probed flags contain it. Composes with the genre filter.
    // "EXTRAS" is the odd one out: titles that have bonus features.
    QString flagFilter() const { return m_flagFilter; }
    void setFlagFilter(const QString &f);
    // The format flags actually present in the library, in display order — the
    // FORMAT group of the (f) filter menu.
    Q_INVOKABLE QStringList availableFormats() const;
    // Home row: mid-watch items, newest first.
    Q_INVOKABLE QVariantList continueWatching(int limit) const;
    // Home row: newest files (one card per show).
    Q_INVOKABLE QVariantList recentlyAdded(int limit) const;
    // Every movie poster in library order — the film icon threads the
    // whole collection through its gate.
    Q_INVOKABLE QStringList moviePosters() const;
    // Home hero: random fanart-backed movies/shows, unwatched first.
    Q_INVOKABLE QVariantList spotlight(int limit) const;
    // #45: bumped once per completed scan so the home view can skip re-walking the
    // whole library (spotlight(100000)) on the GUI thread when nothing rescanned.
    Q_INVOKABLE int scanRevision() const { return m_scanRev; }
    Q_INVOKABLE QVariantList searchAll(const QString &q, int limit) const;
    Q_INVOKABLE QVariantList topShows(int limit) const; // by completed eps
    // {episodes, titles} watched in the last 7 days (media_state.last_played
    // joined to the library so shows collapse to one title).
    Q_INVOKABLE QVariantMap weekActivity() const;
    // Every episode file of a show, in watch order (bulk mark-watched).
    Q_INVOKABLE QStringList episodePaths(const QString &show) const;
    // The BONUS FEATURES page: every extra under a film (its main video's path)
    // or a show (its folder's path), in page order — season, the extras
    // folder's own files, then each sub-group, numbers compared as numbers.
    // Rows: {path, title, group, durationS, thumb, pct, watched}.
    Q_INVOKABLE QVariantList bonusFeatures(const QString &parentPath) const;

    bool hasGuide() const { return m_guides.contains(m_showFilter); }
    QString guideMode() const { return m_guideModes.value(m_showFilter); }
    void setGuideMode(const QString &mode);
    // The opened (or named) show's guide for the views: name, author, site,
    // and its modes as [{mode, label, count}] in menu order.
    Q_INVOKABLE QVariantMap guideInfo(const QString &show = QString()) const;

    // Exposed for the scanner; also useful to tests.
    static Entry parseName(const QString &rawName, const QString &kind,
                           const QString &show = {});
    // "Title (Year)" for any media path — raw filenames must never surface.
    Q_INVOKABLE static QString prettyTitle(const QString &path);

signals:
    void queryChanged();
    void sectionChanged();
    void filtersChanged();
    void headerRowsChanged();
    void guideModeChanged();
    void scanned();
    void scanningChanged();
    // A scan found the metadata out of step with disk (new files to scrape
    // and/or deleted files to prune) — the controller reconciles.
    void reconcileNeeded();

private:
    // Detail page "more like this": TMDB recommendations we ACTUALLY OWN come
    // first (a recommendation you can't play is just an advert), then same-genre
    // titles by rating to fill the row.
    QVariantList moreLikeThis(const Entry &page, int limit) const;
    void applyFilter();
    // Every configured root is present (mount-aware): guards orphan detection
    // against an unmounted drive flagging its whole subtree as deleted.
    bool rootsIntact() const;
    // Re-derive the dirs to watch after every scan: new movie/show folders start
    // being watched, pruned ones drop off. Bounded so a huge root can't exhaust
    // the inotify watch budget.
    void rearmWatch();
    void setEntries(QVector<Entry> entries);
    QVector<Entry> scanRoots() const;
    QVector<Entry> loadManifest() const;
    // Warm-start: cache the processed entry set after each local scan and paint
    // the home from it at launch, so it isn't empty until the first disk walk
    // finishes (seconds on cold NTFS). Hub (local) only; the real scan reconciles.
    void warmStart();
    void saveCache() const;
    QVector<Entry> loadCache() const;

    // Watch-state cache: one bulk SELECT instead of two prepared queries per
    // row (data(), topShows, spotlight, show pages — the stats freeze).
    // Invalidated by refreshResume() and every scan.
    QPair<double, bool> watchFor(const QString &path) const;
    int watchCountFor(const QString &path) const;   // times watched (completed)
    int entryIndexFor(const QString &path) const;   // #2: canonical (roaming-safe) lookup
    mutable QHash<QString, QPair<double, bool>> m_watch;
    mutable QHash<QString, int> m_watchCount;        // filled alongside m_watch
    mutable bool m_watchStale = true;

    ResumeStore *m_store;
    mutable QHash<QString, int> m_manifestIdx;   // manifestKey(url) → manifest position
    QVector<Entry> m_all;
    QVector<int> m_visible; // indices into m_all, filtered by section+query
    QString m_query;
    QString m_section = QStringLiteral("movies");
    QString m_showFilter;
    QString m_sortMode = QStringLiteral("title"); // title | rating | year
    QString m_genreFilter;
    QString m_flagFilter; // format facet: "DV" | "HDR10" | "4K" | "ATMOS" | "EXTRAS"
    QHash<QString, int> m_extrasByParent; // film/show path -> bonus feature count
    // Headings in an opened show: m_visible holds -(i + 1) for heading i —
    // a season ("SEASON 3" // "22"), or on a guide's cut a film it places.
    struct Heading {
        QString label;
        QString count;
    };
    QVector<Heading> m_headings;
    int m_headerRows = 0;
    void insertSeasonHeaders();
    int addHeading(const QString &label, const QString &count);
    QString seasonLabel(int season) const;

    // ── viewing guides ──
    struct GuideItem {
        QString verdict;    // story | top
        int episode = -1;
    };
    struct GuideSection {
        QString type;       // season | movie
        int season = -1;
        QString tmdbId;     // a movie section's film
        QVector<GuideItem> items;
    };
    struct Guide {
        QString show, name, shortName, author, site;
        QVector<GuideSection> sections;
    };
    QHash<QString, Guide> m_guides;          // by show title
    QHash<QString, QString> m_guideModes;    // show -> mode (guide-modes.json)
    void loadGuides();
    void saveGuideModes() const;
    void applyGuides(QVector<Entry> &entries) const;
    void applyArrivals(QVector<Entry> &entries) const;
    bool freshArrival(const Entry &e) const; // arrived lately, not started
    bool isNew(const Entry &e) const;        // …or, for a show, any of its episodes
    mutable QSet<QString> m_newShows;
    mutable bool m_newStale = true;
    const Guide *guideFor(const Entry &e) const;
    static bool guideAccepts(const QString &mode, const Entry &e);
    // the show's episodes (and the films the guide places) in the guide's
    // order, kept by `mode`. With `heads`, the opened show's rows: heading
    // markers -(k + 1) into *heads among the entry indices.
    QVector<int> guideOrder(const Guide &g, const QString &mode,
                            QVector<Heading> *heads = nullptr) const;
    QVariantMap chainEntry(int idx) const;   // nextEpisode()'s answer for m_all[idx]
    QString m_manifestPath; // non-empty = remote client mode (HTTP streaming)
    QString m_configPath;
    QStringList m_unscraped; // paths missing a metadata row (local mode only)
    QStringList m_orphans;   // metadata paths whose file is gone (guarded)
    bool m_scanning = false;
    int m_scanRev = 0;                    // #45: bumped per completed scan
    QFuture<QVector<Entry>> m_scanFuture; // held so ~Library can wait it out

    // Live-watch: roots + immediate children on a QFileSystemWatcher; a burst of
    // directoryChanged events (a copy in flight) coalesces through the debounce
    // before a single rescan runs.
    QFileSystemWatcher m_rootWatcher;
    QTimer m_watchDebounce;
    bool m_liveWatch = true;
};
