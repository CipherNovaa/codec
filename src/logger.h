#pragma once

#include <QFile>
#include <QObject>

// Step logger for detailed debugging (Settings // DEBUG LOG). One file per
// app session in ~/.cache/codec/logs/. The toggle also drops a flag file
// (~/.config/codec/debug) that the python workers and the hub check, so ONE
// switch instruments the whole stack. Logging is a no-op when disabled.
class Logger : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString path READ path NOTIFY enabledChanged)

public:
    explicit Logger(QObject *parent = nullptr);
    static Logger *instance();
    static void log(const QString &cat, const QString &msg); // safe anywhere

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QString path() const { return m_path; }
    Q_INVOKABLE void d(const QString &cat, const QString &msg);

signals:
    void enabledChanged();

private:
    void write(const QString &cat, const QString &msg);
    bool m_enabled = false;
    QString m_path;
    QFile m_file;
};
