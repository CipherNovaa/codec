#include "livechat.h"
#include "scriptpath.h"

#include "logger.h"

#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>

LiveChat::LiveChat(QObject *parent)
    : QAbstractListModel(parent)
{
}

LiveChat::~LiveChat()
{
    close();
}

int LiveChat::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

QVariant LiveChat::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_rows.size())
        return {};
    const QVariantMap &m = m_rows[index.row()];
    switch (role) {
    case AuthorRole: return m.value(QStringLiteral("author"));
    case MessageRole: return m.value(QStringLiteral("message"));
    case BadgesRole: return m.value(QStringLiteral("badges"));
    case AmountRole: return m.value(QStringLiteral("amount"));
    }
    return {};
}

QHash<int, QByteArray> LiveChat::roleNames() const
{
    return {
        {AuthorRole, "author"},
        {MessageRole, "message"},
        {BadgesRole, "badges"},
        {AmountRole, "amount"},
    };
}

bool LiveChat::running() const
{
    return m_proc && m_proc->state() != QProcess::NotRunning;
}

void LiveChat::setStatus(const QString &s)
{
    if (s == m_status)
        return;
    m_status = s;
    emit statusChanged();
}

void LiveChat::open(const QString &uri)
{
    // Same stream, feed still running: keep it (and everything it has loaded)
    // — the player re-asks on every live (re)load, e.g. a DVR rewind.
    if (!uri.isEmpty() && uri == m_uri && m_proc && m_proc->state() != QProcess::NotRunning)
        return;
    close();
    if (uri.isEmpty())
        return;
    m_uri = uri;
    beginResetModel();
    m_rows.clear();
    endResetModel();
    emit countChanged();
    setStatus(QStringLiteral("CONNECTING…"));

    m_proc = new QProcess(this);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, [this] {
        m_buf += m_proc->readAllStandardOutput();
        int nl;
        while ((nl = m_buf.indexOf('\n')) >= 0) {
            const QByteArray line = m_buf.left(nl);
            m_buf.remove(0, nl + 1);
            handleLine(line);
        }
        // A worker spewing newline-less output would grow m_buf without bound
        // and re-scan it on every chunk. No real chat line is this long — drop a
        // runaway partial rather than accumulate it forever.
        if (m_buf.size() > 1 << 20)
            m_buf.clear();
    });
    connect(m_proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this] {
        setStatus(m_rows.isEmpty() ? QStringLiteral("CHAT UNAVAILABLE")
                                   : QStringLiteral("STREAM ENDED"));
        emit runningChanged();
    });
    m_proc->start(QStringLiteral("/usr/bin/python3"),
                  {codecScript(QStringLiteral("codec_yt.py")),
                   QStringLiteral("--chat"), uri});
    emit runningChanged();
    Logger::log(QStringLiteral("chat"), QStringLiteral("open ") + uri);
}

void LiveChat::close()
{
    if (!m_proc)
        return;
    Logger::log(QStringLiteral("chat"), QStringLiteral("close"));
    m_proc->disconnect(this);
    if (m_proc->state() != QProcess::NotRunning) {
        m_proc->terminate(); // SIGTERM → the worker's finally cleans its tmpdir
        if (!m_proc->waitForFinished(400))
            m_proc->kill();
    }
    m_proc->deleteLater();
    m_proc = nullptr;
    m_buf.clear();
    m_uri.clear();
    setStatus(QString());
    emit runningChanged();
}

void LiveChat::sendMessage(const QString &text)
{
    const QString msg = text.trimmed();
    if (msg.isEmpty() || m_uri.isEmpty())
        return;
    if (m_sendProc && m_sendProc->state() != QProcess::NotRunning) {
        emit sendResult(false, QStringLiteral("still sending the last one"));
        return;
    }
    if (!m_sendProc) {
        m_sendProc = new QProcess(this);
        connect(m_sendProc,
                QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this] {
            const QJsonObject o = QJsonDocument::fromJson(
                m_sendProc->readAllStandardOutput()).object();
            // Logged both ways: a send that "didn't work" was undiagnosable —
            // the outcome only ever reached the compose box.
            if (o.value(QStringLiteral("ok")).toBool()) {
                Logger::log(QStringLiteral("chat"), QStringLiteral("sent ok"));
                emit sendResult(true, QString());
            } else {
                const QString err = o.value(QStringLiteral("error")).toString();
                Logger::log(QStringLiteral("chat"), QStringLiteral("send FAILED: ")
                            + (err.isEmpty() ? QStringLiteral("(no reply)") : err));
                emit sendResult(false, err);
            }
        });
    }
    Logger::log(QStringLiteral("chat"), QStringLiteral("send ") + msg.left(40));
    m_sendProc->start(QStringLiteral("/usr/bin/python3"),
                      {codecScript(QStringLiteral("codec_yt.py")),
                       QStringLiteral("--chat-send"), m_uri, msg});
}

