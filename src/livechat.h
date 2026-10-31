#pragma once

#include <QAbstractListModel>
#include <QVariantMap>
#include <QVector>

class QProcess;

// Live-stream chat rail. Runs `codec_yt.py --chat <url>` (yt-dlp's live-chat
// follower, normalized to JSON lines) and models the rolling tail for the
// in-player chat panel. Old rows fall off the top past kMax — a chat is a
// stream, not an archive.
class LiveChat : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool running READ running NOTIFY runningChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    // Connection state for the panel header ("CONNECTING…", "STREAM ENDED",
    // …); empty while messages are flowing normally.
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
    enum Roles {
        AuthorRole = Qt::UserRole + 1,
        MessageRole,
        BadgesRole, // ["mod","member","verified","owner"]
        AmountRole, // superchat purchase text, "" for normal messages
    };

    explicit LiveChat(QObject *parent = nullptr);
    ~LiveChat() override;

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool running() const;
    int count() const { return m_rows.size(); }
    QString status() const { return m_status; }

    Q_INVOKABLE void open(const QString &uri);
    Q_INVOKABLE void close();
    // Post a message to the live chat (worker --chat-send, InnerTube write).
    // Result arrives async on sendResult; the message itself shows up through
    // the normal chat tail once YouTube echoes it.
    Q_INVOKABLE void sendMessage(const QString &text);
    // Recent distinct chatter names for @-mention autocomplete, newest first,
    // filtered by an optional prefix (without the leading @).
    Q_INVOKABLE QStringList mentionCandidates(const QString &prefix) const;
    // One-time OAuth so the official Data API can send (see docs/CHAT.md).
    // Runs the worker's --auth, which opens the browser to Google's consent.
    Q_INVOKABLE void connectYouTube();

signals:
    void runningChanged();
    void countChanged();
    void statusChanged();
    void sendResult(bool ok, const QString &error);
    void authResult(bool ok, const QString &error);

private:
    void setStatus(const QString &s);
    void handleLine(const QByteArray &line);

    QProcess *m_proc = nullptr;
    QProcess *m_sendProc = nullptr;
    QProcess *m_authProc = nullptr;
    QVector<QVariantMap> m_rows;
    QByteArray m_buf;
    QString m_status;
    QString m_uri;
    static constexpr int kMax = 250;
};
