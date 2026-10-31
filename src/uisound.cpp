#include "uisound.h"
#include <QStandardPaths>

#include "appcontroller.h"

#include <QFile>
#include <QMutex>
#include <QMutexLocker>
#include <QRandomGenerator>
#include <QtEndian>
#include <algorithm>
#include <utility>
#include <cmath>

#ifdef CODEC_HAVE_SFX
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#endif

namespace {

// The packs, in the order the editor's NAV SOUND dial walks them. The first is
// the default.
struct PackInfo { const char *key; const char *note; };
constexpr PackInfo kPacks[] = {
    { "mgs",     "Metal Gear Solid's own: the item blip, the codec opening and closing" },
    { "codec",   "square-wave codec blips, crushed to 8-bit" },
    { "garage",  "the Armored Core hangar: relay clicks, servo whine, hydraulic hiss" },
    { "tick",    "soft wooden ticks, the least tiring to hear all night" },
    { "scanner", "HUD lock-on beeps with a radar shimmer" },
    { "psx",     "a warm FM chime with a little room, the 32-bit console menu" },
    { "glass",   "struck glass, bright and inharmonic: the menu glass as a sound" },
};
constexpr const char *kCues[] = { "move", "bump", "select", "back", "open" };
constexpr int kLevels[] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };

// 16-bit PCM WAV → mono float. The forge writes nothing else.
bool parseWav(const QByteArray &b, std::vector<float> &out, int &rate)
{
    if (b.size() < 44 || !b.startsWith("RIFF") || b.mid(8, 4) != "WAVE")
        return false;
    int tag = 0, ch = 0, bits = 0;
    rate = 0;
    qsizetype p = 12;
    while (p + 8 <= b.size()) {
        const QByteArray id = b.mid(p, 4);
        qsizetype len = qFromLittleEndian<quint32>(b.constData() + p + 4);
        const char *d = b.constData() + p + 8;
        len = qMin(len, b.size() - p - 8);
        if (id == "fmt " && len >= 16) {
            tag = qFromLittleEndian<quint16>(d);
            ch = qFromLittleEndian<quint16>(d + 2);
            rate = int(qFromLittleEndian<quint32>(d + 4));
            bits = qFromLittleEndian<quint16>(d + 14);
        } else if (id == "data" && tag == 1 && bits == 16 && ch > 0 && rate > 0) {
            const qsizetype frames = len / (2 * ch);
            out.resize(size_t(frames));
            for (qsizetype i = 0; i < frames; ++i) {
                float s = 0;
                for (int c = 0; c < ch; ++c)
                    s += qFromLittleEndian<qint16>(d + 2 * (i * ch + c)) / 32768.f;
                out[size_t(i)] = s / ch;
            }
            return frames > 1;
        }
        p += 8 + len + (len & 1);
    }
    return false;
}

} // namespace

// The sounding cues, summed into stereo float for whoever pulls — PipeWire's
// data thread. Voices arrive from the GUI thread, so the list is behind a lock
// held for one short buffer.
class SfxMixer
{
public:
    struct Voice {
        std::shared_ptr<const std::vector<float>> pcm;
        double pos = 0, step = 1;
        float gl = 0, gr = 0;
    };
    void add(Voice v)
    {
        QMutexLocker l(&m_mu);
        if (m_voices.size() >= 12)            // a held key: the oldest tail gives way
            m_voices.erase(m_voices.begin());
        m_voices.push_back(std::move(v));
    }
    bool silent() const
    {
        QMutexLocker l(&m_mu);
        return m_voices.empty();
    }
    // `frames` interleaved L/R floats into `out`, overwriting it
    void mix(float *out, uint32_t frames)
    {
        std::fill(out, out + size_t(frames) * 2, 0.f);
        QMutexLocker l(&m_mu);
        for (auto it = m_voices.begin(); it != m_voices.end();) {
            Voice &v = *it;
            const std::vector<float> &a = *v.pcm;
            const double last = double(a.size() - 1);
            for (uint32_t i = 0; i < frames && v.pos < last; ++i, v.pos += v.step) {
                const size_t k = size_t(v.pos);
                const float s = a[k] + (a[k + 1] - a[k]) * float(v.pos - double(k));
                out[2 * i] += s * v.gl;
                out[2 * i + 1] += s * v.gr;
            }
            it = v.pos >= last ? m_voices.erase(it) : it + 1;
        }
        for (size_t i = 0; i < size_t(frames) * 2; ++i)
            out[i] = std::clamp(out[i], -1.f, 1.f);
    }

private:
    mutable QMutex m_mu;
    std::vector<Voice> m_voices;
};

