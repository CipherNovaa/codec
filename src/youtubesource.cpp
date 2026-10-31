#include "youtubesource.h"
#include "scriptpath.h"

#include <QDir>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>
#include <QJsonArray>
#include <QSet>
#include <QTimer>
#include <algorithm>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>

YouTubeSource::YouTubeSource(QObject *parent)
    : QAbstractListModel(parent)
{
    loadRecent();
    loadSearches();
    loadPins();
}

static QString recentPath()
{
    return QDir::home().filePath(QStringLiteral(".cache/codec/yt-recent.json"));
}

static QString searchesPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
           + QStringLiteral("/yt-searches.json");
}

void YouTubeSource::loadSearches()
{
    QFile f(searchesPath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    for (const QJsonValue &v : QJsonDocument::fromJson(f.readAll()).array())
        if (!v.toString().isEmpty())
            m_searches.append(v.toString());
}

void YouTubeSource::saveSearches() const
{
    QDir().mkpath(QFileInfo(searchesPath()).absolutePath());
    QSaveFile f(searchesPath());
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.write(QJsonDocument(QJsonArray::fromStringList(m_searches)).toJson(QJsonDocument::Compact));
    f.commit();
}

static QString pinsPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
           + QStringLiteral("/yt-pins.json");
}

void YouTubeSource::loadPins()
{
    QFile f(pinsPath());
    if (f.open(QIODevice::ReadOnly))
        m_pins = QJsonDocument::fromJson(f.readAll()).array().toVariantList();
}

void YouTubeSource::savePins() const
{
    QDir().mkpath(QFileInfo(pinsPath()).absolutePath());
    QSaveFile f(pinsPath());
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.write(QJsonDocument(QJsonArray::fromVariantList(m_pins)).toJson(QJsonDocument::Compact));
    f.commit();
}

bool YouTubeSource::isPinned(const QString &url) const
{
    for (const QVariant &p : m_pins)
        if (p.toMap().value(QStringLiteral("url")).toString() == url)
            return true;
    return false;
}

void YouTubeSource::pin(const QString &url, const QString &title)
{
    if (url.isEmpty() || isPinned(url))
        return;
    m_pins.append(QVariantMap{{QStringLiteral("url"), url},
                              {QStringLiteral("title"), title.isEmpty() ? QStringLiteral("PLAYLIST") : title}});
    savePins();
    emit pinsChanged();
}

void YouTubeSource::unpin(const QString &url)
{
    for (int i = 0; i < m_pins.size(); ++i)
        if (m_pins[i].toMap().value(QStringLiteral("url")).toString() == url) {
            m_pins.removeAt(i);
            savePins();
            emit pinsChanged();
            return;
        }
}

void YouTubeSource::forgetSearch(const QString &query)
{
    if (m_searches.removeAll(query) > 0) {
        saveSearches();
        emit searchesChanged();
    }
}

void YouTubeSource::suggest(const QString &query)
{
    const QString q = query.trimmed();
    m_suggestFor = q;
    if (q.isEmpty()) {
        if (!m_suggestions.isEmpty()) {
            m_suggestions.clear();
            emit searchesChanged();
        }
        return;
    }
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("suggest"));
    send({{QStringLiteral("op"), QStringLiteral("suggest")}, {QStringLiteral("q"), q},
          {QStringLiteral("id"), id}});
}

void YouTubeSource::loadRecent()
{
    QFile f(recentPath());
    if (!f.open(QIODevice::ReadOnly))
        return;
    for (const QJsonValue &v : QJsonDocument::fromJson(f.readAll()).array()) {
        QVariantMap it = v.toObject().toVariantMap();
        it.remove(QStringLiteral("isLive"));   // see noteWatched
        m_recent.append(it);
    }
}

QString YouTubeSource::recentTitle(const QString &videoId) const
{
    for (const auto &r : m_recent)
        if (r.value(QStringLiteral("videoId")).toString() == videoId)
            return r.value(QStringLiteral("title")).toString();
    return {};
}

void YouTubeSource::noteWatched(const QVariantMap &item)
{
    const QString vid = item.value(QStringLiteral("videoId")).toString();
    if (vid.isEmpty())
        return;
    // codec's own HISTORY (and FOR YOU's seeds) keep it too, whichever way
    // YouTube is done here
    send({{QStringLiteral("op"), QStringLiteral("history_add")},
          {QStringLiteral("item"), item}, {QStringLiteral("id"), -12}});
    QVariantMap it = item;
    // Liveness is a fact about NOW, not about when it was played: a stream
    // watched live is a VOD the next day, and a frozen isLive replayed it down
    // the live lane from HISTORY for the whole 7-day window. A fresh listing
    // says whether it is live.
    it.remove(QStringLiteral("isLive"));
    it.insert(QStringLiteral("watchedAt"), QDateTime::currentSecsSinceEpoch());
    for (int i = m_recent.size() - 1; i >= 0; --i)
        if (m_recent[i].value(QStringLiteral("videoId")).toString() == vid)
            m_recent.removeAt(i);
    m_recent.prepend(it);
    while (m_recent.size() > 60)
        m_recent.removeLast();
    QJsonArray arr;
    for (const auto &r : m_recent)
        arr.append(QJsonObject::fromVariantMap(r));
    QDir().mkpath(QFileInfo(recentPath()).absolutePath());
    QFile f(recentPath() + QStringLiteral(".part"));
    if (f.open(QIODevice::WriteOnly)) {
        f.write(QJsonDocument(arr).toJson(QJsonDocument::Compact));
        f.close();
        QFile::remove(recentPath());
        f.rename(recentPath());
    }
}

