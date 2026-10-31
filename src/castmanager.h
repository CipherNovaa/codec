#pragma once

#include <QAbstractListModel>
#include <QProcess>
#include <QVariantMap>
#include <QVector>

// Cast targets (Chromecast / Google TV), backed by the codec_cast.py worker
// (pychromecast + zeroconf over a JSON-lines pipe). Doubles as the device
// list model for the output picker. targetId "" = play locally.
class CastManager : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(QString targetId READ targetId NOTIFY targetChanged)
    Q_PROPERTY(QString targetName READ targetName NOTIFY targetChanged)
    Q_PROPERTY(QString castState READ castState NOTIFY castStatusChanged)
    Q_PROPERTY(double castPosition READ castPosition NOTIFY castStatusChanged)
    Q_PROPERTY(double castDuration READ castDuration NOTIFY castStatusChanged)
    Q_PROPERTY(QString castTitle READ castTitle NOTIFY castStatusChanged)
    Q_PROPERTY(double castVolume READ castVolume NOTIFY castStatusChanged)
    Q_PROPERTY(double castRate READ castRate NOTIFY castStatusChanged)
    Q_PROPERTY(int deviceCount READ deviceCount NOTIFY devicesChanged)
    // Track/mode state of the current cast session (from the worker's
    // "tracks" event): lists of {i,lang,title,codec[,text]} maps.
    Q_PROPERTY(QVariantList castAudioTracks READ castAudioTracks NOTIFY castTracksChanged)
    Q_PROPERTY(QVariantList castSubTracks READ castSubTracks NOTIFY castTracksChanged)
    Q_PROPERTY(int castAudioIndex READ castAudioIndex NOTIFY castTracksChanged)
    Q_PROPERTY(int castSubIndex READ castSubIndex NOTIFY castTracksChanged)
    Q_PROPERTY(QString castScreenMode READ castScreenMode NOTIFY castTracksChanged)
    Q_PROPERTY(bool castIsYoutube READ castIsYoutube NOTIFY castTracksChanged)
    Q_PROPERTY(QString castUri READ currentUri NOTIFY castStatusChanged)

public:
    enum Roles { IdRole = Qt::UserRole + 1, NameRole, ModelRole, IpRole };

    explicit CastManager(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString targetId() const { return m_targetId; }
    QString targetName() const { return m_targetName; }
    QString castState() const { return m_state; }
    double castPosition() const { return m_position; }
    double castDuration() const { return m_duration; }
    QString castTitle() const { return m_title; }
    double castVolume() const { return m_volume; }
    double castRate() const { return m_rate; }
    int deviceCount() const { return m_devices.size(); }
    QVariantList castAudioTracks() const { return m_audioTracks; }
    QVariantList castSubTracks() const { return m_subTracks; }
    int castAudioIndex() const { return m_audioIdx; }
    int castSubIndex() const { return m_subIdx; }
    QString castScreenMode() const { return m_screenMode; }
    bool castIsYoutube() const { return m_isYt; }
    bool castSubsFinal() const { return m_subsFinal; }
    bool active() const { return !m_targetId.isEmpty(); }
    QString currentUri() const { return m_uri; }

    void start(); // begin discovery (worker spawn)

    Q_INVOKABLE void setTarget(const QString &id); // "" = local
    Q_INVOKABLE void castLoad(const QVariantMap &item, double startPos);
    Q_INVOKABLE void pause();
    Q_INVOKABLE void resume();
    Q_INVOKABLE void togglePause();
    Q_INVOKABLE void seek(double position);
    Q_INVOKABLE void volumeUp();
    Q_INVOKABLE void volumeDown();
    Q_INVOKABLE void setSubTrack(int index);   // -1 = off
    Q_INVOKABLE void addSub(bool refresh = false); // a sidecar fetched WHILE casting (refresh: re-timed)
    Q_INVOKABLE void pushSubStyle();               // the cast caption style, live
    Q_INVOKABLE void setAudioTrack(int index);
    Q_INVOKABLE void setScreenMode(const QString &mode); // fit|zoom|stretch
    Q_INVOKABLE void setRate(double rate);
    Q_INVOKABLE void stopCast();
    // A message on the TV's action-toast plate, held for `ms` (0 = the usual
    // 1.6 s flash); hideTvToast takes a held one down early. UP NEXT uses both.
    // `prompt` = an UP NEXT card: the TV remote's OK/Back answer it while it's held.
    Q_INVOKABLE void showTvToast(const QString &text, int ms = 0, bool prompt = false);
    Q_INVOKABLE void hideTvToast();
    Q_INVOKABLE QVariantMap deviceAt(int row) const;
    // The output picker's ADD DEVICE row: a fresh LAN search (-> scanFinished),
    // or ask one address directly for a device mDNS can't see (-> a device row
    // + addDeviceResult). Neither casts anything.
    Q_INVOKABLE void rescan();
    Q_INVOKABLE void addDeviceIp(const QString &ip);

signals:
    void targetChanged();
    void devicesChanged();
    void castStatusChanged();
    void castTracksChanged();
    // The cast finished the file naturally (queue can advance).
    void castEnded(const QString &uri);
    void castError(const QString &message);
    // Adopted a session another codec started on this device.
    void castAttached(const QString &title);
    void scanFinished(int found);   // devices that weren't listed before
    void addDeviceResult(bool ok, const QString &ip, const QString &name, const QString &error);

private slots:
    void onReadyRead();

private:
    void ensureWorker();
    void request(QVariantMap req);

    QProcess *m_proc = nullptr;
    QVector<QVariantMap> m_devices;
    QString m_targetId, m_targetName;
    QString m_state = QStringLiteral("IDLE");
    QString m_title, m_uri;
    double m_position = 0, m_duration = 0, m_volume = 0, m_rate = 1.0;
    QVariantList m_audioTracks, m_subTracks;
    int m_audioIdx = 0, m_subIdx = -1;
    QString m_screenMode = QStringLiteral("fit");
    bool m_isYt = false;
    bool m_subsFinal = true;
    bool m_started = false;
    qint64 m_reqId = 0;
};
