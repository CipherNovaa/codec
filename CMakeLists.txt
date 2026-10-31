cmake_minimum_required(VERSION 3.24)
project(codec VERSION 1.49.0 LANGUAGES CXX)

# Default to an optimized, NDEBUG build. Release only held because
# -DCMAKE_BUILD_TYPE=Release was passed by hand at configure time; a plain
# `cmake ..` from the deploy runbook would otherwise produce an unoptimized
# binary with asserts on.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

add_compile_definitions(CODEC_VERSION="${PROJECT_VERSION}")
# Dev-only: the source tree, so a dev build can hot-reload the baked assets
# straight from assets/mechui/ (see AppController::heroDevDir) — edit a PNG there
# and it live-updates. A shipped build's path won't exist → falls back to qrc.
add_compile_definitions(CODEC_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Qml Quick Sql Concurrent DBus Network ShaderTools)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
# UI sounds (src/uisound.*) play through PipeWire; a machine without libpipewire
# still builds, it just stays silent.
pkg_check_modules(PIPEWIRE QUIET IMPORTED_TARGET libpipewire-0.3)

qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(codec
    src/main.cpp
    src/logger.h src/logger.cpp
    src/playbackengine.h
    src/theme.h src/theme.cpp
    src/resumestore.h src/resumestore.cpp
    src/library.h src/library.cpp
    src/queuemodel.h src/queuemodel.cpp
    src/youtubesource.h src/youtubesource.cpp
    src/livechat.h src/livechat.cpp
    src/sysvolume.h src/sysvolume.cpp
    src/uisound.h src/uisound.cpp
    src/castmanager.h src/castmanager.cpp
    src/designtokens.h
    src/appcontroller.h src/appcontroller.cpp
    src/hubnam.h src/scriptpath.h
    src/mpris.h src/mpris.cpp
    src/mpv/mpvengine.h src/mpv/mpvengine.cpp
    src/mpv/mpvvideoitem.h src/mpv/mpvvideoitem.cpp
)

qt_add_resources(codec "qml"
    PREFIX "/"
    FILES
        qml/Main.qml
        qml/ChooserView.qml
        qml/MediaPathsView.qml
        qml/FolderBrowser.qml
        qml/BootPlate.qml
        qml/PairPrompt.qml
        qml/HubFinder.qml
        qml/HomeView.qml
        qml/LibraryView.qml
        qml/YouTubeView.qml
        qml/YouTubePage.qml
        qml/YtRow.qml
        qml/YtPlate.qml
        qml/YtHexTab.qml
        qml/YtListingHeader.qml
        qml/YtAction.qml
        qml/IconPlate.qml
        qml/QueueSidebar.qml
        qml/OutputPicker.qml
        qml/WatchPartyView.qml
        qml/CastRemote.qml
        qml/ContextMenu.qml
        qml/PlayerView.qml
        qml/SettingsView.qml
        qml/HelpOverlay.qml
        qml/SearchOverlay.qml
        qml/SearchField.qml
        qml/DetailView.qml
        qml/BonusFeatures.qml
        qml/StatsView.qml
        qml/AttractView.qml
        qml/RedactText.qml
        qml/Cascade.qml
        qml/LiveChatPanel.qml
        qml/OsdToast.qml
        qml/Panel.qml
        qml/ShadowText.qml
        qml/MechSelectRow.qml
        qml/SyncMeter.qml
        qml/TickScale.qml
        qml/ReturnGlyph.qml
        qml/MechSlice.qml
        qml/MechPanel.qml
        qml/MechChip.qml
        qml/MechBar.qml
        qml/MechSprite.qml
        qml/MechButton.qml
        qml/MechEditor.qml
        qml/AssetPreview.qml
        qml/MechKeyLegend.qml
        qml/MechSep.qml
        qml/MechStatus.qml
        qml/KeyHints.qml
        assets/globe3d/albedo.png
        assets/globe3d/lights.png
        assets/globe3d/globe.frag
        assets/foot3d/crt.vert
        assets/foot3d/crt.frag
)