QVector<QVariantMap> YouTubeSource::mergeRecent(QVector<QVariantMap> feed) const
{
    // Codec's own plays the account feed hasn't caught up with yet (not in its
    // first dozen rows) go on top, newest first; the feed's order stands for
    // everything YouTube already knows about.
    QSet<QString> head;
    for (int i = 0; i < feed.size() && i < 12; ++i)
        head.insert(feed[i].value(QStringLiteral("videoId")).toString());
    const qint64 cutoff = QDateTime::currentSecsSinceEpoch() - 7 * 86400;
    QVector<QVariantMap> out;
    for (const auto &r : m_recent) {
        if (r.value(QStringLiteral("watchedAt")).toLongLong() < cutoff)
            break;
        if (!head.contains(r.value(QStringLiteral("videoId")).toString()))
            out.append(r);
    }
    out += feed;
    return out;
}

int YouTubeSource::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_items.size();
}

QVariant YouTubeSource::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};
    const QVariantMap &it = m_items[index.row()];
    // Text roles default to "" — a row can be partial (codec's own recent plays
    // of a live stream keep only id/title/uri), and an invalid QVariant reaches
    // a `required property string` as the text "undefined".
    const auto str = [&it](const char *key) {
        return it.value(QLatin1String(key)).toString();
    };
    switch (role) {
    case TitleRole: return str("title");
    case SubtitleRole: return str("subtitle");
    case UriRole: return str("uri");
    case ArtUrlRole: {
        // no stored thumbnail: YouTube serves one for every id
        const QString art = str("artUrl"), id = str("videoId");
        return art.isEmpty() && !id.isEmpty()
                ? QStringLiteral("https://i.ytimg.com/vi/%1/mqdefault.jpg").arg(id) : art;
    }
    case DurationSRole: return it.value(QStringLiteral("durationS"), 0.0);
    case KindRole: return str("kind");
    case VideoIdRole: return str("videoId");
    case ChannelUrlRole: return str("channelUrl");
    case PublishedRole: return str("published");
    case IsLiveRole: return it.value(QStringLiteral("isLive"), false);
    case IsShortRole: return it.value(QStringLiteral("isShort"), false);
    }
    return {};
}

QHash<int, QByteArray> YouTubeSource::roleNames() const
{
    return {
        {TitleRole, "title"}, {SubtitleRole, "subtitle"}, {UriRole, "uri"},
        {ArtUrlRole, "artUrl"}, {DurationSRole, "durationS"},
        {KindRole, "kind"}, {VideoIdRole, "videoId"},
        {ChannelUrlRole, "channelUrl"}, {PublishedRole, "published"},
        {IsLiveRole, "isLive"}, {IsShortRole, "isShort"},
    };
}

QVariantMap YouTubeSource::itemAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items[row] : QVariantMap();
}

void YouTubeSource::ensureWorker()
{
    // Starting counts as alive: requests arrive in bursts (listing + prefetch),
    // and treating a still-starting worker as dead deleted it mid-launch —
    // "worker exited — retry" on the very first open. QProcess buffers writes
    // made while Starting and delivers them once the process is up.
    if (m_proc && m_proc->state() != QProcess::NotRunning)
        return;
    delete m_proc;
    m_proc = new QProcess(this);
    QString script = QProcessEnvironment::systemEnvironment()
                         .value(QStringLiteral("CODEC_YT_WORKER"));
    if (script.isEmpty())
        script = codecScript(QStringLiteral("codec_yt.py"));
    m_proc->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_proc, &QProcess::readyReadStandardOutput,
            this, &YouTubeSource::onReadyRead);
    connect(m_proc, &QProcess::finished, this, [this] {
        if (m_loading) {
            setError(QStringLiteral("worker exited — retry"));
            setLoading(false);
        }
        // Writes and the playlist picker wait on their own ids: answer them
        // too, or "FETCHING PLAYLISTS…" / a Watch Later add never resolves and
        // nobody can tell whether the write happened.
        if (!m_pendingActions.isEmpty() || m_playlistsReqId) {
            m_pendingActions.clear();
            m_playlistsReqId = 0;
            emit actionFailed(QStringLiteral("worker exited — retry"));
        }
        // and a video page waiting on its parts says so, not "loading" forever
        const auto pages = m_pageReqs;
        m_pageReqs.clear();
        for (const QString &kind : pages)
            emit pageReply(kind, {{QStringLiteral("ok"), false},
                                  {QStringLiteral("error"), QStringLiteral("worker exited — retry")}});
    });
    // System python on purpose (feedback: venv pythons miss system deps).
    m_proc->start(QStringLiteral("/usr/bin/python3"), {script});
}

void YouTubeSource::request(QVariantMap req)
{
    ensureWorker();
    m_forward.clear(); // new navigation; goBack/goForward restore it after
    m_current = req;
    emit listingChanged();
    m_appending = false;
    m_noMore = false;
    m_refreshLoops = 0;
    req.insert(QStringLiteral("id"), ++m_reqId);
    setError({});
    m_note.clear();
    setLoading(true);
    send(req);
}

void YouTubeSource::send(const QVariantMap &req)
{
    ensureWorker();
    m_proc->write(QJsonDocument(QJsonObject::fromVariantMap(req))
                      .toJson(QJsonDocument::Compact) + "\n");
}

void YouTubeSource::prefetchNext()
{
    // Warm the page AFTER the one just shown while it is being read, so
    // scrolling into it (key, remote or wheel) is a cache hit, not a wait.
    if (m_noMore || m_current.isEmpty())
        return;
    QVariantMap next = m_current;
    next.remove(QStringLiteral("id"));
    next.remove(QStringLiteral("fresh"));
    next.insert(QStringLiteral("start"), m_fetchOffset);
    send({{QStringLiteral("op"), QStringLiteral("prefetch")},
          {QStringLiteral("req"), next}});
}

