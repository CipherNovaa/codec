#include "queuemodel.h"

#include <QDateTime>
#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>

#include <algorithm>

QueueModel::QueueModel(QObject *parent)
    : QAbstractListModel(parent)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    m_db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), QStringLiteral("codec_queue"));
    m_db.setDatabaseName(dir + QStringLiteral("/codec.db"));
    if (!m_db.open()) {
        qWarning("queue: %s", qPrintable(m_db.lastError().text()));
        return;
    }
    QSqlQuery q(m_db);
    q.exec(QStringLiteral("PRAGMA journal_mode=WAL"));
    q.exec(QStringLiteral("PRAGMA synchronous=NORMAL"));
    q.exec(QStringLiteral("PRAGMA busy_timeout=2000"));
    q.exec(QStringLiteral(
        "CREATE TABLE IF NOT EXISTS queue_items ("
        " queue TEXT NOT NULL,"
        " pos INTEGER NOT NULL,"
        " json TEXT NOT NULL,"
        " PRIMARY KEY (queue, pos))"));
    // Persist is a full delete+reinsert of the live queue — O(len) per edit.
    // Skipping through a big queue fires one edit per keypress; coalescing
    // turns the burst into a single write once the mashing stops.
    m_persistTimer.setSingleShot(true);
    m_persistTimer.setInterval(400);
    connect(&m_persistTimer, &QTimer::timeout, this, &QueueModel::persistNow);
    restore();
}

QueueModel::~QueueModel()
{
    if (m_persistTimer.isActive())
        persistNow(); // don't lose the last burst of edits on quit
}

int QueueModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_items.size();
}

QVariant QueueModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_items.size())
        return {};
    const QVariantMap &it = m_items[index.row()];
    // text roles are always strings: an item queued without one (the info
    // page sends no subtitle) read "undefined" in the row
    switch (role) {
    case TitleRole: return it.value(QStringLiteral("title")).toString();
    case SubtitleRole: return it.value(QStringLiteral("subtitle")).toString();
    case UriRole: return it.value(QStringLiteral("uri")).toString();
    case ArtUrlRole: return it.value(QStringLiteral("artUrl")).toString();
    case DurationSRole: return it.value(QStringLiteral("durationS"), 0.0);
    case KindRole: return it.value(QStringLiteral("kind")).toString();
    case SourceIdRole: return it.value(QStringLiteral("sourceId")).toString();
    }
    return {};
}

QHash<int, QByteArray> QueueModel::roleNames() const
{
    return {
        {TitleRole, "title"}, {SubtitleRole, "subtitle"}, {UriRole, "uri"},
        {ArtUrlRole, "artUrl"}, {DurationSRole, "durationS"},
        {KindRole, "kind"}, {SourceIdRole, "sourceId"},
    };
}

double QueueModel::totalDuration() const
{
    double total = 0;
    for (const QVariantMap &it : m_items)
        total += it.value(QStringLiteral("durationS"), 0.0).toDouble();
    return total;
}

void QueueModel::add(const QVariantMap &item)
{
    if (item.value(QStringLiteral("uri")).toString().isEmpty())
        return;
    beginInsertRows({}, m_items.size(), m_items.size());
    m_items.append(item);
    endInsertRows();
    persist();
    emit countChanged();
}

void QueueModel::addFront(const QVariantMap &item)
{
    if (item.value(QStringLiteral("uri")).toString().isEmpty())
        return;
    beginInsertRows({}, 0, 0);
    m_items.prepend(item);
    endInsertRows();
    persist();
    emit countChanged();
}

void QueueModel::removeAt(int row)
{
    if (row < 0 || row >= m_items.size())
        return;
    beginRemoveRows({}, row, row);
    m_items.removeAt(row);
    endRemoveRows();
    persist();
    emit countChanged();
}

void QueueModel::moveItem(int from, int to)
{
    if (from < 0 || from >= m_items.size() || to < 0 || to >= m_items.size() || from == to)
        return;
    // beginMoveRows' destination is expressed as an insert-before index.
    beginMoveRows({}, from, from, {}, to > from ? to + 1 : to);
    m_items.move(from, to);
    endMoveRows();
    persist();
}

void QueueModel::clear()
{
    if (m_items.isEmpty())
        return;
    beginResetModel();
    m_items.clear();
    endResetModel();
    persist();
    emit countChanged();
}

void QueueModel::shuffle()
{
    if (m_items.size() < 2)
        return;
    beginResetModel();
    std::shuffle(m_items.begin(), m_items.end(), *QRandomGenerator::global());
    endResetModel();
    persist();
}

void QueueModel::cycleRepeat()
{
    m_repeat = (m_repeat + 1) % 3;
    emit repeatModeChanged();
}

QVariantMap QueueModel::itemAt(int row) const
{
    return (row >= 0 && row < m_items.size()) ? m_items[row] : QVariantMap();
}

