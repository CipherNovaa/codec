#include "castmanager.h"
#include "scriptpath.h"

#include "logger.h"

#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>

CastManager::CastManager(QObject *parent)
    : QAbstractListModel(parent)
{
}

void CastManager::start()
{
    if (!m_started) {
        m_started = true;
        ensureWorker();
    }
}

int CastManager::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_devices.size();
}

QVariant CastManager::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_devices.size())
        return {};
    const QVariantMap &d = m_devices[index.row()];
    switch (role) {
    case IdRole: return d.value(QStringLiteral("id"));
    case NameRole: return d.value(QStringLiteral("name"));
    case ModelRole: return d.value(QStringLiteral("model"));
    case IpRole: return d.value(QStringLiteral("ip"));
    }
    return {};
}

QHash<int, QByteArray> CastManager::roleNames() const
{
    return {{IdRole, "deviceId"}, {NameRole, "name"},
            {ModelRole, "modelName"}, {IpRole, "ip"}};
}

QVariantMap CastManager::deviceAt(int row) const
{
    return (row >= 0 && row < m_devices.size()) ? m_devices[row] : QVariantMap();
}

void CastManager::ensureWorker()
{
    if (m_proc && m_proc->state() == QProcess::Running)
        return;
    delete m_proc;
    m_proc = new QProcess(this);
    QString script = QProcessEnvironment::systemEnvironment()
                         .value(QStringLiteral("CODEC_CAST_WORKER"));
    if (script.isEmpty())
        script = codecScript(QStringLiteral("codec_cast.py"));
    connect(m_proc, &QProcess::readyReadStandardOutput,
            this, &CastManager::onReadyRead);
    connect(m_proc, &QProcess::finished, this, [this] {
        // Worker gone -> devices gone; targets reset to local.
        beginResetModel();
        m_devices.clear();
        endResetModel();
        emit devicesChanged();
        if (!m_targetId.isEmpty()) {
            m_targetId.clear();
            m_targetName.clear();
            emit targetChanged();
            emit castError(QStringLiteral("cast worker exited — back to local"));
        }
    });
    m_proc->start(QStringLiteral("/usr/bin/python3"), {script});
}

void CastManager::rescan()
{
    request({{QStringLiteral("op"), QStringLiteral("rescan")}});
}

void CastManager::addDeviceIp(const QString &ip)
{
    request({{QStringLiteral("op"), QStringLiteral("add_ip")},
             {QStringLiteral("ip"), ip.trimmed()}});
}

void CastManager::request(QVariantMap req)
{
    ensureWorker();
    req.insert(QStringLiteral("id"), ++m_reqId);
    const QByteArray line = QJsonDocument(QJsonObject::fromVariantMap(req))
                                .toJson(QJsonDocument::Compact);
    Logger::log(QStringLiteral("cast>"), QString::fromUtf8(line.left(300)));
    m_proc->write(line + "\n");
}