void YouTubeSource::prewarm(const QStringList &tabs)
{
    // At most once per 4 min (the worker cache holds 5): every landing on the
    // YOUTUBE card otherwise re-ran three full yt-dlp extractions.
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_prewarmAt < 4 * 60 * 1000)
        return;
    m_prewarmAt = now;
    for (const QString &t : tabs)
        send({{QStringLiteral("op"), QStringLiteral("prefetch")},
              {QStringLiteral("req"), QVariantMap{
                   {QStringLiteral("op"), QStringLiteral("browse")},
                   {QStringLiteral("tab"), t}}}});
}

void YouTubeSource::watchPing(const QString &uri, double pos)
{
    // id -9: no listener — a failed ping must never toast mid-film.
    send({{QStringLiteral("op"), QStringLiteral("watch")},
          {QStringLiteral("uri"), uri},
          {QStringLiteral("pos"), qMax(0.0, pos)},
          {QStringLiteral("id"), -9}});
}

void YouTubeSource::refresh()
{
    if (m_current.isEmpty())
        return;
    QVariantMap req = m_current;
    req.remove(QStringLiteral("id"));
    req.remove(QStringLiteral("start"));
    req.insert(QStringLiteral("fresh"), true);
    request(req);
    m_current.remove(QStringLiteral("fresh")); // paging after a refresh may hit cache
}

void YouTubeSource::setFilters(const QVariantMap &f)
{
    if (f == m_filters)
        return;
    m_filters = f;
    emit filtersChanged();
    if (m_tab == QLatin1String("search") && !m_stack.size()
        && !m_current.value(QStringLiteral("q")).toString().isEmpty())
        search(m_current.value(QStringLiteral("q")).toString());
}

void YouTubeSource::setReversed(bool on)
{
    if (on == m_reversed)
        return;
    m_reversed = on;
    emit filtersChanged();
    // A page already on its way would land unreversed below the reversed
    // rows (fetchMore's guard only stops NEW sends): drop it.
    if (m_loading && m_appending) {
        ++m_reqId;
        m_appending = false;
        setLoading(false);
    }
    beginResetModel();
    std::reverse(m_items.begin(), m_items.end());
    endResetModel();
}

namespace {
// A channel page's url ends in the tab it lists: …/@name/videos,
// …/channel/UC…/playlists. Returns that tab, or "" for any other listing.
QString channelTabOf(const QString &url)
{
    const bool channel = url.contains(QLatin1String("/@")) || url.contains(QLatin1String("/channel/"))
                      || url.contains(QLatin1String("/c/")) || url.contains(QLatin1String("/user/"));
    if (!channel)
        return {};
    QString u = url;
    while (u.endsWith(QLatin1Char('/')))
        u.chop(1);
    for (const char *tab : {"videos", "playlists", "streams", "shorts"})
        if (u.endsWith(QLatin1Char('/') + QLatin1String(tab)))
            return QString::fromLatin1(tab);
    return {};
}
}

QString YouTubeSource::channelView() const
{
    return channelTabOf(m_current.value(QStringLiteral("url")).toString());
}

void YouTubeSource::setChannelView(const QString &view)
{
    const QString now = channelView();
    static const QStringList views{QStringLiteral("videos"), QStringLiteral("shorts"),
                                   QStringLiteral("streams"), QStringLiteral("playlists")};
    if (now.isEmpty() || view == now || !views.contains(view))
        return;
    QString url = m_current.value(QStringLiteral("url")).toString();
    while (url.endsWith(QLatin1Char('/')))
        url.chop(1);
    url.chop(now.size());
    url += view;
    if (m_reversed) { // ORDER is per listing
        m_reversed = false;
        emit filtersChanged();
    }
    request({{QStringLiteral("op"), QStringLiteral("browse")},
             {QStringLiteral("url"), url}});
}

void YouTubeSource::fetchMore()
{
    // Infinite scroll: repeat the current listing request further down the
    // feed and append. No-op while loading or when the feed is exhausted.
    if (m_loading || m_noMore || m_items.isEmpty() || m_current.isEmpty())
        return;
    // Reversed (ascending) order is over the rows already loaded; appending
    // the next page would put newer-than-the-end rows below older ones.
    if (m_reversed)
        return;
    QVariantMap req = m_current;
    req.insert(QStringLiteral("start"), m_fetchOffset);
    req.insert(QStringLiteral("id"), ++m_reqId);
    req.remove(QStringLiteral("fresh"));
    if (m_freshNext) {
        req.insert(QStringLiteral("fresh"), true);
        m_freshNext = false;
    }
    m_appending = true;
    setLoading(true);
    send(req);
}

