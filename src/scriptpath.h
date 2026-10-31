#pragma once

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QString>
#include <QStringList>

// Where codec's helper scripts live (the cast worker, YouTube, the art
// pipeline, state sync …). It used to be two of the author's own folders —
// ~/.local/bin symlinks and ~/Projects/codec/scripts — which on any other
// machine meant no art, no YouTube and no casting. The first of these that has
// the script wins:
//   $CODEC_SCRIPTS                         a deliberate override
//   <binary>/../share/codec/scripts        an installed codec (/usr, a Flatpak)
//   <this build's source tree>/scripts     a dev build, wherever it was cloned
//   ~/.local/bin                           the old deploy symlinks
// Nothing found answers the old ~/.local/bin path, whose absence callers
// already read as "not installed here".
inline QString codecScript(const QString &name)
{
    QStringList dirs;
    const QString env = qEnvironmentVariable("CODEC_SCRIPTS");
    if (!env.isEmpty())
        dirs << env;
    dirs << QCoreApplication::applicationDirPath() + QStringLiteral("/../share/codec/scripts");
#ifdef CODEC_SOURCE_DIR
    dirs << QStringLiteral(CODEC_SOURCE_DIR "/scripts");
#endif
    const QString local = QDir::home().filePath(QStringLiteral(".local/bin"));
    dirs << local;
    for (const QString &d : std::as_const(dirs)) {
        const QString p = QDir(d).filePath(name);
        if (QFileInfo::exists(p))
            return QDir::cleanPath(p);
    }
    return QDir(local).filePath(name);
}