# Mech-UI chrome: the curated cut of the purchased Mechs Assets Pack, baked
# by scripts/import_mechui.py (that script is the manifest — re-run it after
# editing the curation; never hand-edit assets/mechui/).
# --- element-group folder layout (drawing clarity) with FLAT resource aliases ---
# PNGs live in assets/mechui/<group>/ so each file is easy to find, but keep their
# original flat resource path (:/assets/mechui/<name>.png) via QT_RESOURCE_ALIAS, so
# QML source strings and the baked binary are byte-identical. hero/ + fonts unchanged.
# Live-edit finds a PNG in ANY subfolder by filename (AppController::heroDevPath).
set_source_files_properties(assets/mechui/plates/queue-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/queue-tex.png)
set_source_files_properties(assets/mechui/plates/osd-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/osd-tex.png)
set_source_files_properties(assets/mechui/plates/pip-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/pip-tex.png)
set_source_files_properties(assets/mechui/plates/search-home-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/search-home-tex.png)
set_source_files_properties(assets/mechui/plates/search-lib-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/search-lib-tex.png)
set_source_files_properties(assets/mechui/plates/search-yt-tex.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/search-yt-tex.png)
set_source_files_properties(assets/mechui/plates/search-yt-tex-hot.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/search-yt-tex-hot.png)
set_source_files_properties(assets/mechui/plates/yt-thumb-frame.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/yt-thumb-frame.png)
set_source_files_properties(assets/mechui/icons/iconbtn-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/iconbtn-idle.png)
set_source_files_properties(assets/mechui/icons/iconbtn-hot.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/iconbtn-hot.png)
set_source_files_properties(assets/mechui/icons/iconbtn-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/iconbtn-press.png)
set_source_files_properties(assets/mechui/icons/iconbtn-on.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/iconbtn-on.png)
set_source_files_properties(assets/mechui/plates/queue-now.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/queue-now.png)
set_source_files_properties(assets/mechui/plates/panel-card.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-card.png)
set_source_files_properties(assets/mechui/plates/panel-body.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-body.png)
set_source_files_properties(assets/mechui/plates/panel-console.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-console.png)
set_source_files_properties(assets/mechui/plates/chip.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/chip.png)
set_source_files_properties(assets/mechui/badges/badge-4k.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-4k.png)
set_source_files_properties(assets/mechui/badges/badge-hdr.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-hdr.png)
set_source_files_properties(assets/mechui/badges/badge-dv.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-dv.png)
set_source_files_properties(assets/mechui/badges/badge-atmos.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-atmos.png)
set_source_files_properties(assets/mechui/badges/badge-71.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-71.png)
set_source_files_properties(assets/mechui/badges/badge-51.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-51.png)
set_source_files_properties(assets/mechui/badges/badge-gen.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/badge-gen.png)
set_source_files_properties(assets/mechui/plates/panel-sq1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-sq1.png)
set_source_files_properties(assets/mechui/plates/panel-sq2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-sq2.png)
set_source_files_properties(assets/mechui/plates/panel-sq3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-sq3.png)
set_source_files_properties(assets/mechui/plates/panel-wide.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-wide.png)
set_source_files_properties(assets/mechui/plates/panel-dlg.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-dlg.png)
set_source_files_properties(assets/mechui/plates/panel-frame.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-frame.png)
set_source_files_properties(assets/mechui/plates/panel-cardframe.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-cardframe.png)
set_source_files_properties(assets/mechui/plates/panel-hollow.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-hollow.png)
set_source_files_properties(assets/mechui/plates/panel-poster.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-poster.png)
set_source_files_properties(assets/mechui/plates/panel-contframe.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-contframe.png)
set_source_files_properties(assets/mechui/plates/panel-conttray.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-conttray.png)
set_source_files_properties(assets/mechui/plates/hdr-capsule.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/hdr-capsule.png)
set_source_files_properties(assets/mechui/plates/panel-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-p2.png)
set_source_files_properties(assets/mechui/plates/panel-dlg-cap.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-dlg-cap.png)
set_source_files_properties(assets/mechui/plates/panel-dlg-body.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-dlg-body.png)
set_source_files_properties(assets/mechui/chevron-tab/stat-tab.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/stat-tab.png)
set_source_files_properties(assets/mechui/chevron-tab/stat-tab-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/stat-tab-hover.png)
set_source_files_properties(assets/mechui/plates/panel-dlg-stats.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/panel-dlg-stats.png)
set_source_files_properties(assets/mechui/chevron-tab/edge-slide.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/edge-slide.png)
set_source_files_properties(assets/mechui/buttons/btn-1-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-1-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-1-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-press.png)
set_source_files_properties(assets/mechui/buttons/btn-2-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-2-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-2-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-press.png)
set_source_files_properties(assets/mechui/buttons/btn-3-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-3-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-3-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-press.png)
set_source_files_properties(assets/mechui/buttons/btn-4-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-4-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-4-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-press.png)
set_source_files_properties(assets/mechui/buttons/btn-5-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-5-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-5-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-press.png)
set_source_files_properties(assets/mechui/buttons/btn-1-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-1-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-1-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-1-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-2-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-2-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-2-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-2-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-3-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-3-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-3-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-3-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-6-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-6-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-6-press.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-press.png)
set_source_files_properties(assets/mechui/buttons/btn-6-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-6-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-6-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-6-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-7-idle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-7-idle.png)
set_source_files_properties(assets/mechui/buttons/btn-7-hover.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-7-hover.png)
set_source_files_properties(assets/mechui/buttons/btn-7-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-7-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-7-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-7-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-7-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-7-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-4-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-4-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-4-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-4-p2.png)
set_source_files_properties(assets/mechui/buttons/btn-5-p0.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-p0.png)
set_source_files_properties(assets/mechui/buttons/btn-5-p1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-p1.png)
set_source_files_properties(assets/mechui/buttons/btn-5-p2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/btn-5-p2.png)
set_source_files_properties(assets/mechui/bars/bar4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar4.png)
set_source_files_properties(assets/mechui/bars/bar6.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar6.png)
set_source_files_properties(assets/mechui/bars/bar5-empty.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar5-empty.png)
set_source_files_properties(assets/mechui/bars/bar5-fill.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar5-fill.png)
set_source_files_properties(assets/mechui/sliders/slider-empty.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/slider-empty.png)
set_source_files_properties(assets/mechui/sliders/slider-fill.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/slider-fill.png)
set_source_files_properties(assets/mechui/sliders/slider-knob.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/slider-knob.png)
set_source_files_properties(assets/mechui/bars/bar-frame.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-frame.png)
set_source_files_properties(assets/mechui/bars/bar-frame-vfd.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-frame-vfd.png)
set_source_files_properties(assets/mechui/bars/bar-fill.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-fill.png)
set_source_files_properties(assets/mechui/bars/bar-fill-l.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-fill-l.png)
set_source_files_properties(assets/mechui/bars/bar-seg.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-seg.png)
set_source_files_properties(assets/mechui/bars/bar-fill-r.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bar-fill-r.png)
set_source_files_properties(assets/mechui/bars/cell-empty.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/cell-empty.png)
set_source_files_properties(assets/mechui/bars/cell-fill.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/cell-fill.png)
set_source_files_properties(assets/mechui/sep/diamond.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/diamond.png)
set_source_files_properties(assets/mechui/chevron-tab/chevron.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/chevron.png)
set_source_files_properties(assets/mechui/icons/icon-alert.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-alert.png)
set_source_files_properties(assets/mechui/icons/icon-back.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-back.png)
set_source_files_properties(assets/mechui/icons/icon-check.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-check.png)
set_source_files_properties(assets/mechui/icons/icon-energy.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-energy.png)
set_source_files_properties(assets/mechui/icons/icon-gear.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-gear.png)
set_source_files_properties(assets/mechui/icons/icon-heart.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-heart.png)
set_source_files_properties(assets/mechui/icons/icon-pause.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-pause.png)
set_source_files_properties(assets/mechui/icons/icon-play.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-play.png)
set_source_files_properties(assets/mechui/icons/icon-search.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-search.png)
set_source_files_properties(assets/mechui/icons/icon-search-hot.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-search-hot.png)
set_source_files_properties(assets/mechui/icons/icon-plus.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-plus.png)
set_source_files_properties(assets/mechui/icons/icon-question.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-question.png)
set_source_files_properties(assets/mechui/icons/icon-shield.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-shield.png)
set_source_files_properties(assets/mechui/icons/icon-sound.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-sound.png)
set_source_files_properties(assets/mechui/icons/icon-square.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-square.png)
set_source_files_properties(assets/mechui/icons/icon-wrench.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-wrench.png)
set_source_files_properties(assets/mechui/icons/icon-x.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/icon-x.png)
set_source_files_properties(assets/mechui/icons/tx-ff.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-ff.png)
set_source_files_properties(assets/mechui/icons/tx-next.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-next.png)
set_source_files_properties(assets/mechui/icons/tx-pause.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-pause.png)
set_source_files_properties(assets/mechui/icons/tx-play.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-play.png)
set_source_files_properties(assets/mechui/icons/tx-prev.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-prev.png)
set_source_files_properties(assets/mechui/icons/tx-rew.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-rew.png)
set_source_files_properties(assets/mechui/icons/tx-stop.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/tx-stop.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-grey-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-grey-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-grey-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-grey-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-grey-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-grey-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-grey-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-grey-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-blue-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-blue-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-blue-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-blue-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-blue-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-blue-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-blue-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-blue-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-cyan-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-cyan-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-cyan-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-cyan-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-cyan-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-cyan-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-cyan-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-cyan-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-green-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-green-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-green-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-green-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-green-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-green-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-green-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-green-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-orange-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-orange-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-orange-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-orange-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-orange-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-orange-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-orange-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-orange-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-pink-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-pink-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-pink-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-pink-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-pink-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-pink-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-pink-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-pink-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-purple-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-purple-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-purple-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-purple-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-purple-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-purple-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-purple-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-purple-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-red-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-red-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-red-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-red-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-red-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-red-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-red-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-red-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-yellow-1.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-yellow-1.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-yellow-2.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-yellow-2.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-yellow-3.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-yellow-3.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-yellow-4.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-yellow-4.png)
set_source_files_properties(assets/mechui/mech-sprites/mech-shadow.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/mech-shadow.png)
set_source_files_properties(assets/mechui/lasers/laser-a-muzzle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-a-muzzle.png)
set_source_files_properties(assets/mechui/lasers/laser-a-core.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-a-core.png)
set_source_files_properties(assets/mechui/lasers/laser-b-muzzle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-b-muzzle.png)
set_source_files_properties(assets/mechui/lasers/laser-b-core.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-b-core.png)
set_source_files_properties(assets/mechui/lasers/laser-c-muzzle.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-c-muzzle.png)
set_source_files_properties(assets/mechui/lasers/laser-c-core.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/laser-c-core.png)
set_source_files_properties(assets/mechui/sep/sep-diamond.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/sep-diamond.png)
set_source_files_properties(assets/mechui/fx/explosion.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/explosion.png)
set_source_files_properties(assets/mechui/fx/rocket.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/rocket.png)
set_source_files_properties(assets/mechui/backdrops/bg-city.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bg-city.png)
set_source_files_properties(assets/mechui/backdrops/bg-desert.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bg-desert.png)
set_source_files_properties(assets/mechui/backdrops/bg-grass.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bg-grass.png)
set_source_files_properties(assets/mechui/backdrops/bg-snow.png PROPERTIES QT_RESOURCE_ALIAS assets/mechui/bg-snow.png)