#ifdef CODEC_HAVE_SFX
// One PipeWire playback stream on its own thread loop: F32 stereo at 48 kHz (the
// clips' rate; PipeWire converts for the device), autoconnected to the default
// output and moved when the default moves. Created PAUSED and only run while
// something sounds — a paused node lets the device suspend.
class SfxOutput
{
public:
    explicit SfxOutput(SfxMixer *mixer) : m_mixer(mixer) {}
    ~SfxOutput()
    {
        if (m_loop) {
            pw_thread_loop_lock(m_loop);
            if (m_stream) pw_stream_destroy(m_stream);
            pw_thread_loop_unlock(m_loop);
            pw_thread_loop_stop(m_loop);
            pw_thread_loop_destroy(m_loop);
        }
        if (m_inited) pw_deinit();
    }
    bool start()
    {
        pw_init(nullptr, nullptr);
        m_inited = true;
        m_loop = pw_thread_loop_new("codec-sfx", nullptr);
        if (!m_loop) return false;
        m_events.version = PW_VERSION_STREAM_EVENTS;
        m_events.process = &SfxOutput::onProcess;
        pw_thread_loop_lock(m_loop);
        bool ok = pw_thread_loop_start(m_loop) >= 0;
        if (ok) {
            pw_properties *props = pw_properties_new(
                PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
                PW_KEY_APP_NAME, "codec", PW_KEY_NODE_NAME, "codec-ui-sounds",
                PW_KEY_MEDIA_NAME, "UI sounds", nullptr);
            m_stream = pw_stream_new_simple(pw_thread_loop_get_loop(m_loop), "codec UI sounds",
                                            props, &m_events, this);
            ok = m_stream != nullptr;
        }
        if (ok) {
            uint8_t buf[1024];
            spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof(buf));
            spa_audio_info_raw info{};
            info.format = SPA_AUDIO_FORMAT_F32;
            info.rate = kRate;
            info.channels = 2;
            info.position[0] = SPA_AUDIO_CHANNEL_FL;
            info.position[1] = SPA_AUDIO_CHANNEL_FR;
            const spa_pod *params[1] = { spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info) };
            ok = pw_stream_connect(m_stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                   pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS
                                                   | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE),
                                   params, 1) >= 0;
        }
        pw_thread_loop_unlock(m_loop);
        return ok;
    }
    void setActive(bool on)
    {
        if (!m_stream || on == m_active) return;
        m_active = on;
        pw_thread_loop_lock(m_loop);
        pw_stream_set_active(m_stream, on);
        pw_thread_loop_unlock(m_loop);
    }
    static constexpr int kRate = 48000;

private:
    static void onProcess(void *data)
    {
        auto *self = static_cast<SfxOutput *>(data);
        pw_buffer *b = pw_stream_dequeue_buffer(self->m_stream);
        if (!b) return;
        spa_data &d = b->buffer->datas[0];
        if (d.data) {
            constexpr uint32_t stride = 2 * sizeof(float);
            uint32_t frames = d.maxsize / stride;
            if (b->requested) frames = std::min<uint32_t>(frames, uint32_t(b->requested));
            self->m_mixer->mix(static_cast<float *>(d.data), frames);
            d.chunk->offset = 0;
            d.chunk->stride = stride;
            d.chunk->size = frames * stride;
        }
        pw_stream_queue_buffer(self->m_stream, b);
    }

    SfxMixer *m_mixer;
    pw_thread_loop *m_loop = nullptr;
    pw_stream *m_stream = nullptr;
    pw_stream_events m_events{};
    bool m_inited = false;
    bool m_active = false;
};
#else
class SfxOutput {};
#endif