QVariantList QueueModel::allItems() const
{
    QVariantList out;
    for (const QVariantMap &it : m_items)
        out.append(it);
    return out;
}

void QueueModel::replaceAll(const QVariantList &items)
{
    beginResetModel();
    m_items.clear();
    for (const QVariant &v : items) {
        const QVariantMap m = v.toMap();
        // Same guard add()/addFront() enforce: a URI-less row is an unplayable
        // phantom. hub-queue adoption fed straight in here, bypassing it.
        if (!m.value(QStringLiteral("uri")).toString().trimmed().isEmpty())
            m_items.append(m);
    }
    endResetModel();
    persist();
    emit countChanged();
}

QVariantMap QueueModel::takeAt(int row)
{
    if (row < 0 || row >= m_items.size())
        return {};
    const QVariantMap it = m_items[row];
    removeAt(row);
    return it;
}

void QueueModel::persist()
{
    m_persistTimer.start();
}

void QueueModel::persistNow()
{
    if (!m_db.isOpen())
        return;
    m_lastEditMs = QDateTime::currentMSecsSinceEpoch();
    m_db.transaction();
    QSqlQuery del(m_db);
    del.prepare(QStringLiteral("DELETE FROM queue_items WHERE queue='live'"));
    del.exec();
    QSqlQuery ins(m_db);
    ins.prepare(QStringLiteral(
        "INSERT INTO queue_items (queue, pos, json) VALUES ('live', ?, ?)"));
    for (int i = 0; i < m_items.size(); ++i) {
        ins.addBindValue(i);
        ins.addBindValue(QString::fromUtf8(
            QJsonDocument(QJsonObject::fromVariantMap(m_items[i])).toJson(QJsonDocument::Compact)));
        ins.exec();
    }
    QSqlQuery meta(m_db);
    meta.prepare(QStringLiteral(
        "INSERT OR REPLACE INTO queue_items (queue, pos, json)"
        " VALUES ('_meta', 0, ?)"));
    meta.addBindValue(QString::number(m_lastEditMs));
    meta.exec();
    m_db.commit();
}

void QueueModel::restore()
{
    QSqlQuery mq(m_db);
    mq.prepare(QStringLiteral("SELECT json FROM queue_items WHERE queue='_meta'"));
    if (mq.exec() && mq.next())
        m_lastEditMs = mq.value(0).toString().toLongLong();
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral("SELECT json FROM queue_items WHERE queue='live' ORDER BY pos"));
    if (!q.exec())
        return;
    beginResetModel();
    m_items.clear();
    while (q.next())
        m_items.append(QJsonDocument::fromJson(q.value(0).toByteArray()).object().toVariantMap());
    endResetModel();
    emit countChanged();
}

void QueueModel::saveAs(const QString &name)
{
    if (!m_db.isOpen() || name.isEmpty() || name == QLatin1String("live")
        || name == QLatin1String("_meta"))
        return;
    m_db.transaction();
    QSqlQuery del(m_db);
    del.prepare(QStringLiteral("DELETE FROM queue_items WHERE queue=?"));
    del.addBindValue(name);
    del.exec();
    QSqlQuery ins(m_db);
    ins.prepare(QStringLiteral("INSERT INTO queue_items (queue, pos, json) VALUES (?, ?, ?)"));
    for (int i = 0; i < m_items.size(); ++i) {
        ins.addBindValue(name);
        ins.addBindValue(i);
        ins.addBindValue(QString::fromUtf8(
            QJsonDocument(QJsonObject::fromVariantMap(m_items[i])).toJson(QJsonDocument::Compact)));
        ins.exec();
    }
    m_db.commit();
}

void QueueModel::loadSaved(const QString &name)
{
    // 'live' is the working queue's own row and '_meta' holds a bare epoch-ms
    // number, not MediaItems — loading either as a saved queue yields garbage.
    // saveAs() already refuses these names; loadSaved must too.
    if (!m_db.isOpen() || name.isEmpty()
        || name == QLatin1String("live") || name == QLatin1String("_meta"))
        return;
    QSqlQuery q(m_db);
    q.prepare(QStringLiteral("SELECT json FROM queue_items WHERE queue=? ORDER BY pos"));
    q.addBindValue(name);
    if (!q.exec())
        return;
    beginResetModel();
    m_items.clear();
    while (q.next())
        m_items.append(QJsonDocument::fromJson(q.value(0).toByteArray()).object().toVariantMap());
    endResetModel();
    persist();
    emit countChanged();
}

QStringList QueueModel::savedQueues() const
{
    QStringList out;
    QSqlQuery q(m_db);
    if (q.exec(QStringLiteral(
            "SELECT DISTINCT queue FROM queue_items"
            " WHERE queue NOT IN ('live','_meta') ORDER BY queue")))
        while (q.next())
            out << q.value(0).toString();
    return out;
}
