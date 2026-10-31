#include "theme.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUrl>
#include <QUrlQuery>

bool Theme::mgsCovers(char32_t u) const
{
    if (!m_mgsLoaded) {
        // The same files the UI's FontLoaders use (compiled into qrc).
        m_mgsCodec = QRawFont(QStringLiteral(":/assets/mechui/mgs-codec.ttf"), 16);
        m_mgsHud = QRawFont(QStringLiteral(":/assets/mechui/mgs-hud.ttf"), 16);
        m_mgsLoaded = true;
    }
    return m_mgsCodec.isValid() && m_mgsHud.isValid()
        && m_mgsCodec.supportsCharacter(u) && m_mgsHud.supportsCharacter(u);
}

Theme::Theme(QObject *parent)
    : QObject(parent)
{
    const QByteArray override = qgetenv("CODEC_WAL_PATH");
    m_jsonPath = override.isEmpty()
        ? QDir::home().filePath(QStringLiteral(".cache/wal/colors.json"))
        : QString::fromUtf8(override);

    m_debounce.setSingleShot(true);
    m_debounce.setInterval(80);
    connect(&m_debounce, &QTimer::timeout, this, &Theme::reload);

    // wal replaces the file, which drops it from the watcher — watching the
    // directory too catches the recreate, and reload() re-adds the file.
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &Theme::scheduleReload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Theme::scheduleReload);
    const QString dir = QFileInfo(m_jsonPath).absolutePath();
    if (QDir(dir).exists())
        m_watcher.addPath(dir);

    reload();
}

void Theme::scheduleReload()
{
    m_debounce.start();
}

qreal Theme::luminance(const QColor &c)
{
    return 0.2126 * c.redF() + 0.7152 * c.greenF() + 0.0722 * c.blueF();
}

QColor Theme::mix(const QColor &a, const QColor &b, qreal t) const
{
    return QColor::fromRgbF(a.redF() + (b.redF() - a.redF()) * t,
                            a.greenF() + (b.greenF() - a.greenF()) * t,
                            a.blueF() + (b.blueF() - a.blueF()) * t,
                            1.0);
}

void Theme::reload()
{
    if (QFile::exists(m_jsonPath) && !m_watcher.files().contains(m_jsonPath))
        m_watcher.addPath(m_jsonPath);
    // The wal cache dir may not exist at launch (fresh machine, pywal never
    // run). The constructor could not watch it then; retry here so that once
    // pywal finally creates ~/.cache/wal/, a later reload picks up the watch and
    // live re-theming self-heals instead of needing an app restart.
    const QString dir = QFileInfo(m_jsonPath).absolutePath();
    if (!m_watcher.directories().contains(dir) && QDir(dir).exists())
        m_watcher.addPath(dir);

    // Resolve to an empty root on a MISSING or partial file so every colour
    // below falls back to its built-in default and we still derive a valid dark
    // theme. Returning early (the old behaviour) left surface/surfaceHi/border/
    // dimFg and the palette UNassigned — invalid QColors that QML paints
    // transparent, i.e. a black/broken UI on a fresh or offline deploy where
    // pywal never wrote colors.json. But if a theme was already loaded, keep it
    // rather than flashing defaults over a live re-theme's partial write.
    QJsonObject root;
    QFile f(m_jsonPath);
    if (!f.open(QIODevice::ReadOnly)) {
        if (!m_palette.isEmpty())
            return;
    } else {
        const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
        if (doc.isObject())
            root = doc.object();
        else if (!m_palette.isEmpty())
            return; // partial write — keep the theme we have; debounce re-fires
    }
    const QJsonObject special = root.value(QStringLiteral("special")).toObject();
    const QJsonObject colors = root.value(QStringLiteral("colors")).toObject();

    // A key can be PRESENT but garbage ("", "#a1b2c") — toString(default) only
    // substitutes the default for a missing/non-string value, so a present-but-
    // invalid hex yields an invalid QColor (luminance from zeroed components ->
    // wrong isLight, surfaces mixed from junk). Validate and fall back per key.
    auto color = [](const QJsonValue &v, const char *fallback) {
        QColor c(v.toString(QString::fromLatin1(fallback)));
        return c.isValid() ? c : QColor(QString::fromLatin1(fallback));
    };

    m_bg = color(special.value(QStringLiteral("background")), "#101010");
    m_fg = color(special.value(QStringLiteral("foreground")), "#d0d0d0");
    m_wallpaper = root.value(QStringLiteral("wallpaper")).toString();

    bool alphaOk = false;
    const double alphaPct = root.value(QStringLiteral("alpha")).toString().toDouble(&alphaOk);
    m_alpha = alphaOk ? qBound(0.0, alphaPct / 100.0, 1.0) : 1.0;

    m_palette.clear();
    for (int i = 0; i < 16; ++i) {
        const QString key = QStringLiteral("color%1").arg(i);
        m_palette.append(color(colors.value(key), "#808080"));
    }

    m_isLight = luminance(m_bg) > 0.5;

    // Accent = the most saturated of colors 1..6 (same convention as the
    // Obsidian graph coloring). Greyscale palettes fall back to color4.
    QColor best = m_palette.value(4).value<QColor>();
    qreal bestSat = -1;
    for (int i = 1; i <= 6; ++i) {
        const QColor c = m_palette.value(i).value<QColor>();
        if (c.hsvSaturationF() > bestSat) {
            bestSat = c.hsvSaturationF();
            best = c;
        }
    }
    m_accent = best;
    // Keep the accent readable against the background.
    if (qAbs(luminance(m_accent) - luminance(m_bg)) < 0.18)
        m_accent = mix(m_accent, m_fg, 0.55);
    m_accentFg = luminance(m_accent) > 0.5 ? QColor(QStringLiteral("#101010"))
                                           : QColor(QStringLiteral("#f0f0f0"));

    // Warning = the most red-leaning saturated slot; greyscale palettes get a
    // fixed desaturated red so alerts stay recognizable on any wallpaper.
    QColor warn;
    qreal warnScore = 0;
    for (int i = 1; i <= 6; ++i) {
        const QColor c = m_palette.value(i).value<QColor>();
        const qreal hue = c.hsvHueF(); // red wraps around 0/1
        const qreal redness = hue < 0 ? 0 : qMax(0.0, 1.0 - qMin(hue, 1.0 - hue) * 6.0);
        const qreal score = redness * c.hsvSaturationF();
        if (score > warnScore) {
            warnScore = score;
            warn = c;
        }
    }
    m_warning = warnScore > 0.12 ? warn : QColor(QStringLiteral("#c86450"));
    if (qAbs(luminance(m_warning) - luminance(m_bg)) < 0.18)
        m_warning = mix(m_warning, m_fg, 0.45);

    m_surface = mix(m_bg, m_fg, 0.06);
    m_surfaceHi = mix(m_bg, m_fg, 0.14);
    m_border = mix(m_bg, m_fg, 0.28);
    m_dimFg = mix(m_bg, m_fg, 0.62);

    // Mech mode overrides every wallpaper-derived role with the fixed set. Done
    // AFTER the pywal derivation so a single flip of the flag switches cleanly
    // (and turning it back off recomputes pywal on the next reload).
    if (m_mechPalette)
        applyMechPalette();

    emit changed();
}

