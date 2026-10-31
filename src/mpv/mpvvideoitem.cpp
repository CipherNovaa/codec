#include "mpvvideoitem.h"
#include "mpvengine.h"

#include <mpv/render_gl.h>

#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QQuickWindow>

#include <atomic>

static std::atomic<int> g_mpvUpdateRequests{0};

int MpvVideoItem::takeUpdateRequests() { return g_mpvUpdateRequests.exchange(0); }

namespace {

void *getProcAddress(void *, const char *name)
{
    QOpenGLContext *ctx = QOpenGLContext::currentContext();
    if (!ctx)
        return nullptr;
    return reinterpret_cast<void *>(ctx->getProcAddress(QByteArray(name)));
}

} // namespace

class MpvRenderer : public QQuickFramebufferObject::Renderer
{
public:
    explicit MpvRenderer(const MpvVideoItem *item)
        : m_item(item)
    {
    }

    ~MpvRenderer() override
    {
        qWarning("codec: mpv renderer destroyed (ctx=%p)", static_cast<void *>(m_ctx));
        if (m_ctx)
            mpv_render_context_free(m_ctx);
    }

    QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override
    {
        if (!m_ctx && m_item->engine()) {
            mpv_opengl_init_params glParams{getProcAddress, nullptr};
            mpv_render_param params[]{
                {MPV_RENDER_PARAM_API_TYPE,
                 const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
                {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glParams},
                {MPV_RENDER_PARAM_INVALID, nullptr},
            };
            const int rc = mpv_render_context_create(&m_ctx, m_item->engine()->handle(), params);
            qWarning("codec: mpv render context create -> %d (size %dx%d)", rc,
                     size.width(), size.height());
            if (rc >= 0) {
                mpv_render_context_set_update_callback(m_ctx, onUpdate,
                                                       const_cast<MpvVideoItem *>(m_item));
                MpvEngine *engine = m_item->engine();
                QMetaObject::invokeMethod(engine, [engine] { engine->notifyRenderReady(); },
                                          Qt::QueuedConnection);
            } else {
                m_ctx = nullptr;
            }
        }
        return QQuickFramebufferObject::Renderer::createFramebufferObject(size);
    }

    void render() override
    {
        if (!m_ctx)
            return;
        QOpenGLFramebufferObject *fbo = framebufferObject();
        // Declare the FBO's real format (QQuickFramebufferObject = GL_RGBA8)
        // so mpv's dither targets the true 8-bit depth in HDR output mode.
        constexpr int kGlRgba8 = 0x8058;
        mpv_opengl_fbo mpvFbo{static_cast<int>(fbo->handle()), fbo->width(), fbo->height(),
                              kGlRgba8};
        int flipY = 0;
        // Never block for the video's target display time: the scene graph
        // repaints for UI reasons too (dragging the PiP dock), and blocking
        // here caps the whole window at the video's frame rate.
        int block = 0;
        mpv_render_param params[]{
            {MPV_RENDER_PARAM_OPENGL_FBO, &mpvFbo},
            {MPV_RENDER_PARAM_FLIP_Y, &flipY},
            {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        mpv_render_context_render(m_ctx, params);
    }

private:
    static void onUpdate(void *ctx)
    {
        auto *item = static_cast<MpvVideoItem *>(ctx);
        ++g_mpvUpdateRequests;
        QMetaObject::invokeMethod(item, [item] { item->update(); }, Qt::QueuedConnection);
    }

    const MpvVideoItem *m_item;
    mpv_render_context *m_ctx = nullptr;
};

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent)
{
    // mpv renders top-down into the FBO, which matches how the scene graph
    // samples it — no vertical mirror (verified live: mirroring flips subs too).
}

void MpvVideoItem::setEngine(MpvEngine *engine)
{
    if (engine == m_engine)
        return;
    m_engine = engine;
    emit engineChanged();
    update();
}

QQuickFramebufferObject::Renderer *MpvVideoItem::createRenderer() const
{
    return new MpvRenderer(this);
}
