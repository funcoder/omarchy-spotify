import QtQuick
import qs.Commons
import qs.Ui

// Bar entry: a Spotify glyph that becomes a tiny live visualizer while music
// plays, plus the song title. Click opens the player, right click
// plays/pauses, middle click skips, scrolling changes the volume.
BarWidget {
  id: root
  moduleName: "funcoder.spotify"

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property bool showTitle: setting("showTitle", true) !== false
  readonly property int maxTitleWidth: Style.space(Number(setting("maxTitleWidth", 220)) || 220)

  readonly property var track: service ? service.track : null
  readonly property bool playing: !!(service && service.playing)
  readonly property string title: track ? track.name + (track.artist ? "  ·  " + track.artist : "") : ""

  // Tell the service a bar wants live data (clock and visualizer).
  property var registeredWith: null
  onServiceChanged: register()
  Component.onCompleted: register()
  Component.onDestruction: if (registeredWith) registeredWith.barWidgets = Math.max(0, registeredWith.barWidgets - 1)
  function register() {
    if (registeredWith === service) return
    if (registeredWith) registeredWith.barWidgets = Math.max(0, registeredWith.barWidgets - 1)
    registeredWith = service
    if (service) service.barWidgets++
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
    text: ""
    tooltipText: root.track
      ? root.track.name + "\n" + root.track.artist + "\n\nClick: open  ·  Right click: play/pause  ·  Middle: next  ·  Scroll: volume"
      : "Spotify  (click to open)"
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton && root.service) root.service.togglePlay()
      else if (b === Qt.MiddleButton && root.service) root.service.next()
      else root.bar.run("omarchy-shell shell toggle funcoder.spotify '{}'")
    }
    onWheelMoved: function(delta) {
      if (root.service && root.service.volume >= 0) root.service.setVolume(root.service.volume + (delta > 0 ? 5 : -5))
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(7)

      Item {
        width: Math.round(button.fontSize * 1.15)
        height: Math.round(button.fontSize * 0.95)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          anchors.centerIn: parent
          visible: !root.playing
          textFormat: Text.PlainText
          text: ""
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
        }

        Visualizer {
          anchors.fill: parent
          visible: root.playing
          levels: root.service && root.service.cavaAvailable ? root.service.levels.slice(1, 25) : fallback.levels
          count: 4
          gap: 0.3
          minimum: 2
          radius: 1
          low: Color.accent
          high: Color.accent
        }
      }

      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showTitle && !root.vertical && root.title !== ""
        width: visible ? Math.min(implicitWidth, root.maxTitleWidth) : 0
        textFormat: Text.PlainText
        text: root.title
        color: button.foreground
        opacity: root.playing ? 1 : 0.55
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        elide: Text.ElideRight
      }
    }
  }

  // Gentle fake bounce when cava isn't installed.
  QtObject {
    id: fallback
    property real t: 0
    readonly property var levels: [0.5 + 0.4 * Math.sin(t * 5.1), 0.5 + 0.45 * Math.sin(t * 3.7 + 1), 0.5 + 0.4 * Math.sin(t * 6.3 + 2), 0.5 + 0.35 * Math.sin(t * 4.2 + 3)]
  }
  FrameAnimation {
    running: root.playing && !(root.service && root.service.cavaAvailable)
    onTriggered: fallback.t += frameTime
  }
}