void CastManager::onReadyRead()
{
    while (m_proc->canReadLine()) {
        const QByteArray line = m_proc->readLine();
        const QJsonObject obj = QJsonDocument::fromJson(line).object();
        const QString event = obj.value(QStringLiteral("event")).toString();
        if (event != QLatin1String("status")) // status = 1Hz noise
            Logger::log(QStringLiteral("cast<"),
                        QString::fromUtf8(line.trimmed().left(300)));
        if (event == QLatin1String("device")) {
            const QVariantMap d = obj.toVariantMap();
            bool known = false;
            for (const QVariantMap &e : std::as_const(m_devices))
                if (e.value(QStringLiteral("id")) == d.value(QStringLiteral("id")))
                    known = true;
            if (!known) {
                beginInsertRows({}, m_devices.size(), m_devices.size());
                m_devices.append(d);
                endInsertRows();
                emit devicesChanged();
            }
        } else if (event == QLatin1String("scan_done")) {
            emit scanFinished(obj.value(QStringLiteral("found")).toInt());
        } else if (event == QLatin1String("add_ip_result")) {
            emit addDeviceResult(obj.value(QStringLiteral("ok")).toBool(),
                                 obj.value(QStringLiteral("ip")).toString(),
                                 obj.value(QStringLiteral("name")).toString(),
                                 obj.value(QStringLiteral("error")).toString());
        } else if (event == QLatin1String("device_gone")) {
            const QString id = obj.value(QStringLiteral("id")).toString();
            for (int i = 0; i < m_devices.size(); ++i) {
                if (m_devices[i].value(QStringLiteral("id")).toString() == id) {
                    beginRemoveRows({}, i, i);
                    m_devices.removeAt(i);
                    endRemoveRows();
                    emit devicesChanged();
                    break;
                }
            }
        } else if (event == QLatin1String("status")) {
            m_state = obj.value(QStringLiteral("state")).toString();
            m_position = obj.value(QStringLiteral("position")).toDouble();
            m_duration = obj.value(QStringLiteral("duration")).toDouble();
            m_volume = obj.value(QStringLiteral("volume")).toDouble(m_volume);
            m_rate = obj.value(QStringLiteral("rate")).toDouble(m_rate);
            emit castStatusChanged();
            if (obj.value(QStringLiteral("finished")).toBool() && !m_uri.isEmpty()) {
                const QString done = m_uri;
                m_uri.clear();
                emit castEnded(done);
            }
        } else if (event == QLatin1String("tracks")) {
            m_audioTracks = obj.value(QStringLiteral("audio")).toArray().toVariantList();
            m_subTracks = obj.value(QStringLiteral("subs")).toArray().toVariantList();
            m_audioIdx = obj.value(QStringLiteral("aidx")).toInt();
            m_subIdx = obj.value(QStringLiteral("sub")).toInt(-1);
            m_screenMode = obj.value(QStringLiteral("mode")).toString(QStringLiteral("fit"));
            m_isYt = obj.value(QStringLiteral("yt")).toBool();
            m_subsFinal = obj.value(QStringLiteral("subs_final")).toBool(true);
            emit castTracksChanged();
        } else if (event == QLatin1String("title")) {
            m_title = obj.value(QStringLiteral("title")).toString();
            emit castStatusChanged();
        } else if (event == QLatin1String("attached")) {
            if (obj.value(QStringLiteral("media")).toBool()) {
                // Foreign session adopted: from here on we're its remote.
                m_uri = obj.value(QStringLiteral("uri")).toString();
                m_title = obj.value(QStringLiteral("title")).toString();
                m_state = obj.value(QStringLiteral("state")).toString();
                m_position = obj.value(QStringLiteral("position")).toDouble();
                m_duration = obj.value(QStringLiteral("duration")).toDouble();
                emit castStatusChanged();
                emit castAttached(m_title);
            }
        } else if (event == QLatin1String("cast_error")
                   || event == QLatin1String("fatal")) {
            emit castError(obj.value(QStringLiteral("error")).toString());
        } else if (!event.isEmpty()) {
            // ready etc.
        } else if (!obj.value(QStringLiteral("ok")).toBool(true)) {
            emit castError(obj.value(QStringLiteral("error")).toString());
        }
    }
}

void CastManager::setTarget(const QString &id)
{
    if (id == m_targetId)
        return;
    if (id.isEmpty())
        request({{QStringLiteral("op"), QStringLiteral("disconnect")}});
    m_targetId = id;
    m_targetName.clear();
    for (const QVariantMap &d : std::as_const(m_devices))
        if (d.value(QStringLiteral("id")).toString() == id)
            m_targetName = d.value(QStringLiteral("name")).toString();
    m_state = QStringLiteral("IDLE");
    m_position = m_duration = 0;
    emit targetChanged();
    emit castStatusChanged();
    if (!id.isEmpty()) {
        // Another codec on the network may already be casting here — adopt
        // that session as a remote instead of clobbering it on next play.
        request({{QStringLiteral("op"), QStringLiteral("attach")},
                 {QStringLiteral("device"), id}});
    }
}

