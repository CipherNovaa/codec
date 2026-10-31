#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QProcess>
#include <QVariantMap>
#include <QVector>

// YouTube browse model, backed by the codec_yt.py worker (yt-dlp behind a
// JSON-lines pipe). One in-flight request at a time; replies for anything but
// the newest request are dropped. The worker is restartable — no state lives
// in it.
class YouTubeSource : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(QString tab READ tab NOTIFY tabChanged)
    Q_PROPERTY(QString context READ context NOTIFY contextChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    // loading AND the request is the next page of the current listing (show a
    // foot loader, not the full QUERYING strip).
    Q_PROPERTY(bool appending READ appending NOTIFY loadingChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool drilled READ drilled NOTIFY tabChanged)
    // how many listings deep (a channel 1, a playlist inside it 2): Back
    // returns to the row it left (YouTubeView's depth stack)
    Q_PROPERTY(int depth READ depth NOTIFY tabChanged)
    // Search filters {sort, date, type, duration, live} — see codec_yt.py
    // search_params(). Changing them re-runs the current search.
    Q_PROPERTY(QVariantMap filters READ filters WRITE setFilters NOTIFY filtersChanged)
    // Ascending: YouTube only sorts descending, so this reverses the loaded rows.
    Q_PROPERTY(bool reversed READ reversed WRITE setReversed NOTIFY filtersChanged)
    // On a channel's page: which of its tabs it lists — "videos", "shorts",
    // "streams" (LIVE) or "playlists"; "" = not a channel.
    Q_PROPERTY(QString channelView READ channelView NOTIFY listingChanged)
    // Who YouTube is on this machine (the worker's "account" event):
    // {mode: account|local, state: local|connected|expired|signedout|
    //  nobrowser|offline, browser (ZEN…), profile, spec, name, handle, photo,
    //  engine {ytdlp, js}, local {following, watchlater, playlists, history}}
    Q_PROPERTY(QVariantMap account READ account NOTIFY accountChanged)
    // Every browser profile here, for CONNECT YOUTUBE (findProfiles()):
    // [{spec, label, profileName, signedIn, name, photo, expired, locked}]
    Q_PROPERTY(QVariantList profiles READ profiles NOTIFY profilesChanged)
    Q_PROPERTY(bool findingProfiles READ findingProfiles NOTIFY profilesChanged)
    // A Google Takeout found in Downloads (its file name), or "".
    Q_PROPERTY(QString takeout READ takeout NOTIFY profilesChanged)
    // Beside `error`: why a list needs the account — "" or local / nobrowser
    // / signedout / expired (codec_yt.NotSignedIn), so the view offers the
    // right way out.
    Q_PROPERTY(QString errorKind READ errorKind NOTIFY errorChanged)
    // What an empty list of codec's own would be filled by ("" otherwise).
    Q_PROPERTY(QString note READ note NOTIFY listingChanged)
    // What heads a drilled listing (codec_yt.listing_header): a channel
    // {kind, title, channelId, url, handle, followers, avatar, banner,
    // description} or a playlist {kind, title, id, url, count, owner}; {}
    // for a tab or a search.
    Q_PROPERTY(QVariantMap header READ header NOTIFY listingChanged)
    // The search box's list: what was searched here before (newest first,
    // kept in ~/.local/share/codec/yt-searches.json), and YouTube's own
    // suggestions for what's being typed (suggest()).
    Q_PROPERTY(QStringList recentSearches READ recentSearches NOTIFY searchesChanged)
    Q_PROPERTY(QStringList suggestions READ suggestions NOTIFY searchesChanged)
    // Playlists pinned as tabs of their own, after PLAYLISTS: [{url, title}]
    // (~/.local/share/codec/yt-pins.json). Their tab is "pin:<url>".
    Q_PROPERTY(QVariantList pins READ pins NOTIFY pinsChanged)
    // IMPORT FROM ACCOUNT's progress line; "" when no import runs.
    Q_PROPERTY(QString importStatus READ importStatus NOTIFY importChanged)

public:
    enum Roles {
        TitleRole = Qt::UserRole + 1,
        SubtitleRole,
        UriRole,
        ArtUrlRole,
        DurationSRole,
        KindRole,
        VideoIdRole,
        ChannelUrlRole,
        PublishedRole,
        IsLiveRole,
        IsShortRole,
    };

    explicit YouTubeSource(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString tab() const { return m_tab; }
    QString context() const { return m_context; }
    bool loading() const { return m_loading; }
    bool appending() const { return m_loading && m_appending; }
    QString error() const { return m_error; }
    bool drilled() const { return !m_stack.isEmpty(); }
    int depth() const { return int(m_stack.size()); }
    QVariantMap filters() const { return m_filters; }
    void setFilters(const QVariantMap &f);
    bool reversed() const { return m_reversed; }
    void setReversed(bool on);
    QString channelView() const;
    // Swap the channel's page to another of its tabs in place (no drill:
    // Back still leaves the channel).
    Q_INVOKABLE void setChannelView(const QString &view);

    QVariantMap account() const { return m_account; }
    QVariantList profiles() const { return m_profiles; }
    bool findingProfiles() const { return m_profilesReqId != 0; }
    QString errorKind() const { return m_errorKind; }
    QString note() const { return m_note; }
    QVariantMap header() const { return m_header; }
    QStringList recentSearches() const { return m_searches; }
    QStringList suggestions() const { return m_suggestions; }
    Q_INVOKABLE void suggest(const QString &query);     // "" clears
    QVariantList pins() const { return m_pins; }
    Q_INVOKABLE bool isPinned(const QString &url) const;
    Q_INVOKABLE void pin(const QString &url, const QString &title);
    Q_INVOKABLE void unpin(const QString &url);
    Q_INVOKABLE void forgetSearch(const QString &query);
    QString importStatus() const { return m_importStatus; }
    QString takeout() const { return m_takeout; }
    bool localMode() const { return m_account.value(QStringLiteral("mode")) == QLatin1String("local"); }

    // The worker up at launch: the account is known (and the player's login
    // set) before the first YouTube anything.
    Q_INVOKABLE void start();
    Q_INVOKABLE void refreshAccount();            // ask YouTube again who it is
    Q_INVOKABLE void findProfiles();              // -> profiles
    Q_INVOKABLE void connectProfile(const QString &spec);
    Q_INVOKABLE void useLocal();                  // codec's own lists, no account
    Q_INVOKABLE void importAccount(const QString &spec); // "" = the signed-in one
    Q_INVOKABLE void importTakeout();             // the Takeout found in Downloads
    // A channel by any link to it (/@handle, /channel/UC…): followed?
    Q_INVOKABLE bool isFollowing(const QString &channelUrl) const;
    Q_INVOKABLE void subscribe(const QString &channelUrl, const QString &title);
    Q_INVOKABLE void unsubscribe(const QString &channelUrl, const QString &title);
    Q_INVOKABLE void createPlaylist(const QString &name, const QVariantMap &item);
    Q_INVOKABLE void removeFromPlaylist(const QString &videoId, const QString &playlistId,
                                        const QString &title);
    Q_INVOKABLE void notInterested(const QVariantMap &item);   // codec's own FOR YOU
    Q_INVOKABLE void removeFromHistory(const QVariantMap &item);

    // A video's own page (YouTubePage.qml), on the action ids so it never
    // races the listing: fetchPage -> pageReply("video", the page),
    // fetchComments -> pageReply("comments", {comments, next, count, token}),
    // fetchRelated -> pageReply("related", {rows, next}).
    Q_INVOKABLE void fetchPage(const QString &videoId);
    Q_INVOKABLE void fetchComments(const QString &videoId, const QString &token);
    Q_INVOKABLE void fetchRelated(const QString &videoId, const QString &token);
    // Select mode: one action on many rows (codec_yt.batch) — wl_add,
    // wl_remove, pl_add, pl_remove (playlistId), subscribe, unsubscribe,
    // unlike, history_remove, hide, notif_hide -> pageReply("batch",
    // {action, count, ok, error})
    Q_INVOKABLE void batch(const QString &action, const QVariantList &items,
                           const QString &playlistId = {});
    // NOTIFICATIONS ▸ CLEAR ALL: every notification hidden on YouTube
    // -> pageReply("notif_clear", {hidden})
    Q_INVOKABLE void clearNotifications();
    // PLAY ALL / SHUFFLE: every video of the drilled playlist or channel tab
    // -> pageReply("all", {entries, shuffle})
    Q_INVOKABLE void playAll(bool shuffle);
    // A comment (params = the comments' createParams) or a reply (params = the
    // comment's replyParams), posted as the account -> pageReply("comment",
    // {comment, reply, parentId}); a comment's LIKE / UNLIKE -> "comment_like"
    Q_INVOKABLE void postComment(const QString &videoId, const QString &text, const QString &params,
                                 bool reply, const QString &parentId);
    Q_INVOKABLE void likeComment(const QString &videoId, const QString &commentId,
                                 const QString &action, bool liked);
    // LIKE / DISLIKE / "" (neither): the account's rating, or codec's own
    // Liked videos -> pageReply("rated", {videoId, rating})
    Q_INVOKABLE void rate(const QVariantMap &item, const QString &status);

    // The playlist the listing is (a drilled list=… or codec's own), or "".
    Q_INVOKABLE QString currentPlaylist() const;
    // The drilled listing's url (codec:notifications, a channel's /videos…), or "".
    Q_INVOKABLE QString currentUrl() const { return m_current.value(QStringLiteral("url")).toString(); }
    Q_INVOKABLE void search(const QString &query);
    Q_INVOKABLE void openTab(const QString &tab); // trending|subs|watchlater|history|rec
    Q_INVOKABLE void openItem(int row);           // drill into playlist/channel
    Q_INVOKABLE void openUrl(const QString &url); // drill an arbitrary listing url
    Q_INVOKABLE void fetchMore();                 // infinite scroll: next page
    Q_INVOKABLE bool goBack();                    // pop the drill stack
    // Mouse FORWARD: re-enter the listing goBack() just left (browser-style).
    bool canGoForward() const { return !m_forward.isEmpty(); }
    bool goForward();
    Q_INVOKABLE QVariantMap itemAt(int row) const;
    Q_INVOKABLE void describe(const QString &videoId); // async -> described()
    Q_INVOKABLE void refresh();                   // re-run the listing, bypassing cache
    // Warm the worker's cache for the tabs most likely opened first, so the
    // view opens instantly. Called once at idle after launch.
    Q_INVOKABLE void prewarm(const QStringList &tabs);
    // Account watch-history ping through the warm worker (silent).
    void watchPing(const QString &uri, double pos);
    // Remember a YouTube item codec just played, so HISTORY shows it at once —
    // the account feed can lag minutes behind the watch ping.
    void noteWatched(const QVariantMap &item);
    // The title codec saw for a video it played (its own HISTORY), or "".
    QString recentTitle(const QString &videoId) const;

    // Context-menu actions — separate reply channel from browsing, so a
    // background write never races the visible listing.
    // `item` = the row (codec's own lists keep it whole; an account needs
    // only the id).
    Q_INVOKABLE void addToWatchLater(const QString &videoId, const QString &title,
                                     const QVariantMap &item = {});
    Q_INVOKABLE void removeFromWatchLater(const QString &videoId, const QString &title);
    Q_INVOKABLE void addToPlaylist(const QString &videoId, const QString &playlistId,
                                   const QString &title, const QVariantMap &item = {});
    Q_INVOKABLE void fetchPlaylists();

signals:
    void tabChanged();
    void contextChanged();
    void loadingChanged();
    void errorChanged();
    void actionDone(const QString &message);
    void described(const QString &videoId, const QString &text);
    void actionFailed(const QString &message);
    void playlistsReady(const QVariantList &playlists); // [{title,id}]
    void filtersChanged();
    void listingChanged();
    void accountChanged();
    void profilesChanged();
    void importChanged();
    void followingChanged();
    void searchesChanged();
    void pinsChanged();
    void pageReply(const QString &kind, const QVariantMap &data);
    // a playlist made by createPlaylist (the picker shows it at once)
    void playlistCreated(const QString &playlistId, const QString &title);

private slots:
    void onReadyRead();

private:
    void ensureWorker();
    void request(QVariantMap req);
    void actionRequest(QVariantMap req, const QString &doneMessage);
    void setLoading(bool on);
    void setError(const QString &e, const QString &kind = {});
    void setEntries(QVector<QVariantMap> entries, const QString &context);
    void send(const QVariantMap &req);
    void prefetchNext();

    QProcess *m_proc = nullptr;
    QVector<QVariantMap> m_items;
    // Drill stack of pending requests so h/back replays the parent listing.
    QVector<QVariantMap> m_stack;
    QVector<QVariantMap> m_forward; // listings goBack() left, newest last
    QVariantMap m_current; // request that produced the current listing
    bool m_appending = false;
    bool m_noMore = false;
    int m_fetchOffset = 0;  // upstream feed position (pre-dedupe, so paging
                            // never re-reads a window dedupe shrank)
    int m_refreshLoops = 0; // consecutive tail re-pulls with nothing new
    QString m_tab = QStringLiteral("search");
    QString m_context;
    QString m_error;
    bool m_loading = false;
    qint64 m_reqId = 0;
    QHash<qint64, QString> m_pendingActions; // id -> success toast
    qint64 m_playlistsReqId = 0;
    QVariantMap m_filters;
    bool m_reversed = false;
    QVector<QVariantMap> m_recent; // newest first, persisted
    bool m_freshNext = false;  // next fetchMore bypasses the worker cache (For You re-draw)
    qint64 m_actionId = 1000000000; // actions/playlists: own id range, never m_reqId
    qint64 m_prewarmAt = 0;    // ms epoch of the last prewarm (throttle)
    void loadRecent();
    QVector<QVariantMap> mergeRecent(QVector<QVariantMap> feed) const;
    void onEvent(const QJsonObject &obj);
    void setAccount(const QVariantMap &a);
    void setFollowing(const QJsonArray &ids);
    QString channelIdOf(const QString &url) const;

    QVariantMap m_account;
    QVariantList m_profiles;
    qint64 m_profilesReqId = 0;
    qint64 m_importReqId = 0;
    QString m_errorKind;
    QString m_note;
    QVariantMap m_header;
    QStringList m_searches;
    QStringList m_suggestions;
    QString m_suggestFor;            // the query the newest suggest() asked about
    void loadSearches();
    QVariantList m_pins;
    void loadPins();
    void savePins() const;
    void saveSearches() const;
    QString m_importStatus;
    QString m_takeout;
    QSet<QString> m_follow;                  // followed channel ids (UC…)
    QHash<QString, QString> m_channelIds;    // a channel link -> its UC… id
    QHash<qint64, QString> m_followActs;     // subscribe/unsubscribe ids -> toast
    QHash<qint64, QString> m_createActs;     // pl_create ids -> the toast
    QHash<qint64, QString> m_pageReqs;       // a video page's request ids -> kind
};
