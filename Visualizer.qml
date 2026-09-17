import QtQuick
import qs.Commons

// Spectrum bars from the service's cava feed. Bars grow from the bottom (or
// out from the middle when `mirrored`), shading from the theme accent at
// rest to the bright foreground at full level.
Item {
  id: root

  property var levels: []
  property int count: levels.length
  property color low: Color.accent
  property color high: Color.foreground
  property bool mirrored: false
  property real gap: 0.35      // fraction of each slot left empty
  property real minimum: 2
  property real radius: -1

  readonly property real slot: count > 0 ? width / count : 0

  Repeater {
    model: root.count
    Rectangle {
      required property int index
      readonly property real v: {
        var src = root.levels
        if (!src || src.length === 0) return 0
        // Resample when the widget wants fewer bars than cava produces.
        var i = Math.floor(index * src.length / root.count)
        return Math.max(0, Math.min(1, src[i] || 0))
      }
      x: index * root.slot + root.slot * root.gap / 2
      width: Math.max(1, root.slot * (1 - root.gap))
      height: Math.max(root.minimum, v * root.height)
      y: root.mirrored ? (root.height - height) / 2 : root.height - height
      radius: root.radius >= 0 ? root.radius : Math.min(width / 2, 3)
      color: Qt.rgba(root.low.r + (root.high.r - root.low.r) * v,
                     root.low.g + (root.high.g - root.low.g) * v,
                     root.low.b + (root.high.b - root.low.b) * v,
                     0.55 + 0.45 * v)
    }
  }
}