void CastManager::castLoad(const QVariantMap &item, double startPos)
{
    if (m_targetId.isEmpty())
        return;
    // #4: reset the transport readout on a media change (as stopCast/setTarget do),
    // else the remote paints the FINISHED item's fill bar + time (e.g. a near-full
    // 23:00/24:00) under the new title until the first status tick arrives.
    m_position = startPos;
    m_duration = 0;
    m_uri = item.value(QStringLiteral("uri")).toString();
    m_title = item.value(QStringLiteral("title")).toString();
    QString thumb = item.value(QStringLiteral("artUrl")).toString();
    if (thumb.startsWith(QLatin1String("file://")))
        thumb.clear(); // the TV can't fetch our local files
    QVariantMap req{{QStringLiteral("op"), QStringLiteral("load")},
             {QStringLiteral("device"), m_targetId},
             {QStringLiteral("uri"), m_uri},
             {QStringLiteral("title"), m_title},
             {QStringLiteral("thumb"), thumb},
             {QStringLiteral("position"), startPos},
             {QStringLiteral("duration"),
              item.value(QStringLiteral("durationS"), 0)},
             {QStringLiteral("subsize"),
              item.value(QStringLiteral("subsize"), 1.0)}};
    // WATCH PARTY FROM A CAST: when the item carries a party token, the worker
    // makes the receiver a FOLLOWER of that hub room (its own party lane +
    // clock) instead of a solo cast — see CastWorker._party_follower_load.
    const QString partyToken = item.value(QStringLiteral("partyToken")).toString();
    if (!partyToken.isEmpty()) {
        req.insert(QStringLiteral("partyToken"), partyToken);
        const QVariant subs = item.value(QStringLiteral("partySubs"));
        if (subs.isValid())
            req.insert(QStringLiteral("subs"), subs);
    }
    request(req);
    m_state = QStringLiteral("BUFFERING");
    emit castStatusChanged();
}

void CastManager::pause() { request({{QStringLiteral("op"), QStringLiteral("pause")}}); }
void CastManager::resume() { request({{QStringLiteral("op"), QStringLiteral("resume")}}); }

void CastManager::togglePause()
{
    if (m_state == QLatin1String("PLAYING") || m_state == QLatin1String("BUFFERING"))
        pause();
    else
        resume();
    // Optimistic flip so the remote reflects the keypress before the TV's
    // status round-trip (~1s) lands.
    m_state = (m_state == QLatin1String("PAUSED")) ? QStringLiteral("PLAYING")
                                                   : QStringLiteral("PAUSED");
    emit castStatusChanged();
}

void CastManager::volumeUp()
{
    request({{QStringLiteral("op"), QStringLiteral("volume")},
             {QStringLiteral("dir"), QStringLiteral("up")}});
}

void CastManager::volumeDown()
{
    request({{QStringLiteral("op"), QStringLiteral("volume")},
             {QStringLiteral("dir"), QStringLiteral("down")}});
}

void CastManager::seek(double position)
{
    request({{QStringLiteral("op"), QStringLiteral("seek")},
             {QStringLiteral("position"), position}});
}

void CastManager::setSubTrack(int index)
{
    request({{QStringLiteral("op"), QStringLiteral("set_sub")},
             {QStringLiteral("index"), index}});
    m_subIdx = index; // optimistic; the worker's tracks event confirms
    emit castTracksChanged();
}

void CastManager::addSub(bool refresh)
{
    request({{QStringLiteral("op"), QStringLiteral("add_sub")},
             {QStringLiteral("refresh"), refresh}});
}

void CastManager::pushSubStyle()
{
    request({{QStringLiteral("op"), QStringLiteral("sub_style")}});
}

void CastManager::setAudioTrack(int index)
{
    request({{QStringLiteral("op"), QStringLiteral("set_audio")},
             {QStringLiteral("index"), index}});
    m_audioIdx = index;
    emit castTracksChanged();
}

void CastManager::setRate(double rate)
{
    request({{QStringLiteral("op"), QStringLiteral("rate")},
             {QStringLiteral("value"), rate}});
    m_rate = rate; // optimistic
    emit castStatusChanged();
}

void CastManager::setScreenMode(const QString &mode)
{
    request({{QStringLiteral("op"), QStringLiteral("screen_mode")},
             {QStringLiteral("mode"), mode}});
    m_screenMode = mode;
    emit castTracksChanged();
}

void CastManager::showTvToast(const QString &text, int ms, bool prompt)
{
    QVariantMap req{{QStringLiteral("op"), QStringLiteral("toast")},
                    {QStringLiteral("text"), text}};
    if (ms > 0)
        req.insert(QStringLiteral("ms"), ms);
    if (prompt)
        req.insert(QStringLiteral("prompt"), true);
    request(req);
}

void CastManager::hideTvToast()
{
    request({{QStringLiteral("op"), QStringLiteral("toast")},
             {QStringLiteral("hide"), true}});
}

void CastManager::stopCast()
{
    m_uri.clear();
    request({{QStringLiteral("op"), QStringLiteral("stop")}});
    m_state = QStringLiteral("IDLE");
    m_position = m_duration = 0;
    emit castStatusChanged();
}