void YouTubeSource::onReadyRead()
{
    while (m_proc->canReadLine()) {
        const QJsonObject obj = QJsonDocument::fromJson(m_proc->readLine()).object();
        if (obj.contains(QStringLiteral("event"))) {
            onEvent(obj);
            continue;
        }
        const qint64 id = obj.value(QStringLiteral("id")).toVariant().toLongLong();
        if (id == m_profilesReqId && m_profilesReqId != 0) {
            m_profilesReqId = 0;
            if (obj.value(QStringLiteral("ok")).toBool()) {
                m_profiles = obj.value(QStringLiteral("profiles")).toArray().toVariantList();
                m_takeout = obj.value(QStringLiteral("takeout")).toString();
            }
            emit profilesChanged();
            continue;
        }
        if (id == m_importReqId && m_importReqId != 0) {
            m_importReqId = 0;
            m_importStatus.clear();
            emit importChanged();
            if (obj.value(QStringLiteral("ok")).toBool()) {
                const QJsonObject a = obj.value(QStringLiteral("added")).toObject();
                emit actionDone(QStringLiteral("IMPORTED · %1 CHANNELS · %2 PLAYLISTS · %3 IN WATCH LATER")
                                    .arg(a.value(QStringLiteral("following")).toInt())
                                    .arg(a.value(QStringLiteral("playlists")).toInt())
                                    .arg(a.value(QStringLiteral("watchlater")).toInt()));
                refreshAccount();
                if (localMode() && m_stack.isEmpty() && m_tab != QLatin1String("search"))
                    refresh();
            } else {
                emit actionFailed(obj.value(QStringLiteral("error")).toString());
            }
            continue;
        }
        if (m_followActs.contains(id)) {
            const QString done = m_followActs.take(id);
            if (obj.value(QStringLiteral("ok")).toBool()) {
                setFollowing(obj.value(QStringLiteral("following")).toArray().isEmpty()
                                 ? obj.value(QStringLiteral("ids")).toArray()
                                 : obj.value(QStringLiteral("following")).toArray());
                if (!done.isEmpty())
                    emit actionDone(done);
            } else if (!done.isEmpty()) {
                emit actionFailed(obj.value(QStringLiteral("error")).toString());
            }
            continue;
        }
        if (m_createActs.contains(id)) {
            const QString done = m_createActs.take(id);
            if (obj.value(QStringLiteral("ok")).toBool()) {
                emit playlistCreated(obj.value(QStringLiteral("playlistId")).toString(),
                                     obj.value(QStringLiteral("title")).toString());
                emit actionDone(done);
            } else {
                emit actionFailed(obj.value(QStringLiteral("error")).toString());
            }
            continue;
        }
        if (m_pageReqs.contains(id)) {
            const QString kind = m_pageReqs.take(id);
            if (kind == QLatin1String("suggest")) {
                // only the newest question's answer (typing races its replies)
                if (obj.value(QStringLiteral("q")).toString() == m_suggestFor) {
                    m_suggestions.clear();
                    for (const QJsonValue &v : obj.value(QStringLiteral("suggestions")).toArray())
                        m_suggestions.append(v.toString());
                    emit searchesChanged();
                }
                continue;
            }
            // a batch (un)subscribe brings the list it leaves behind
            if (kind == QLatin1String("batch") && obj.contains(QStringLiteral("following")))
                setFollowing(obj.value(QStringLiteral("following")).toArray());
            emit pageReply(kind, obj.toVariantMap());
            continue;
        }
        if (obj.contains(QStringLiteral("description"))) {
            const QString vid = obj.value(QStringLiteral("videoId")).toString();
            // a row past a feed's first page has no date; its describe brings one
            const QString published = obj.value(QStringLiteral("published")).toString();
            if (!published.isEmpty())
                for (int i = 0; i < m_items.size(); ++i)
                    if (m_items[i].value(QStringLiteral("videoId")).toString() == vid
                        && m_items[i].value(QStringLiteral("published")).toString().isEmpty()) {
                        m_items[i].insert(QStringLiteral("published"), published);
                        emit dataChanged(index(i), index(i), {PublishedRole});
                    }
            emit described(vid, obj.value(QStringLiteral("description")).toString());
            continue;
        }
        // Background action replies (WL/playlist writes, playlist listing).
        if (m_pendingActions.contains(id)) {
            const QString done = m_pendingActions.take(id);
            if (obj.value(QStringLiteral("ok")).toBool()) {
                if (!done.isEmpty())
                    emit actionDone(done);
            } else {
                emit actionFailed(obj.value(QStringLiteral("error")).toString());
            }
            continue;
        }
        if (obj.contains(QStringLiteral("account")) && obj.value(QStringLiteral("ok")).toBool()) {
            setAccount(obj.value(QStringLiteral("account")).toObject().toVariantMap());
            continue;
        }
        if (id == m_playlistsReqId && m_playlistsReqId != 0) {
            m_playlistsReqId = 0;
            if (obj.value(QStringLiteral("ok")).toBool())
                emit playlistsReady(obj.value(QStringLiteral("playlists"))
                                        .toArray().toVariantList());
            else
                emit actionFailed(obj.value(QStringLiteral("error")).toString());
            continue;
        }
        if (id != m_reqId)
            continue; // stale reply for a superseded request
        setLoading(false);
        if (!obj.value(QStringLiteral("ok")).toBool()) {
            setError(obj.value(QStringLiteral("error")).toString(),
                     obj.value(QStringLiteral("auth")).toString());
            continue;
        }
        if (!m_appending) {
            const QString note = obj.value(QStringLiteral("note")).toString();
            const QVariantMap header = obj.value(QStringLiteral("header")).toObject().toVariantMap();
            if (note != m_note || header != m_header) {
                m_note = note;
                m_header = header;
                emit listingChanged();
            }
        }
        QVector<QVariantMap> entries;
        const QJsonArray arr = obj.value(QStringLiteral("entries")).toArray();
        entries.reserve(arr.size());
        for (const QJsonValue &v : arr)
            entries.append(v.toObject().toVariantMap());
        if (m_appending) {
            m_appending = false;
            m_fetchOffset += entries.size();
            // Recommendation pages overlap — the same video must never
            // appear twice in one listing.
            QSet<QString> seen;
            for (const auto &it : m_items)
                seen.insert(it.value(QStringLiteral("videoId")).toString());
            QVector<QVariantMap> fresh;
            for (auto &e : entries) {
                const QString v = e.value(QStringLiteral("videoId")).toString();
                if (v.isEmpty() || !seen.contains(v)) {
                    seen.insert(v);
                    fresh.append(std::move(e));
                }
            }
            if (!fresh.isEmpty()) {
                m_refreshLoops = 0;
                beginInsertRows({}, m_items.size(),
                                m_items.size() + fresh.size() - 1);
                m_items += fresh;
                endInsertRows();
            }
            // The worker says whether the feed goes on ("more"); older
            // replies without it fall back to the short-page heuristic.
            const bool ended = obj.contains(QStringLiteral("more"))
                ? !obj.value(QStringLiteral("more")).toBool()
                : entries.size() < 20;
            if (ended || fresh.isEmpty()) {
                // For You never truly ends, and its pages have HOLES: offset
                // 40 can come back empty while 80 and 120 are full (measured
                // 2026-10-04). An empty page skips ahead past the hole; a page
                // of pure repeats restarts the cursor (recs are re-drawn every
                // pull). Four dry pulls in a row = actually done. Either way
                // the next pull fires now — at the end of the list nothing
                // else would trigger it.
                if (m_current.value(QStringLiteral("tab")) == QLatin1String("rec")
                    && ++m_refreshLoops <= 4) {
                    if (entries.isEmpty())
                        m_fetchOffset += 40;
                    else
                        m_fetchOffset = 0;
                    // A re-draw must reach YouTube: offset 0 is the cached
                    // first page (prewarm filled it), which would just be
                    // the same repeats four times over.
                    m_freshNext = true;
                    QTimer::singleShot(0, this, &YouTubeSource::fetchMore);
                } else {
                    m_noMore = true;
                }
            }
            prefetchNext();
            continue;
        }
        m_fetchOffset = entries.size();
        m_refreshLoops = 0;
        // For You never truly ends (the append path re-pulls fresh recs), so
        // its first page must never park the feed.
        if (obj.contains(QStringLiteral("more")) && !obj.value(QStringLiteral("more")).toBool()
            && m_current.value(QStringLiteral("tab")) != QLatin1String("rec"))
            m_noMore = true;
        // (codec's own HISTORY is codec's plays already)
        if (m_stack.isEmpty() && !localMode()
            && m_current.value(QStringLiteral("tab")) == QLatin1String("history"))
            entries = mergeRecent(std::move(entries));
        setEntries(std::move(entries), obj.value(QStringLiteral("context")).toString());
        prefetchNext();
    }
}