// Fixed mech instrument palette — codec's identity, independent of the wallpaper.
// A steel accent + near-white type on a dark slate; the same family as the OSD.
// Surfaces/border/dimFg are mixed off the fixed bg/fg so they stay coherent, and
// the 16-slot palette becomes a neutral ramp so any view that indexes it gets
// steady greys instead of desktop colours.
void Theme::applyMechPalette()
{
    m_bg = QColor(QStringLiteral("#0d1119"));
    m_fg = QColor(QStringLiteral("#e7ecf3"));
    m_accent = QColor(QStringLiteral("#a6b1c7"));
    m_warning = QColor(QStringLiteral("#d9694a"));
    m_isLight = false;
    m_alpha = 1.0;
    m_accentFg = luminance(m_accent) > 0.5 ? QColor(QStringLiteral("#101010"))
                                           : QColor(QStringLiteral("#f0f0f0"));
    m_surface = mix(m_bg, m_fg, 0.06);
    m_surfaceHi = mix(m_bg, m_fg, 0.14);
    m_border = mix(m_bg, m_fg, 0.28);
    m_dimFg = mix(m_bg, m_fg, 0.62);
    m_palette.clear();
    for (int i = 0; i < 16; ++i)
        m_palette.append(mix(m_bg, m_fg, i / 15.0));
}

void Theme::setMechPalette(bool on)
{
    if (m_mechPalette == on)
        return;
    m_mechPalette = on;
    reload();   // re-derive from pywal, then (maybe) re-apply the mech override
}

QString Theme::artLocal(const QString &p) const
{
    if (p.isEmpty())
        return QString();
    if (p.startsWith(QLatin1String("http://"))
        || p.startsWith(QLatin1String("https://"))) {
        // A satellite's poster is a hub "/art?f=<file>" URL. The same <file> is in
        // the local art cache (reconcile rsyncs it). A Qt Quick 3D Texture can't
        // fetch http, so return the local file when we have it; else the URL as a
        // last resort (no worse than before). #238: the MOVIES film-strip on the
        // laptop was all-white because the 3D texture couldn't load the remote URL.
        const QString file = QUrlQuery(QUrl(p)).queryItemValue(QStringLiteral("f"));
        if (!file.isEmpty()) {
            const QString local = QDir::homePath()
                + QStringLiteral("/.cache/codec/art/") + file;
            if (QFile::exists(local))
                return QStringLiteral("file://") + local;
        }
        return p;
    }
    return QStringLiteral("file://") + p;   // hub: already a local path
}
