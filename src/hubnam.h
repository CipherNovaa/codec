#pragma once

#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QQmlNetworkAccessManagerFactory>
#include <QReadWriteLock>
#include <QSet>
#include <QString>

// A satellite's key to its hub (device pairing, scripts/codec_pairing.py) rides
// every request this process makes to that hub — and only to it: the app's
// own calls (AppController's m_nam) and QML's (a poster fetched straight from
// the hub). One process-wide copy, set by AppController::loadHubConfig from
// the owner-only hub-key.json; never sent to any other host.
class HubNam : public QNetworkAccessManager
{
public:
    using QNetworkAccessManager::QNetworkAccessManager;

    static void setAuth(const QSet<QString> &hosts, const QByteArray &key)
    {
        QWriteLocker l(&lock());
        hostsRef() = hosts;
        keyRef() = key;
    }

protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &req,
                                 QIODevice *data) override
    {
        QNetworkRequest r(req);
        {
            QReadLocker l(&lock());
            if (!keyRef().isEmpty() && hostsRef().contains(r.url().host().toLower())
                && !r.hasRawHeader("X-Codec-Key"))
                r.setRawHeader("X-Codec-Key", keyRef());
        }
        return QNetworkAccessManager::createRequest(op, r, data);
    }

private:
    static QReadWriteLock &lock() { static QReadWriteLock l; return l; }
    static QSet<QString> &hostsRef() { static QSet<QString> h; return h; }
    static QByteArray &keyRef() { static QByteArray k; return k; }
};

class HubNamFactory : public QQmlNetworkAccessManagerFactory
{
public:
    QNetworkAccessManager *create(QObject *parent) override { return new HubNam(parent); }
};