void YouTubeSource::setEntries(QVector<QVariantMap> entries, const QString &context)
{
    // One page can itself repeat a video (mixes + recs) — first one wins.
    QSet<QString> seen;
    QVector<QVariantMap> uniq;
    uniq.reserve(entries.size());
    for (auto &e : entries) {
        const QString v = e.value(QStringLiteral("videoId")).toString();
        if (v.isEmpty() || !seen.contains(v)) {
            seen.insert(v);
            uniq.append(std::move(e));
        }
    }
    if (m_reversed)
        std::reverse(uniq.begin(), uniq.end());
    beginResetModel();
    m_items = std::move(uniq);
    endResetModel();
    if (context != m_context) {
        m_context = context;
        emit contextChanged();
    }
}

void YouTubeSource::describe(const QString &videoId)
{
    if (videoId.isEmpty() || !m_proc || m_proc->state() != QProcess::Running)
        return;
    // Fire-and-forget: the reply matches on its "description" key, not the
    // request id, so a superseded listing request can't eat it.
    const QVariantMap req{{QStringLiteral("op"), QStringLiteral("describe")},
                          {QStringLiteral("videoId"), videoId},
                          {QStringLiteral("id"), -7}};
    m_proc->write(QJsonDocument(QJsonObject::fromVariantMap(req))
                      .toJson(QJsonDocument::Compact) + "\n");
}

void YouTubeSource::search(const QString &query)
{
    // the box's RECENT list: newest first, each once, the last 30
    const QString q = query.trimmed();
    if (!q.isEmpty()) {
        m_searches.removeAll(q);
        m_searches.prepend(q);
        while (m_searches.size() > 30)
            m_searches.removeLast();
        saveSearches();
        emit searchesChanged();
    }
    m_stack.clear();
    if (m_tab != QLatin1String("search")) {
        m_tab = QStringLiteral("search");
        emit tabChanged();
    }
    QVariantMap req{{QStringLiteral("op"), QStringLiteral("search")},
                    {QStringLiteral("q"), query}};
    if (!m_filters.isEmpty())
        req.insert(QStringLiteral("filters"), m_filters);
    request(req);
}

void YouTubeSource::openTab(const QString &tab)
{
    if (m_reversed) { // ORDER is per listing — paging is off while reversed
        m_reversed = false;
        emit filtersChanged();
    }
    // the tab again from inside one of its channels/playlists: back to its root
    const bool wasDrilled = !m_stack.isEmpty();
    m_stack.clear();
    if (m_tab != tab || wasDrilled) {
        m_tab = tab;
        emit tabChanged();
    }
    // a pinned playlist's tab lists that playlist
    if (tab.startsWith(QLatin1String("pin:")))
        request({{QStringLiteral("op"), QStringLiteral("browse")},
                 {QStringLiteral("url"), tab.mid(4)}});
    else
        request({{QStringLiteral("op"), QStringLiteral("browse")},
                 {QStringLiteral("tab"), tab}});
}