UiSound::UiSound(AppController *app, QObject *parent)
    : QObject(parent), m_app(app), m_mixer(std::make_unique<SfxMixer>())
{
    m_enabled = m_app->getSetting(QStringLiteral("uiSounds"), true).toBool();
    m_level = qBound(10, m_app->getSetting(QStringLiteral("uiSoundLevel"), 50).toInt(), 100);
    const QString saved = m_app->getSetting(QStringLiteral("uiSoundPack")).toString();
    // the saved pack, else the first one actually here (MGS where it is,
    // otherwise codec's own blips)
    const QStringList here = packs();
    m_pack = here.contains(saved) ? saved
           : (here.isEmpty() ? QString::fromLatin1(kPacks[0].key) : here.first());
    loadPack();

    m_idle.setSingleShot(true);
    m_idle.setInterval(3000);
    connect(&m_idle, &QTimer::timeout, this, [this] {
        if (!m_mixer->silent()) { m_idle.start(); return; }
#ifdef CODEC_HAVE_SFX
        if (m_out) m_out->setActive(false);
#endif
    });
    // Connect a moment after launch — clear of start-up itself, and before the
    // first press, which then only wakes a stream that's already linked.
    QTimer::singleShot(1500, this, [this] { if (m_enabled) ensureOutput(); });
    m_flush.setSingleShot(true);
    m_flush.setInterval(0);
    connect(&m_flush, &QTimer::timeout, this, [this] {
        const QString cue = std::exchange(m_pending, QString());
        if (cue.isEmpty())
            return;
        const bool step = cue == QLatin1String("move") || cue == QLatin1String("bump");
        if (step) {
            // A HELD nav key repeats ~25×/s (Hyprland's rate) and the 135-ms
            // tick stacked 3-4 deep into a buzz ("spam"). Rapid, not a
            // spray: one step tick per 100 ms — every third repeat (~8/s).
            constexpr qint64 kStepGapMs = 100;
            if (m_lastStep.isValid() && m_lastStep.elapsed() < kStepGapMs)
                return;
            m_lastStep.restart();
        }
        sound(cue, m_pendingPan, step);
    });
    m_demoTimer.setSingleShot(true);
    connect(&m_demoTimer, &QTimer::timeout, this, [this] {
        if (m_demoSteps.isEmpty()) return;
        const QString cue = m_demoSteps.takeFirst();
        static const qreal pans[] = { -0.3, 0.0, 0.3, 0.3, 0.0 };
        sound(cue, pans[qMax(0, 4 - int(m_demoSteps.size()))], cue == QLatin1String("move"));
        if (!m_demoSteps.isEmpty()) {
            m_demoTimer.setInterval(m_demoSteps.first() == QLatin1String("select") ? 280 : 130);
            m_demoTimer.start();
        }
    });
}

UiSound::~UiSound() = default;   // SfxOutput stops PipeWire's thread before the mixer goes

void UiSound::setEnabled(bool on)
{
    if (on == m_enabled) return;
    m_enabled = on;
    m_app->putSetting(QStringLiteral("uiSounds"), on);
    emit changed();
}

void UiSound::setPack(const QString &pack)
{
    if (!packs().contains(pack)) return;
    // re-picking the same pack still re-reads it: on a dev build that's how a
    // freshly forged take is heard
    const bool same = pack == m_pack;
    m_pack = pack;
    loadPack();
    if (same) return;
    m_app->putSetting(QStringLiteral("uiSoundPack"), pack);
    emit changed();
}

void UiSound::setLevel(int level)
{
    level = qBound(10, level, 100);
    if (level == m_level) return;
    m_level = level;
    m_app->putSetting(QStringLiteral("uiSoundLevel"), level);
    emit changed();
}

// Where a pack's cue lives: a person's own folder (a pack they built, like the
// MGS one from their own copies — codec_sfx_forge.py --mgs-from), the source
// tree (a dev build: a re-forged pack plays at once), or the copy built in.
// Every build carries all the packs today; a pack is offered only where one
// of these has it, so a build without the MGS files (the takedown lever,
// CODEC_BUNDLE_MGS_SOUNDS) quietly falls back to codec's own.
static QString cuePath(const QString &pack, const QString &cue)
{
    const QString rel = QStringLiteral("sfx/") + pack + QLatin1Char('/') + cue + QStringLiteral(".wav");
    const QString own = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)
                        + QLatin1Char('/') + rel;
    if (QFile::exists(own)) return own;
    const QString dev = QStringLiteral(CODEC_SOURCE_DIR "/assets/") + rel;
    if (QFile::exists(dev)) return dev;
    const QString baked = QStringLiteral(":/assets/") + rel;
    return QFile::exists(baked) ? baked : QString();
}

QStringList UiSound::packs() const
{
    QStringList out;
    for (const PackInfo &p : kPacks) {
        const QString key = QString::fromLatin1(p.key);
        if (!cuePath(key, QStringLiteral("select")).isEmpty())
            out << key;
    }
    return out;
}

QVariantList UiSound::levels() const
{
    QVariantList out;
    for (int l : kLevels) out << l;
    return out;
}

