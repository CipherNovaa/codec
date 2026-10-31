#pragma once

#include <QAbstractListModel>
#include <QSqlDatabase>
#include <QTimer>
#include <QVariantMap>
#include <QVector>

// The play queue — the single "what plays next" authority (episode autoplay
// feeds it too). Items are source-agnostic maps with the MediaItem shape:
//   uri, title, subtitle, artUrl, durationS, kind, sourceId
// The live queue persists in codec.db across restarts; named queues can be
// saved and loaded.
class QueueModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int repeatMode READ repeatMode NOTIFY repeatModeChanged)
    Q_PROPERTY(double totalDuration READ totalDuration NOTIFY countChanged)

public:
    enum Roles {
        TitleRole = Qt::UserRole + 1,
        SubtitleRole,
        UriRole,
        ArtUrlRole,
        DurationSRole,
        KindRole,
        SourceIdRole,
    };
    enum RepeatMode { RepeatOff = 0, RepeatAll = 1, RepeatOne = 2 };
    Q_ENUM(RepeatMode)

    explicit QueueModel(QObject *parent = nullptr);
    ~QueueModel() override;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return m_items.size(); }
    int repeatMode() const { return m_repeat; }
    double totalDuration() const;

    Q_INVOKABLE void add(const QVariantMap &item);
    Q_INVOKABLE void addFront(const QVariantMap &item);
    Q_INVOKABLE void removeAt(int row);
    Q_INVOKABLE void moveItem(int from, int to);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void shuffle();
    Q_INVOKABLE void cycleRepeat();
    Q_INVOKABLE QVariantMap itemAt(int row) const;
    QVariantList allItems() const;
    void replaceAll(const QVariantList &items); // hub cast-queue adoption
    // Pop for playback: removes and returns the row.
    Q_INVOKABLE QVariantMap takeAt(int row);

    Q_INVOKABLE void saveAs(const QString &name);
    Q_INVOKABLE void loadSaved(const QString &name); // replaces the live queue
    Q_INVOKABLE QStringList savedQueues() const;

    // When the live queue was last written, epoch ms — survives restarts so
    // hub-queue LWW can tell "my restored queue is newer than the hub's".
    qint64 lastEditMs() const { return m_lastEditMs; }

signals:
    void countChanged();
    void repeatModeChanged();

private:
    void persist();     // schedules persistNow (coalesced)
    void persistNow();  // the actual full-table rewrite
    void restore();

    QSqlDatabase m_db;
    QVector<QVariantMap> m_items;
    QTimer m_persistTimer;
    qint64 m_lastEditMs = 0;
    int m_repeat = RepeatOff;
};