void YouTubeSource::openItem(int row)
{
    if (m_reversed) { // ORDER is per listing — paging is off while reversed
        m_reversed = false;
        emit filtersChanged();
    }
    const QVariantMap it = itemAt(row);
    const QString kind = it.value(QStringLiteral("kind")).toString();
    // "list" = a list of codec's own (SUBS' ALL CHANNELS, NOTIFICATIONS)
    if (kind != QLatin1String("playlist") && kind != QLatin1String("channel")
        && kind != QLatin1String("list"))
        return;
    QString url = it.value(QStringLiteral("uri")).toString();
    if (kind == QLatin1String("channel") && !url.contains(QLatin1String("/videos")))
        url += QStringLiteral("/videos");
    m_stack.append(m_current);
    emit tabChanged(); // drilled changed
    request({{QStringLiteral("op"), QStringLiteral("browse")},
             {QStringLiteral("url"), url}});
}

void YouTubeSource::openUrl(const QString &url)
{
    if (m_reversed) { // ORDER is per listing — paging is off while reversed
        m_reversed = false;
        emit filtersChanged();
    }
    if (url.isEmpty())
        return;
    m_stack.append(m_current);
    emit tabChanged(); // drilled changed
    QString u = url;
    // A bare channel root lists the channel's TABS (one "<channel> — Videos"
    // row) instead of its videos. Handles, /channel/ ids and /c/ names alike.
    const bool channelRoot = (u.contains(QLatin1String("/@"))
                              || u.contains(QLatin1String("/channel/"))
                              || u.contains(QLatin1String("/c/"))
                              || u.contains(QLatin1String("/user/")))
        && !u.contains(QLatin1String("/videos")) && !u.contains(QLatin1String("/streams"))
        && !u.contains(QLatin1String("/shorts")) && !u.contains(QLatin1String("/playlists"));
    if (channelRoot) {
        while (u.endsWith(QLatin1Char('/')))
            u.chop(1);
        u += QStringLiteral("/videos");
    }
    request({{QStringLiteral("op"), QStringLiteral("browse")},
             {QStringLiteral("url"), u}});
}

void YouTubeSource::actionRequest(QVariantMap req, const QString &doneMessage)
{
    ensureWorker();
    // Own id range: bumping m_reqId here made the in-flight LISTING reply look
    // superseded — it was dropped and QUERYING / LOADING MORE stuck on.
    const qint64 id = ++m_actionId;
    m_pendingActions.insert(id, doneMessage);
    req.insert(QStringLiteral("id"), id);
    m_proc->write(QJsonDocument(QJsonObject::fromVariantMap(req))
                      .toJson(QJsonDocument::Compact) + "\n");
}

void YouTubeSource::addToWatchLater(const QString &videoId, const QString &title,
                                    const QVariantMap &item)
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("wl_add")},
                   {QStringLiteral("videoId"), videoId},
                   {QStringLiteral("item"), item}},
                  QStringLiteral("WATCH LATER + %1").arg(title));
}

void YouTubeSource::removeFromWatchLater(const QString &videoId, const QString &title)
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("wl_remove")},
                   {QStringLiteral("videoId"), videoId}},
                  QStringLiteral("REMOVED FROM WATCH LATER · %1").arg(title));
}

void YouTubeSource::addToPlaylist(const QString &videoId, const QString &playlistId,
                                  const QString &title, const QVariantMap &item)
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("pl_add")},
                   {QStringLiteral("videoId"), videoId},
                   {QStringLiteral("playlistId"), playlistId},
                   {QStringLiteral("item"), item}},
                  QStringLiteral("%1 + VIDEO").arg(title.toUpper()));
}

void YouTubeSource::removeFromPlaylist(const QString &videoId, const QString &playlistId,
                                       const QString &title)
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("pl_remove")},
                   {QStringLiteral("videoId"), videoId},
                   {QStringLiteral("playlistId"), playlistId}},
                  QStringLiteral("REMOVED FROM THE PLAYLIST · %1").arg(title));
}

void YouTubeSource::createPlaylist(const QString &name, const QVariantMap &item)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    const QString title = name.trimmed().isEmpty() ? QStringLiteral("NEW PLAYLIST") : name.trimmed();
    m_createActs.insert(id, item.isEmpty() ? QStringLiteral("NEW PLAYLIST · %1").arg(title.toUpper())
                                           : QStringLiteral("%1 + VIDEO").arg(title.toUpper()));
    send({{QStringLiteral("op"), QStringLiteral("pl_create")},
          {QStringLiteral("title"), title},
          {QStringLiteral("videoId"), item.value(QStringLiteral("videoId"))},
          {QStringLiteral("item"), item},
          {QStringLiteral("id"), id}});
}

void YouTubeSource::notInterested(const QVariantMap &item)
{
    const QString vid = item.value(QStringLiteral("videoId")).toString();
    actionRequest({{QStringLiteral("op"), QStringLiteral("hide")},
                   {QStringLiteral("videoId"), vid}},
                  QStringLiteral("NOT INTERESTED · %1").arg(item.value(QStringLiteral("title")).toString()));
    // gone from the list at once
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].value(QStringLiteral("videoId")).toString() == vid) {
            beginRemoveRows({}, i, i);
            m_items.removeAt(i);
            endRemoveRows();
            break;
        }
}

void YouTubeSource::removeFromHistory(const QVariantMap &item)
{
    const QString vid = item.value(QStringLiteral("videoId")).toString();
    actionRequest({{QStringLiteral("op"), QStringLiteral("history_remove")},
                   {QStringLiteral("videoId"), vid}},
                  QStringLiteral("REMOVED FROM HISTORY · %1").arg(item.value(QStringLiteral("title")).toString()));
    for (int i = m_recent.size() - 1; i >= 0; --i)
        if (m_recent[i].value(QStringLiteral("videoId")).toString() == vid)
            m_recent.removeAt(i);
    for (int i = 0; i < m_items.size(); ++i)
        if (m_items[i].value(QStringLiteral("videoId")).toString() == vid) {
            beginRemoveRows({}, i, i);
            m_items.removeAt(i);
            endRemoveRows();
            break;
        }
}

