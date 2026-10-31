#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QRawFont>
#include <QObject>
#include <QTimer>
#include <QVariantList>

// Live pywal theme. Reads ~/.cache/wal/colors.json (override with
// CODEC_WAL_PATH), watches it for rewrites, and derives a small set of
// contrast-safe roles the QML layer binds to. All roles are derived from
// the wal background/foreground pair, so light wallpapers flip for free.
class Theme : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QColor bg READ bg NOTIFY changed)
    Q_PROPERTY(QColor fg READ fg NOTIFY changed)
    Q_PROPERTY(QColor accent READ accent NOTIFY changed)
    Q_PROPERTY(QColor accentFg READ accentFg NOTIFY changed)
    Q_PROPERTY(QColor warning READ warning NOTIFY changed)
    Q_PROPERTY(QColor surface READ surface NOTIFY changed)
    Q_PROPERTY(QColor surfaceHi READ surfaceHi NOTIFY changed)
    Q_PROPERTY(QColor border READ border NOTIFY changed)
    Q_PROPERTY(QColor dimFg READ dimFg NOTIFY changed)
    Q_PROPERTY(QVariantList palette READ palette NOTIFY changed)
    Q_PROPERTY(bool isLight READ isLight NOTIFY changed)
    Q_PROPERTY(double alpha READ alpha NOTIFY changed)
    Q_PROPERTY(QString wallpaper READ wallpaper NOTIFY changed)
    Q_PROPERTY(QString monoFont READ monoFont CONSTANT)
    Q_PROPERTY(QString uiFont READ uiFont CONSTANT)
    // Mech-UI faces (loaded app-wide by Main.qml's FontLoaders). Centralised here
    // so every view references the ONE instrument set — the P1 typography sweep
    // replaces generic monoFont/uiFont with these. hudFont = data/labels/body,
    // codecFont = headings/titles/emphasis.
    Q_PROPERTY(QString hudFont READ hudFont CONSTANT)
    Q_PROPERTY(QString codecFont READ codecFont CONSTANT)
    // When true, the wallpaper palette is IGNORED and every role is a fixed mech
    // instrument colour (codec's identity, steady regardless of the desktop).
    // pywal is not scrapped — flip this off to bring it back. Owned as a persisted
    // setting by AppController, which drives it; default is mech-on.
    Q_PROPERTY(bool mechPalette READ mechPalette WRITE setMechPalette NOTIFY changed)