void LiveChat::connectYouTube()
{
    if (m_authProc && m_authProc->state() != QProcess::NotRunning)
        return;
    if (!m_authProc) {
        m_authProc = new QProcess(this);
        connect(m_authProc,
                QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this] {
            // The worker prints one JSON object per event; the last line with
            // an "ok" field is the outcome.
            bool ok = false;
            QString err = QStringLiteral("authorization failed");
            const QList<QByteArray> lines =
                m_authProc->readAllStandardOutput().split('\n');
            for (const QByteArray &ln : lines) {
                const QJsonObject o = QJsonDocument::fromJson(ln).object();
                if (o.contains(QStringLiteral("ok"))) {
                    ok = o.value(QStringLiteral("ok")).toBool();
                    err = o.value(QStringLiteral("error")).toString();
                }
            }
            emit authResult(ok, err);
        });
    }
    emit authResult(false, QStringLiteral("__STARTED__")); // UI: "opening browser…"
    m_authProc->start(QStringLiteral("/usr/bin/python3"),
                      {codecScript(QStringLiteral("codec_yt.py")),
                       QStringLiteral("--auth")});
}

QStringList LiveChat::mentionCandidates(const QString &prefix) const
{
    // Recent distinct chatters, newest first — a cheap @-autocomplete with no
    // extra API call (the participant list would need one). Author names carry
    // a leading @ already; match on the bare handle.
    const QString p = prefix.toLower();
    QStringList out;
    for (int i = m_rows.size() - 1; i >= 0 && out.size() < 8; --i) {
        QString a = m_rows[i].value(QStringLiteral("author")).toString();
        if (a.startsWith(QLatin1Char('@')))
            a = a.mid(1);
        if (a.isEmpty() || out.contains(a))
            continue;
        if (p.isEmpty() || a.toLower().startsWith(p))
            out << a;
    }
    return out;
}

void LiveChat::handleLine(const QByteArray &line)
{
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    const QString ev = o.value(QStringLiteral("event")).toString();
    if (ev == QLatin1String("chat")) {
        QVariantMap m;
        m.insert(QStringLiteral("author"),
                 o.value(QStringLiteral("author")).toString());
        m.insert(QStringLiteral("message"),
                 o.value(QStringLiteral("message")).toString());
        QStringList badges;
        const QJsonArray arr = o.value(QStringLiteral("badges")).toArray();
        for (const QJsonValue &b : arr)
            badges << b.toString();
        m.insert(QStringLiteral("badges"), badges);
        m.insert(QStringLiteral("amount"),
                 o.value(QStringLiteral("amount")).toString());
        const int excess = m_rows.size() + 1 - kMax;
        if (excess > 0) {
            beginRemoveRows({}, 0, excess - 1);
            m_rows.remove(0, excess);
            endRemoveRows();
        }
        beginInsertRows({}, m_rows.size(), m_rows.size());
        m_rows.append(m);
        endInsertRows();
        emit countChanged();
        if (!m_status.isEmpty())
            setStatus(QString()); // messages flowing — header stands down
    } else if (ev == QLatin1String("ready")) {
        setStatus(QStringLiteral("WAITING FOR CHAT…"));
    } else if (ev == QLatin1String("error")) {
        setStatus(o.value(QStringLiteral("error")).toString().toUpper());
    } else if (ev == QLatin1String("end")) {
        setStatus(m_rows.isEmpty() ? QStringLiteral("CHAT UNAVAILABLE")
                                   : QStringLiteral("STREAM ENDED"));
    }
}