qt_add_resources(codec "mechui"
    PREFIX "/"
    FILES
        assets/mechui/graph-frame.png
        assets/mechui/fx/card-deploy.png
        assets/mechui/plates/queue-tex.png
        assets/mechui/plates/queue-now.png
        assets/mechui/plates/osd-tex.png
        assets/mechui/plates/pip-tex.png
        assets/mechui/plates/search-home-tex.png
        assets/mechui/plates/search-lib-tex.png
        assets/mechui/plates/search-yt-tex.png
        assets/mechui/plates/search-yt-tex-hot.png
        assets/mechui/plates/yt-thumb-frame.png
        assets/mechui/icons/iconbtn-idle.png
        assets/mechui/icons/iconbtn-hot.png
        assets/mechui/icons/iconbtn-press.png
        assets/mechui/icons/iconbtn-on.png
        assets/mechui/plates/panel-card.png
        assets/mechui/plates/panel-body.png
        assets/mechui/plates/panel-console.png
        assets/mechui/plates/chip.png
        assets/mechui/badges/badge-4k.png
        assets/mechui/badges/badge-hdr.png
        assets/mechui/badges/badge-dv.png
        assets/mechui/badges/badge-atmos.png
        assets/mechui/badges/badge-71.png
        assets/mechui/badges/badge-51.png
        assets/mechui/badges/badge-gen.png
        assets/mechui/plates/panel-sq1.png
        assets/mechui/plates/panel-sq2.png
        assets/mechui/plates/panel-sq3.png
        assets/mechui/plates/panel-wide.png
        assets/mechui/plates/panel-dlg.png
        assets/mechui/plates/panel-frame.png
        assets/mechui/plates/panel-cardframe.png
        assets/mechui/plates/panel-hollow.png
        assets/mechui/plates/panel-poster.png
        assets/mechui/plates/panel-contframe.png
        assets/mechui/plates/panel-conttray.png
        assets/mechui/hero/panel-hero.png
        assets/mechui/hero/hero-pill.png
        assets/mechui/hero/hero-nameplate.png
        assets/mechui/hero/hero-nameplate-alt.png
        assets/mechui/hero/hero-band-1.png
        assets/mechui/hero/hero-band-2.png
        assets/mechui/hero/hero-band-3.png
        assets/mechui/hero/hero-bezel.png
        assets/mechui/hero/hero-hinge-cap.png
        assets/mechui/hero/hero-hinge-cap-b.png
        assets/mechui/plates/hdr-capsule.png
        assets/mechui/plates/panel-p2.png
        assets/mechui/plates/panel-dlg-cap.png
        assets/mechui/plates/panel-dlg-body.png
        assets/mechui/chevron-tab/stat-tab.png
        assets/mechui/chevron-tab/stat-tab-hover.png
        assets/mechui/plates/panel-dlg-stats.png
        assets/mechui/chevron-tab/edge-slide.png
        assets/mechui/buttons/btn-1-idle.png
        assets/mechui/buttons/btn-1-hover.png
        assets/mechui/buttons/btn-1-press.png
        assets/mechui/buttons/btn-2-idle.png
        assets/mechui/buttons/btn-2-hover.png
        assets/mechui/buttons/btn-2-press.png
        assets/mechui/buttons/btn-3-idle.png
        assets/mechui/buttons/btn-3-hover.png
        assets/mechui/buttons/btn-3-press.png
        assets/mechui/buttons/btn-4-idle.png
        assets/mechui/buttons/btn-4-hover.png
        assets/mechui/buttons/btn-4-press.png
        assets/mechui/buttons/btn-5-idle.png
        assets/mechui/buttons/btn-5-hover.png
        assets/mechui/buttons/btn-5-press.png
        assets/mechui/buttons/btn-1-p0.png
        assets/mechui/buttons/btn-1-p1.png
        assets/mechui/buttons/btn-1-p2.png
        assets/mechui/buttons/btn-2-p0.png
        assets/mechui/buttons/btn-2-p1.png
        assets/mechui/buttons/btn-2-p2.png
        assets/mechui/buttons/btn-3-p0.png
        assets/mechui/buttons/btn-3-p1.png
        assets/mechui/buttons/btn-3-p2.png
        assets/mechui/buttons/btn-6-idle.png
        assets/mechui/buttons/btn-6-hover.png
        assets/mechui/buttons/btn-6-press.png
        assets/mechui/buttons/btn-6-p0.png
        assets/mechui/buttons/btn-6-p1.png
        assets/mechui/buttons/btn-6-p2.png
        assets/mechui/buttons/btn-7-idle.png
        assets/mechui/buttons/btn-7-hover.png
        assets/mechui/buttons/btn-7-p0.png
        assets/mechui/buttons/btn-7-p1.png
        assets/mechui/buttons/btn-7-p2.png
        assets/mechui/buttons/btn-4-p0.png
        assets/mechui/buttons/btn-4-p1.png
        assets/mechui/buttons/btn-4-p2.png
        assets/mechui/buttons/btn-5-p0.png
        assets/mechui/buttons/btn-5-p1.png
        assets/mechui/buttons/btn-5-p2.png
        assets/mechui/bars/bar4.png
        assets/mechui/bars/bar6.png
        assets/mechui/bars/bar5-empty.png
        assets/mechui/bars/bar5-fill.png
        assets/mechui/sliders/slider-empty.png
        assets/mechui/sliders/slider-fill.png
        assets/mechui/sliders/slider-knob.png
        assets/mechui/mecha.ttf
        assets/mechui/mecha-bold.ttf
        assets/mechui/mecha-cond.ttf
        assets/mechui/mecha-cond-bold.ttf
        assets/mechui/mgs-codec.ttf
        assets/mechui/mgs-hud.ttf
        assets/mechui/departure-mono.otf
        assets/mechui/mgs-ammo.ttf
        assets/mechui/bars/bar-frame.png
        assets/mechui/bars/bar-frame-vfd.png
        assets/mechui/bars/bar-fill.png
        assets/mechui/bars/bar-fill-l.png
        assets/mechui/bars/bar-seg.png
        assets/mechui/bars/bar-fill-r.png
        assets/mechui/bars/cell-empty.png
        assets/mechui/bars/cell-fill.png
        assets/mechui/sep/diamond.png
        assets/mechui/chevron-tab/chevron.png
        assets/mechui/icons/icon-alert.png
        assets/mechui/icons/icon-back.png
        assets/mechui/icons/icon-check.png
        assets/mechui/icons/icon-energy.png
        assets/mechui/icons/icon-gear.png
        assets/mechui/icons/icon-heart.png
        assets/mechui/icons/icon-pause.png
        assets/mechui/icons/icon-play.png
        assets/mechui/icons/icon-search.png
        assets/mechui/icons/icon-search-hot.png
        assets/mechui/icons/icon-plus.png
        assets/mechui/icons/icon-question.png
        assets/mechui/icons/icon-shield.png
        assets/mechui/icons/icon-sound.png
        assets/mechui/icons/icon-square.png
        assets/mechui/icons/icon-wrench.png
        assets/mechui/icons/icon-x.png
        assets/mechui/icons/tx-ff.png
        assets/mechui/icons/tx-next.png
        assets/mechui/icons/tx-pause.png
        assets/mechui/icons/tx-play.png
        assets/mechui/icons/tx-prev.png
        assets/mechui/icons/tx-rew.png
        assets/mechui/icons/tx-stop.png
        assets/mechui/mech-sprites/mech-grey-1.png
        assets/mechui/mech-sprites/mech-grey-2.png
        assets/mechui/mech-sprites/mech-grey-3.png
        assets/mechui/mech-sprites/mech-grey-4.png
        assets/mechui/mech-sprites/mech-blue-1.png
        assets/mechui/mech-sprites/mech-blue-2.png
        assets/mechui/mech-sprites/mech-blue-3.png
        assets/mechui/mech-sprites/mech-blue-4.png
        assets/mechui/mech-sprites/mech-cyan-1.png
        assets/mechui/mech-sprites/mech-cyan-2.png
        assets/mechui/mech-sprites/mech-cyan-3.png
        assets/mechui/mech-sprites/mech-cyan-4.png
        assets/mechui/mech-sprites/mech-green-1.png
        assets/mechui/mech-sprites/mech-green-2.png
        assets/mechui/mech-sprites/mech-green-3.png
        assets/mechui/mech-sprites/mech-green-4.png
        assets/mechui/mech-sprites/mech-orange-1.png
        assets/mechui/mech-sprites/mech-orange-2.png
        assets/mechui/mech-sprites/mech-orange-3.png
        assets/mechui/mech-sprites/mech-orange-4.png
        assets/mechui/mech-sprites/mech-pink-1.png
        assets/mechui/mech-sprites/mech-pink-2.png
        assets/mechui/mech-sprites/mech-pink-3.png
        assets/mechui/mech-sprites/mech-pink-4.png
        assets/mechui/mech-sprites/mech-purple-1.png
        assets/mechui/mech-sprites/mech-purple-2.png
        assets/mechui/mech-sprites/mech-purple-3.png
        assets/mechui/mech-sprites/mech-purple-4.png
        assets/mechui/mech-sprites/mech-red-1.png
        assets/mechui/mech-sprites/mech-red-2.png
        assets/mechui/mech-sprites/mech-red-3.png
        assets/mechui/mech-sprites/mech-red-4.png
        assets/mechui/mech-sprites/mech-yellow-1.png
        assets/mechui/mech-sprites/mech-yellow-2.png
        assets/mechui/mech-sprites/mech-yellow-3.png
        assets/mechui/mech-sprites/mech-yellow-4.png
        assets/mechui/mech-sprites/mech-shadow.png
        assets/mechui/lasers/laser-a-muzzle.png
        assets/mechui/lasers/laser-a-core.png
        assets/mechui/lasers/laser-b-muzzle.png
        assets/mechui/lasers/laser-b-core.png
        assets/mechui/lasers/laser-c-muzzle.png
        assets/mechui/lasers/laser-c-core.png
        assets/mechui/sep/sep-diamond.png
        assets/mechui/fx/explosion.png
        assets/mechui/fx/rocket.png
        assets/mechui/backdrops/bg-city.png
        assets/mechui/backdrops/bg-desert.png
        assets/mechui/backdrops/bg-grass.png
        assets/mechui/backdrops/bg-snow.png
)