// ── the account ───────────────────────────────────────────────────────────

void YouTubeSource::start()
{
    ensureWorker();
    // which channels are followed, for SUBSCRIBE / UNSUBSCRIBE in menus
    const qint64 id = ++m_actionId;
    m_followActs.insert(id, QString());
    send({{QStringLiteral("op"), QStringLiteral("following")}, {QStringLiteral("id"), id}});
}

void YouTubeSource::refreshAccount()
{
    ensureWorker();
    // the reply's account rides back as an event too (see onEvent)
    send({{QStringLiteral("op"), QStringLiteral("account")},
          {QStringLiteral("fresh"), true}, {QStringLiteral("id"), -11}});
}

void YouTubeSource::findProfiles()
{
    ensureWorker();
    m_profilesReqId = ++m_actionId;
    emit profilesChanged();
    send({{QStringLiteral("op"), QStringLiteral("profiles")},
          {QStringLiteral("fresh"), true}, {QStringLiteral("id"), m_profilesReqId}});
}

void YouTubeSource::connectProfile(const QString &spec)
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("connect")},
                   {QStringLiteral("spec"), spec}},
                  QString());
}

void YouTubeSource::useLocal()
{
    actionRequest({{QStringLiteral("op"), QStringLiteral("use_local")}}, QString());
}

void YouTubeSource::importAccount(const QString &spec)
{
    if (m_importReqId)
        return;
    ensureWorker();
    m_importReqId = ++m_actionId;
    m_importStatus = QStringLiteral("IMPORTING…");
    emit importChanged();
    send({{QStringLiteral("op"), QStringLiteral("import")},
          {QStringLiteral("spec"), spec}, {QStringLiteral("id"), m_importReqId}});
}

void YouTubeSource::importTakeout()
{
    if (m_importReqId)
        return;
    ensureWorker();
    m_importReqId = ++m_actionId;
    m_importStatus = QStringLiteral("READING THE TAKEOUT…");
    emit importChanged();
    send({{QStringLiteral("op"), QStringLiteral("import_takeout")},
          {QStringLiteral("id"), m_importReqId}});
}

QString YouTubeSource::currentPlaylist() const
{
    const QString url = m_current.value(QStringLiteral("url")).toString();
    if (url.startsWith(QLatin1String("codec:playlist:")))
        return url.mid(15);
    const int at = url.indexOf(QLatin1String("list="));
    if (at < 0)
        return {};
    return url.mid(at + 5).section(QLatin1Char('&'), 0, 0);
}

QString YouTubeSource::channelIdOf(const QString &url) const
{
    static const QRegularExpression re(QStringLiteral("/channel/(UC[\\w-]{22})"));
    const auto m = re.match(url);
    if (m.hasMatch())
        return m.captured(1);
    QString u = url;
    while (u.endsWith(QLatin1Char('/')))
        u.chop(1);
    for (const char *tab : {"/videos", "/playlists", "/streams", "/shorts", "/featured"})
        if (u.endsWith(QLatin1String(tab)))
            u.chop(int(qstrlen(tab)));
    return m_channelIds.value(u);
}

bool YouTubeSource::isFollowing(const QString &channelUrl) const
{
    const QString id = channelIdOf(channelUrl);
    return !id.isEmpty() && m_follow.contains(id);
}

void YouTubeSource::fetchPage(const QString &videoId)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("video"));
    send({{QStringLiteral("op"), QStringLiteral("video")},
          {QStringLiteral("videoId"), videoId}, {QStringLiteral("id"), id}});
}

void YouTubeSource::fetchComments(const QString &videoId, const QString &token)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("comments"));
    send({{QStringLiteral("op"), QStringLiteral("comments")}, {QStringLiteral("videoId"), videoId},
          {QStringLiteral("token"), token}, {QStringLiteral("id"), id}});
}

void YouTubeSource::fetchRelated(const QString &videoId, const QString &token)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("related"));
    send({{QStringLiteral("op"), QStringLiteral("related_more")}, {QStringLiteral("videoId"), videoId},
          {QStringLiteral("token"), token}, {QStringLiteral("id"), id}});
}

void YouTubeSource::batch(const QString &action, const QVariantList &items,
                          const QString &playlistId)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("batch"));
    send({{QStringLiteral("op"), QStringLiteral("batch")}, {QStringLiteral("action"), action},
          {QStringLiteral("items"), items}, {QStringLiteral("playlistId"), playlistId},
          {QStringLiteral("id"), id}});
}

void YouTubeSource::clearNotifications()
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("notif_clear"));
    send({{QStringLiteral("op"), QStringLiteral("notif_clear")}, {QStringLiteral("id"), id}});
}

void YouTubeSource::playAll(bool shuffle)
{
    const QString url = m_current.value(QStringLiteral("url")).toString();
    if (url.isEmpty())
        return;
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("all"));
    send({{QStringLiteral("op"), QStringLiteral("all_entries")}, {QStringLiteral("url"), url},
          {QStringLiteral("shuffle"), shuffle}, {QStringLiteral("id"), id}});
}

void YouTubeSource::postComment(const QString &videoId, const QString &text, const QString &params,
                                bool reply, const QString &parentId)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("comment"));
    send({{QStringLiteral("op"), QStringLiteral("comment")}, {QStringLiteral("videoId"), videoId},
          {QStringLiteral("text"), text}, {QStringLiteral("params"), params},
          {QStringLiteral("reply"), reply}, {QStringLiteral("parentId"), parentId},
          {QStringLiteral("id"), id}});
}

