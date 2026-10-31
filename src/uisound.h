#pragma once

#include <QHash>
#include <QObject>
#include <QStringList>
#include <QElapsedTimer>
#include <QTimer>
#include <QVariantList>
#include <memory>
#include <vector>

class AppController;
class SfxMixer;
class SfxOutput;

// UI sounds — the short cues codec plays as you move around a screen (QML: Sfx).
// Every pack carries the same five cues (move · bump · select · back · open), so a
// view asks for a CUE and the chosen pack answers. Packs are WAVs under
// assets/sfx/<pack>/ (made by scripts/codec_sfx_forge.py); a dev build reads
// them from the source tree whenever a pack is picked, so a re-forged pack plays
// without a rebuild.
//
// Output is one PipeWire stream (src/uisound.cpp, SfxOutput), not Qt Multimedia:
// Qt's audio drags in its FFmpeg backend, which held the GUI thread for 1.4 s on
// first use (the display picker missed clicks) and loaded CUDA for +130 MB. The
// stream connects once, a moment after launch, follows the default output, and
// sits PAUSED while nothing sounds — a paused node doesn't keep the device awake.
// PipeWire's own thread pulls the mix; the GUI thread only hands it voices. Built
// without libpipewire, every call is a no-op.
//
// Settings (config.json): uiSounds (on/off), uiSoundPack, uiSoundLevel (10..100).
class UiSound : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY changed)
    Q_PROPERTY(QString pack READ pack WRITE setPack NOTIFY changed)
    Q_PROPERTY(int level READ level WRITE setLevel NOTIFY changed)
    Q_PROPERTY(QStringList packs READ packs CONSTANT)
    Q_PROPERTY(QVariantList levels READ levels CONSTANT)

public:
    explicit UiSound(AppController *app, QObject *parent = nullptr);
    ~UiSound() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on);
    QString pack() const { return m_pack; }
    void setPack(const QString &pack);
    int level() const { return m_level; }
    void setLevel(int level);
    QStringList packs() const;
    QVariantList levels() const;

    // A cue from the chosen pack. pan: -1 (left) .. 1 (right). Silent when off.
    // One input often raises several cues (⏎ on CONTINUE opens the deck AND moves
    // the focus); they collapse to ONE per event-loop turn, the strongest winning
    // (select > open = back > bump > move), so a view can call this from every
    // place a change happens without double sounds.
    Q_INVOKABLE void play(const QString &cue, qreal pan = 0.0);
    // Drops the cue raised so far this turn: the app's own change (the player
    // closing the queue for UP NEXT) set off a view's open/close watcher.
    Q_INVOKABLE void hush() { m_pending.clear(); }
    // Quiet while a film plays HERE (the author 2026-10-16: the cues talked over it,
    // in the miniplayer as much as full screen). Set by AppController from the
    // engine's play/pause/idle state; paused or casting, the cues speak again.
    // Gates new cues only — one already raised this turn still sounds (⏎'s
    // select as a film starts; the stop cue as it ends).
    void setQuiet(bool on) { m_quiet = on; }
    bool quiet() const { return m_quiet; }
    // Plays even when UI sounds are off — the editor auditioning a pack.
    Q_INVOKABLE void preview(const QString &cue);
    // A short walk in the chosen pack — three moves, a bump, a select — so a
    // pack is heard the way it will be used, not one cue at a time.
    Q_INVOKABLE void demo();
    Q_INVOKABLE QString packNote(const QString &pack) const;
    Q_INVOKABLE void stepPack(int dir);
    Q_INVOKABLE void stepLevel(int dir);

signals:
    void changed();

private:
    struct Clip { std::vector<float> pcm; int rate = 48000; };
    void loadPack();
    std::shared_ptr<const Clip> loadClip(const QString &cue) const;
    void sound(const QString &cue, qreal pan, bool jitter);
    bool ensureOutput();

    AppController *m_app;
    bool m_enabled = true;
    bool m_quiet = false;                // a film is playing locally
    QString m_pack;
    int m_level = 50;
    QHash<QString, std::shared_ptr<const Clip>> m_clips;
    std::unique_ptr<SfxMixer> m_mixer;
    std::unique_ptr<SfxOutput> m_out;
    bool m_outFailed = false;            // no PipeWire here — stop trying
    QTimer m_idle;                       // pauses the stream once nothing has sounded for a while
    QTimer m_demoTimer;
    QStringList m_demoSteps;
    QTimer m_flush;                      // plays the turn's strongest cue
    QString m_pending;
    qreal m_pendingPan = 0;
    QElapsedTimer m_lastStep;            // when the last move/bump tick sounded
};