# The full external-pack mirror (assets/mechext, generated wholesale by
# import_mechui.py: every png/gif from every extracted pack at full
# resolution + the manifest.json the editor's asset browser reads at
# runtime). Globbed because the tree is generated — CONFIGURE_DEPENDS
# re-globs on build; re-run the import script when packs change.
file(GLOB_RECURSE MECHEXT_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}
     CONFIGURE_DEPENDS assets/mechext/*)
# Drop editor/backup/OS cruft so a stray file dropped under the tree isn't baked
# into the shipped binary (the glob has no extension filter of its own).
list(FILTER MECHEXT_FILES EXCLUDE REGEX
     "(\\.(bak|orig|tmp|swp|ase|aseprite|xcf|psd|kra)$|~$|/\\.[^/]+$|Thumbs\\.db$|\\.DS_Store$)")
# Viewing guides (scripts/codec_guide_import.py writes them): a fan's map of a
# show, joined onto its episodes by Library on both machines. Globbed: a tree
# may carry none (the public one, until a guide's author says yes).
file(GLOB GUIDE_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS assets/guides/*.json)
if(GUIDE_FILES)
    qt_add_resources(codec "guides"
        PREFIX "/guides"
        BASE "assets/guides"
        FILES ${GUIDE_FILES}
    )
endif()

# YouTube's red SUBSCRIBE pill, rebuilt from a stock image that can't be
# redistributed: baked when present, else YtAction draws a plate.
set(YT_PILL_FILES)
foreach(f idle hot press)
    if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/assets/mechui/plates/yt-subscribe-${f}.png)
        set_source_files_properties(assets/mechui/plates/yt-subscribe-${f}.png
            PROPERTIES QT_RESOURCE_ALIAS assets/mechui/yt-subscribe-${f}.png)
        list(APPEND YT_PILL_FILES assets/mechui/plates/yt-subscribe-${f}.png)
    endif()
endforeach()
if(YT_PILL_FILES)
    qt_add_resources(codec "ytpill" PREFIX "/" FILES ${YT_PILL_FILES})
endif()

# The look codec ships with (scripts/codec_bake_look.py writes it from the author's
# config): read by AppController::loadSettings for keys a config doesn't set.
qt_add_resources(codec "look"
    PREFIX "/look"
    BASE "assets/look"
    FILES
        assets/look/look.json
)

qt_add_resources(codec "mechext"
    PREFIX "/"
    FILES ${MECHEXT_FILES}
)

# UI-chrome PQ encoder for HDR-engaged playback + the RetroTV tube-glass
# pass (qsb-compiled, ShaderEffect).
qt_add_shaders(codec "codec_shaders"
    PREFIX "/"
    FILES qml/shaders/pqencode.frag qml/shaders/crtglass.frag qml/shaders/herocrt.frag qml/shaders/speedobloom.frag qml/shaders/longshadow.frag qml/shaders/headerglow.frag qml/shaders/neonglow.frag
)

# UI sound packs — assets/sfx/<pack>/<cue>.wav, made by scripts/codec_sfx_forge.py
file(GLOB SFX_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS assets/sfx/*/*.wav)
# Konami's MGS menu sounds are baked into EVERY build — the author's call
# (2026-10-16), accepting the small chance of a takedown. If one ever comes,
# -DCODEC_BUNDLE_MGS_SOUNDS=OFF (and deleting assets/sfx/mgs) is the lever:
# codec then defaults to its own "codec" pack, and anyone with their own
# copies can still build the MGS pack into their own folder
# (scripts/codec_sfx_forge.py --mgs-from <folder>).
option(CODEC_BUNDLE_MGS_SOUNDS "bake the MGS sound pack into the binary" ON)
if(NOT CODEC_BUNDLE_MGS_SOUNDS)
    list(FILTER SFX_FILES EXCLUDE REGEX "^assets/sfx/mgs/")
endif()
qt_add_resources(codec "sfx"
    PREFIX "/"
    FILES ${SFX_FILES}
)

target_include_directories(codec PRIVATE src)
target_link_libraries(codec PRIVATE
    Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Sql Qt6::Concurrent Qt6::DBus Qt6::Network
    PkgConfig::MPV
)
if(PIPEWIRE_FOUND)
    target_link_libraries(codec PRIVATE PkgConfig::PIPEWIRE)
    target_compile_definitions(codec PRIVATE CODEC_HAVE_SFX=1)
else()
    message(STATUS "libpipewire not found — UI sounds are built silent")
endif()

install(TARGETS codec RUNTIME DESTINATION bin)
install(DIRECTORY scripts/ DESTINATION share/codec/scripts USE_SOURCE_PERMISSIONS
        PATTERN "__pycache__" EXCLUDE)