public:
    explicit Theme(QObject *parent = nullptr);

    QColor bg() const { return m_bg; }
    QColor fg() const { return m_fg; }
    QColor accent() const { return m_accent; }
    QColor accentFg() const { return m_accentFg; }
    QColor warning() const { return m_warning; }
    QColor surface() const { return m_surface; }
    QColor surfaceHi() const { return m_surfaceHi; }
    QColor border() const { return m_border; }
    QColor dimFg() const { return m_dimFg; }
    QVariantList palette() const { return m_palette; }
    bool isLight() const { return m_isLight; }
    double alpha() const { return m_alpha; }
    QString wallpaper() const { return m_wallpaper; }
    QString monoFont() const { return QStringLiteral("Iosevka Nerd Font Mono"); }
    QString uiFont() const { return QStringLiteral("Iosevka Nerd Font"); }
    QString hudFont() const { return QStringLiteral("MGS1 HUD"); }
    QString codecFont() const { return QStringLiteral("MGS1 Codec"); }

    bool mechPalette() const { return m_mechPalette; }
    void setMechPalette(bool on);

    // Make dynamic text safe for the MGS faces. Since 2026-10 the faces cover all
    // of Latin-1 + Latin Extended-A, punctuation, super/subscripts, currency and
    // the UI symbols (scripts/codec_font_glyphs.py), so the rule is COVERAGE, read
    // from the font files themselves: any character BOTH MGS faces draw is kept
    // verbatim — "Velásquez", "Björk", "The Accountant²", a · or — separator.
    // Only what they lack is folded (below) to something they have, or an accent
    // stripped to its base as the last resort — better than dropping to another
    // font mid-word. Adding a glyph to the fonts needs no change here.
    bool mgsCovers(char32_t u) const;
    Q_INVOKABLE QString mgsSafe(const QString &s) const
    {
        QString out;
        out.reserve(s.size());
        for (const QChar c : s) {
            if (c.unicode() < 0x80 || mgsCovers(c.unicode())) {
                out += c;
                continue;
            }
            // Superscript / subscript digit → plain digit. The MGS faces have no
            // such glyph, so Qt falls back to another font and renders a small,
            // raised, blurry digit (TMDB stylises the sequel as "The Accountant²").
            // A stylised number reads best with the space TMDB drops, so restore
            // one when the digit butts straight up against a letter.
            const ushort u = c.unicode();
            int sd = -1;
            if (u == 0x2070) sd = 0;
            else if (u == 0x00B9) sd = 1;
            else if (u == 0x00B2) sd = 2;
            else if (u == 0x00B3) sd = 3;
            else if (u >= 0x2074 && u <= 0x2079) sd = u - 0x2070; // superscript 4..9
            else if (u >= 0x2080 && u <= 0x2089) sd = u - 0x2080; // subscript 0..9
            if (sd >= 0) {
                if (!out.isEmpty() && out.back().isLetter())
                    out += QLatin1Char(' ');
                out += QChar(QLatin1Char('0' + sd));
                continue;
            }
            // Not drawn by both faces (only reached for those): fold to an
            // MGS-native equivalent (cosmetic, not a meaning change).
            switch (c.unicode()) {
            case 0x00B7: case 0x2022: out += QLatin1Char(' '); break;
            case 0x2014: case 0x2013: case 0x2212: out += QLatin1Char('-'); break;
            case 0x00D7: out += QLatin1Char('x'); break;
            case 0x2192: case 0x25B8: case 0x25B9: case 0x00BB:
                out += QLatin1Char('>'); break;
            case 0x2190: case 0x00AB: out += QLatin1Char('<'); break;
            case 0x2191: out += QLatin1Char('^'); break;
            case 0x2193: out += QLatin1Char('v'); break;
            case 0x23CE: case 0x21B5: out += QStringLiteral("RET"); break;
            case 0x2423: out += QStringLiteral("SPC"); break;
            case 0x232B: case 0x2421: out += QStringLiteral("DEL"); break;
            case 0x00B1: out += QStringLiteral("+/-"); break;
            case 0x26A0: out += QLatin1Char('!'); break;
            case 0x2026: out += QStringLiteral("..."); break;
            case 0x2018: case 0x2019: case 0x02BC: out += QLatin1Char('\''); break;
            case 0x201C: case 0x201D: out += QLatin1Char('"'); break;
            default:
                if (c.unicode() < 0x80) {
                    out += c;                       // plain ASCII, unchanged
                } else {
                    // Unknown non-ASCII: strip any accent down to its ASCII base.
                    const QString d = QString(c).normalized(QString::NormalizationForm_D);
                    for (const QChar dc : d)
                        if (dc.category() != QChar::Mark_NonSpacing) out += dc;
                }
                break;
            }
        }
        return out;
    }

    Q_INVOKABLE QColor withAlpha(const QColor &c, qreal a) const
    {
        QColor out = c;
        out.setAlphaF(a);
        return out;
    }
    Q_INVOKABLE QColor mix(const QColor &a, const QColor &b, qreal t) const;

    // #10: art is a LOCAL file on the hub but an http(s) /art URL on a satellite.
    // Return an Image-ready source: a local path as file://, "" for empty, and a
    // satellite's hub "/art?f=<file>" URL as the SAME file from the local art
    // cache when it is there (else the URL). Every art site funnels through here
    // (the old inline `"file://" + poster` produced "file://http://…" on
    // satellites). It used to hand the URL back untouched, so every poster on
    // the laptop was a network fetch and the library went blank away from the
    // hub although the art was on disk — now the cache is what the library
    // shows from, online or not, and the hub is only asked for art it lacks.
    Q_INVOKABLE QString art(const QString &p) const { return artLocal(p); }

    // The resolver behind art(): the local cache file for a hub "/art?f=" URL
    // when it exists (reconcile rsyncs ~/.cache/codec/art; codec_pull_library
    // fetches what's missing), the URL as a last resort, file:// for a path.
    // Also what a Qt Quick 3D Texture (the MOVIES film-strip) needs, since it
    // cannot fetch http at all.
    Q_INVOKABLE QString artLocal(const QString &p) const;

signals:
    void changed();

private:
    void scheduleReload();
    void reload();
    void applyMechPalette();   // overwrite the roles with the fixed mech set
    static qreal luminance(const QColor &c);

    QString m_jsonPath;
    QFileSystemWatcher m_watcher;
    // The two MGS faces as raw fonts, for mgsCovers() (loaded on first use).
    mutable QRawFont m_mgsCodec, m_mgsHud;
    mutable bool m_mgsLoaded = false;
    QTimer m_debounce;

    QColor m_bg{QStringLiteral("#101010")};
    QColor m_fg{QStringLiteral("#d0d0d0")};
    QColor m_accent{QStringLiteral("#8e8e8e")};
    QColor m_accentFg{QStringLiteral("#101010")};
    QColor m_warning{QStringLiteral("#c86450")};
    QColor m_surface;
    QColor m_surfaceHi;
    QColor m_border;
    QColor m_dimFg;
    QVariantList m_palette;
    bool m_isLight = false;
    double m_alpha = 1.0;
    QString m_wallpaper;
    bool m_mechPalette = true;   // default: fixed mech palette (pywal off)
};