void YouTubeSource::likeComment(const QString &videoId, const QString &commentId,
                                const QString &action, bool liked)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("comment_like"));
    send({{QStringLiteral("op"), QStringLiteral("comment_like")}, {QStringLiteral("videoId"), videoId},
          {QStringLiteral("commentId"), commentId}, {QStringLiteral("action"), action},
          {QStringLiteral("liked"), liked}, {QStringLiteral("id"), id}});
}

void YouTubeSource::rate(const QVariantMap &item, const QString &status)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_pageReqs.insert(id, QStringLiteral("rated"));
    send({{QStringLiteral("op"), QStringLiteral("rate")},
          {QStringLiteral("videoId"), item.value(QStringLiteral("videoId"))},
          {QStringLiteral("item"), item}, {QStringLiteral("status"), status},
          {QStringLiteral("id"), id}});
}

void YouTubeSource::subscribe(const QString &channelUrl, const QString &title)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_followActs.insert(id, (localMode() ? QStringLiteral("FOLLOWING · %1")
                                         : QStringLiteral("SUBSCRIBED · %1")).arg(title.toUpper()));
    send({{QStringLiteral("op"), QStringLiteral("subscribe")},
          {QStringLiteral("channelUrl"), channelUrl},
          {QStringLiteral("title"), title}, {QStringLiteral("id"), id}});
}

void YouTubeSource::unsubscribe(const QString &channelUrl, const QString &title)
{
    ensureWorker();
    const qint64 id = ++m_actionId;
    m_followActs.insert(id, QStringLiteral("UNSUBSCRIBED · %1").arg(title.toUpper()));
    send({{QStringLiteral("op"), QStringLiteral("unsubscribe")},
          {QStringLiteral("channelUrl"), channelUrl},
          {QStringLiteral("title"), title}, {QStringLiteral("id"), id}});
}

void YouTubeSource::setFollowing(const QJsonArray &ids)
{
    QSet<QString> f;
    for (const QJsonValue &v : ids)
        f.insert(v.toString());
    if (f != m_follow) {
        m_follow = f;
        emit followingChanged();
    }
}

void YouTubeSource::setAccount(const QVariantMap &a)
{
    const QString was = m_account.value(QStringLiteral("mode")).toString()
        + m_account.value(QStringLiteral("state")).toString()
        + m_account.value(QStringLiteral("spec")).toString();
    m_account = a;
    emit accountChanged();
    const QString now = a.value(QStringLiteral("mode")).toString()
        + a.value(QStringLiteral("state")).toString()
        + a.value(QStringLiteral("spec")).toString();
    if (was.isEmpty() || was == now)
        return;
    // A different login (or none): the feeds on screen were someone else's,
    // and so is the followed list.
    start();
    if (m_stack.isEmpty() && m_tab != QLatin1String("search") && !m_current.isEmpty())
        refresh();
}

void YouTubeSource::onEvent(const QJsonObject &obj)
{
    const QString ev = obj.value(QStringLiteral("event")).toString();
    if (ev == QLatin1String("fatal")) {
        setError(obj.value(QStringLiteral("error")).toString());
        setLoading(false);
        m_account.insert(QStringLiteral("state"), QStringLiteral("noengine"));
        m_account.insert(QStringLiteral("error"), obj.value(QStringLiteral("error")).toString());
        emit accountChanged();
    } else if (ev == QLatin1String("account")) {
        QVariantMap a = obj.toVariantMap();
        a.remove(QStringLiteral("event"));
        setAccount(a);
    } else if (ev == QLatin1String("channels")) {
        // links resolved to channel ids in the background (SUBSCRIBE menus)
        const QJsonObject ids = obj.value(QStringLiteral("ids")).toObject();
        for (auto it = ids.begin(); it != ids.end(); ++it)
            m_channelIds.insert(it.key(), it.value().toString());
        emit followingChanged();
    } else if (ev == QLatin1String("import")) {
        m_importStatus = obj.value(QStringLiteral("status")).toString();
        emit importChanged();
    }
}

void YouTubeSource::fetchPlaylists()
{
    ensureWorker();
    m_playlistsReqId = ++m_actionId;
    QVariantMap req{{QStringLiteral("op"), QStringLiteral("playlists_flat")},
                    {QStringLiteral("id"), m_playlistsReqId}};
    m_proc->write(QJsonDocument(QJsonObject::fromVariantMap(req))
                      .toJson(QJsonDocument::Compact) + "\n");
}

bool YouTubeSource::goForward()
{
    if (m_forward.isEmpty())
        return false;
    QVariantMap next = m_forward.takeLast();
    QVariantMap here = m_current;
    here.remove(QStringLiteral("id"));
    here.remove(QStringLiteral("start"));
    m_stack.append(here);
    emit tabChanged(); // drilled changed
    next.remove(QStringLiteral("id"));
    QVector<QVariantMap> keep = m_forward;
    request(next);
    m_forward = keep; // request() is also the path that clears it
    return true;
}

bool YouTubeSource::goBack()
{
    if (m_stack.isEmpty())
        return false;
    {
        QVariantMap here = m_current;
        here.remove(QStringLiteral("id"));
        here.remove(QStringLiteral("start"));
        m_forward.append(here);
    }
    QVector<QVariantMap> keep = m_forward;
    QVariantMap parent = m_stack.takeLast();
    emit tabChanged();
    parent.remove(QStringLiteral("id"));
    request(parent);
    m_forward = keep;
    return true;
}

void YouTubeSource::setLoading(bool on)
{
    if (on != m_loading) {
        m_loading = on;
        emit loadingChanged();
    }
}

void YouTubeSource::setError(const QString &e, const QString &kind)
{
    if (e != m_error || kind != m_errorKind) {
        m_error = e;
        m_errorKind = kind;
        emit errorChanged();
    }
}