QString UiSound::packNote(const QString &pack) const
{
    for (const PackInfo &p : kPacks)
        if (pack == QLatin1String(p.key)) return QString::fromUtf8(p.note);
    return {};
}

void UiSound::stepPack(int dir)
{
    const QStringList all = packs();
    const int i = qMax(0, int(all.indexOf(m_pack)));
    setPack(all.at(((i + dir) % all.size() + all.size()) % all.size()));
}

void UiSound::stepLevel(int dir)
{
    const int n = int(std::size(kLevels));
    int i = 0;
    while (i < n - 1 && kLevels[i] < m_level) ++i;
    setLevel(kLevels[qBound(0, i + dir, n - 1)]);
}

void UiSound::play(const QString &cue, qreal pan)
{
    if (!m_enabled || m_quiet) return;
    const auto rank = [](const QString &c) {
        return c == QLatin1String("select") ? 3 : c == QLatin1String("open") || c == QLatin1String("back") ? 2
             : c == QLatin1String("bump") ? 1 : 0;
    };
    if (m_pending.isEmpty() || rank(cue) >= rank(m_pending)) {
        m_pending = cue;
        m_pendingPan = pan;
    }
    if (!m_flush.isActive()) m_flush.start();
}

void UiSound::preview(const QString &cue)
{
    m_demoTimer.stop();
    m_demoSteps.clear();
    sound(cue, 0.0, false);
}

void UiSound::demo()
{
    m_demoSteps = { QStringLiteral("move"), QStringLiteral("move"), QStringLiteral("move"),
                    QStringLiteral("bump"), QStringLiteral("select") };
    m_demoTimer.setInterval(0);
    m_demoTimer.start();
}

std::shared_ptr<const UiSound::Clip> UiSound::loadClip(const QString &cue) const
{
    const QString path = cuePath(m_pack, cue);
    if (path.isEmpty()) return nullptr;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return nullptr;
    auto clip = std::make_shared<Clip>();
    if (!parseWav(f.readAll(), clip->pcm, clip->rate)) {
        qWarning("[sfx] unreadable %s", qPrintable(path));
        return nullptr;
    }
    return clip;
}

void UiSound::loadPack()
{
    m_clips.clear();
    for (const char *cue : kCues) {
        const QString c = QString::fromLatin1(cue);
        if (auto clip = loadClip(c)) m_clips.insert(c, clip);
    }
}

void UiSound::sound(const QString &cue, qreal pan, bool jitter)
{
    // CODEC_SFX_LOG=1 prints every cue that SOUNDS (each turn's winner, the
    // editor's previews) — checking a view's cues headlessly, where there's no audio
    static const bool log = qEnvironmentVariableIsSet("CODEC_SFX_LOG");
    if (log) qInfo("[sfx] %s pan=%.2f", qPrintable(cue), pan);
#ifdef CODEC_HAVE_SFX
    const auto clip = m_clips.value(cue);
    if (!clip || !ensureOutput()) return;
    SfxMixer::Voice v;
    // share the samples with the voice without copying them
    v.pcm = std::shared_ptr<const std::vector<float>>(clip, &clip->pcm);
    v.step = double(clip->rate) / SfxOutput::kRate;
    if (jitter)   // ±1.5% — a run of the same tick doesn't read as a machine gun
        v.step *= 1.0 + (QRandomGenerator::global()->generateDouble() - 0.5) * 0.03;
    // the level dial is perceptual-ish (square law: 50% ≈ -12 dB); the pan is
    // constant-power, normalised so a centred cue plays at full level
    const double g = std::pow(m_level / 100.0, 2.0);
    const double a = (qBound(-1.0, double(pan), 1.0) + 1.0) * M_PI / 4.0;
    v.gl = float(g * std::cos(a) * M_SQRT2);
    v.gr = float(g * std::sin(a) * M_SQRT2);
    m_mixer->add(std::move(v));
    m_out->setActive(true);
    m_idle.start();
#else
    Q_UNUSED(cue) Q_UNUSED(pan) Q_UNUSED(jitter)
#endif
}

bool UiSound::ensureOutput()
{
#ifdef CODEC_HAVE_SFX
    if (m_out) return true;
    if (m_outFailed) return false;
    m_out = std::make_unique<SfxOutput>(m_mixer.get());
    if (!m_out->start()) {
        qWarning("[sfx] no PipeWire output — UI sounds stay silent");
        m_out.reset();
        m_outFailed = true;
        return false;
    }
    return true;
#else
    return false;
#endif
}
