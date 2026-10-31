#pragma once

#include <QObject>
#include <QVariantList>

// Design tokens — the vocabulary the QML layer is allowed to use for motion,
// spacing and type size. Theme owns colour (it tracks pywal and changes at
// runtime); this owns everything that must NOT change at runtime.
//
// It exists because the QML tree had grown 24 distinct animation durations, 17
// type sizes and 26 spacing values as bare literals. That isn't a hierarchy,
// it's the absence of one, and it's the difference between a UI that reads as
// an instrument and one that reads as a web page.
//
// A C++ context property rather than a QML singleton because the QML here is
// shipped through qt_add_resources, which has no qmldir to declare a singleton
// in — and because these values are compile-time constants anyway.
class DesignTokens : public QObject
{
    Q_OBJECT

    // ── motion ────────────────────────────────────────────────────────────
    // Six durations, no others. Taken from IBM Carbon's productive set, which
    // is built around exactly this register: machine, not personality.
    Q_PROPERTY(int fast READ fast CONSTANT)       // 70  micro-interaction
    Q_PROPERTY(int quick READ quick CONSTANT)     // 110 fade, small element
    Q_PROPERTY(int base READ base CONSTANT)       // 160 the default
    Q_PROPERTY(int slow READ slow CONSTANT)       // 240 expansion, surface
    Q_PROPERTY(int grand READ grand CONSTANT)     // 400 large surface
    Q_PROPERTY(int scrim READ scrim CONSTANT)     // 700 background dim
    // Exit is 0.7x enter: a thing leaving should not take as long as a thing
    // arriving, because you have already stopped caring about it.
    Q_INVOKABLE static int out(int enter) { return int(enter * 0.7); }
    // Selection feel — the STATS rows', used by every selectable list: the
    // spotlight (lit plate, text brightness/colour) FADES over selFade instead of
    // snapping, and the row's content dips with its plate's press by selDip(h) —
    // 15% of the plate's height, held to 4..7px (STATS's 7 on its rows, 6 on the
    // 40px YouTube tabs, never a twitch on a small row).
    Q_PROPERTY(int selFade READ selFade CONSTANT)  // 200

    // Three curves, and they are DIRECTIONAL — one curve for everything is
    // what makes motion read as soft. Decelerate-only says "actuated, then
    // damped" (a servo). Accelerate-only says "released, gone". Symmetric
    // ease-in-out says "a mass moved gently by hand", which is wrong here.
    // Bezier arrays are in QML's [x1,y1,x2,y2,1,1] form.
    Q_PROPERTY(QVariantList enterCurve READ enterCurve CONSTANT)
    Q_PROPERTY(QVariantList exitCurve READ exitCurve CONSTANT)
    Q_PROPERTY(QVariantList moveCurve READ moveCurve CONSTANT)

    // Choreography: 20ms between staggered items, whole sequence under 500ms.
    Q_PROPERTY(int stagger READ stagger CONSTANT)
    Q_PROPERTY(int staggerMax READ staggerMax CONSTANT)
    // Movement is orthogonal: X then Y, offset by this, so things travel on
    // the grid like a gantry instead of sliding diagonally.
    Q_PROPERTY(int axisOffset READ axisOffset CONSTANT)

    // ── spacing (4px base) ────────────────────────────────────────────────
    Q_PROPERTY(int s1 READ s1 CONSTANT)   // 4   icon<->label, tick pitch
    Q_PROPERTY(int s2 READ s2 CONSTANT)   // 8   within a field group
    Q_PROPERTY(int s3 READ s3 CONSTANT)   // 12  between fields
    Q_PROPERTY(int s4 READ s4 CONSTANT)   // 16  panel padding
    Q_PROPERTY(int s5 READ s5 CONSTANT)   // 24  between panels
    Q_PROPERTY(int s6 READ s6 CONSTANT)   // 32  between sections
    Q_PROPERTY(int s7 READ s7 CONSTANT)   // 48
    Q_PROPERTY(int s8 READ s8 CONSTANT)   // 64  view margin

    // ── type (1.25 ratio) ─────────────────────────────────────────────────
    // 11px is the floor and only for tracked uppercase labels: below that it
    // stops being "technical" and starts being unreadable.
    Q_PROPERTY(int tLabel READ tLabel CONSTANT)     // 11 UPPERCASE +track
    Q_PROPERTY(int tMeta READ tMeta CONSTANT)       // 12
    Q_PROPERTY(int tBody READ tBody CONSTANT)       // 14
    Q_PROPERTY(int tTitle READ tTitle CONSTANT)     // 17
    Q_PROPERTY(int tHead READ tHead CONSTANT)       // 21
    Q_PROPERTY(int tView READ tView CONSTANT)       // 26
    Q_PROPERTY(int tDisplay READ tDisplay CONSTANT) // 54
    // Uppercase needs 5-12% tracking to stay legible; lowercase needs none.
    // These are absolute pixels for Iosevka at the size they're named for.
    Q_PROPERTY(qreal trackLabel READ trackLabel CONSTANT)  // ~0.08em at 11px
    Q_PROPERTY(qreal trackHead READ trackHead CONSTANT)    // ~0.06em at 21px

public:
    // (public: QML only calls PUBLIC invokables — see the selection-feel note above)
    Q_INVOKABLE int selDip(qreal plateH) const { return qBound(4, qRound(plateH * 0.15), 7); }
    using QObject::QObject;

    int fast() const { return 70; }
    int quick() const { return 110; }
    int base() const { return 160; }
    int slow() const { return 240; }
    int grand() const { return 400; }
    int scrim() const { return 700; }
    int selFade() const { return 200; }

    QVariantList enterCurve() const { return {0.0, 0.0, 0.38, 0.9, 1.0, 1.0}; }
    QVariantList exitCurve() const { return {0.2, 0.0, 1.0, 0.9, 1.0, 1.0}; }
    QVariantList moveCurve() const { return {0.2, 0.0, 0.38, 0.9, 1.0, 1.0}; }

    int stagger() const { return 20; }
    int staggerMax() const { return 500; }
    int axisOffset() const { return 60; }

    int s1() const { return 4; }
    int s2() const { return 8; }
    int s3() const { return 12; }
    int s4() const { return 16; }
    int s5() const { return 24; }
    int s6() const { return 32; }
    int s7() const { return 48; }
    int s8() const { return 64; }

    int tLabel() const { return 11; }
    int tMeta() const { return 12; }
    int tBody() const { return 14; }
    int tTitle() const { return 17; }
    int tHead() const { return 21; }
    int tView() const { return 26; }
    int tDisplay() const { return 54; }
    qreal trackLabel() const { return 0.9; }
    qreal trackHead() const { return 1.3; }
};
