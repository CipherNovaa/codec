#include "logger.h"

#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QSettings>
#include <QStandardPaths>

static Logger *s_instance = nullptr;

Logger::Logger(QObject *parent)
    : QObject(parent)
{
    s_instance = this;
    m_enabled = QSettings().value(QStringLiteral("debugLog"), false).toBool();
    if (m_enabled)
        setEnabled(true); // opens the session file + refreshes the flag file
}

Logger *Logger::instance()
{
    return s_instance;
}

void Logger::log(const QString &cat, const QString &msg)
{
    if (s_instance && s_instance->m_enabled)
        s_instance->write(cat, msg);
}

void Logger::d(const QString &cat, const QString &msg)
{
    if (m_enabled)
        write(cat, msg);
}

void Logger::setEnabled(bool on)
{
    QSettings().setValue(QStringLiteral("debugLog"), on);
    const QString flag = QDir::home().filePath(QStringLiteral(".config/codec/debug"));
    if (on) {
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation)
                            + QStringLiteral("/codec/logs");
        QDir().mkpath(dir);
        QDir().mkpath(QFileInfo(flag).absolutePath());
        QFile flagFile(flag);
        if (!flagFile.open(QIODevice::WriteOnly)) // flag for workers + hub
            qWarning("codec: cannot write debug flag %s: %s", qUtf8Printable(flag),
                     qUtf8Printable(flagFile.errorString()));
        if (!m_file.isOpen()) {
            m_path = dir + QStringLiteral("/app-")
                     + QDateTime::currentDateTime().toString(QStringLiteral("MMdd-HHmmss"))
                     + QStringLiteral(".log");
            m_file.setFileName(m_path);
            // Say so loudly if this fails: write() silently no-ops on a closed
            // file, so the UI would show logging "on" while recording nothing —
            // and the debug log is the tool used to root-cause everything else.
            if (!m_file.open(QIODevice::WriteOnly | QIODevice::Append))
                qWarning("codec: cannot open log %s: %s", qUtf8Printable(m_path),
                         qUtf8Printable(m_file.errorString()));
        }
    } else {
        QFile::remove(flag);
        if (m_file.isOpen())
            m_file.close();
    }
    if (m_enabled != on) {
        m_enabled = on;
        emit enabledChanged();
    }
    if (on)
        write(QStringLiteral("log"), QStringLiteral("debug logging enabled"));
}

void Logger::write(const QString &cat, const QString &msg)
{
    if (!m_file.isOpen())
        return;
    m_file.write(QStringLiteral("%1 [%2] %3\n")
                     .arg(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz")),
                          cat, msg)
                     .toUtf8());
    m_file.flush();
}
