#pragma once

#include <QQuickFramebufferObject>

class MpvEngine;

// Draws the mpv video into the Qt Quick scene graph via mpv's OpenGL
// render API — real GPU video inside a native Wayland window.
class MpvVideoItem : public QQuickFramebufferObject
{
    Q_OBJECT
    Q_PROPERTY(MpvEngine *engine READ engine WRITE setEngine NOTIFY engineChanged)

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);

    Renderer *createRenderer() const override;

    MpvEngine *engine() const { return m_engine; }
    // Dev meter (CODEC_FPS): how many redraws mpv asked for since the last call.
    static int takeUpdateRequests();
    void setEngine(MpvEngine *engine);

signals:
    void engineChanged();

private:
    MpvEngine *m_engine = nullptr;
};
