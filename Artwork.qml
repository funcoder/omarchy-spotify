import QtQuick
import qs.Commons

// Album art pushed through the theme duotone shader. A new `source`
// crossfades in over the old one once it has loaded, so track changes never
// flash an empty square. `amount` 1 is fully omarchified, 0 the original.
Item {
  id: root

  property string source: ""
  property real amount: 1
  property real contrast: 1.15
  property bool circle: false
  property real hole: 0
  property color shadow: Color.background
  property color highlight: Color.accent
  property color peak: Color.foreground
  property string placeholderGlyph: ""
  property int sourceSize: 640
  property int fadeDuration: 420

  Behavior on amount { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

  // 0 or 1: which layer is on top.
  property int front: 0
  readonly property bool hasImage: layerA.image.status === Image.Ready || layerB.image.status === Image.Ready

  onSourceChanged: {
    var back = front === 0 ? layerB : layerA
    if ((front === 0 ? layerA : layerB).image.source.toString() === source) return
    back.image.source = source
  }

  Component.onCompleted: layerA.image.source = source

  function promote(layer) {
    var top = layer === layerA ? 0 : 1
    if (top === front && layer.opacity === 1) return
    front = top
    layer.z = 1
    ;(layer === layerA ? layerB : layerA).z = 0
    fade.target = layer
    fade.restart()
  }

  NumberAnimation {
    id: fade
    property: "opacity"
    from: 0
    to: 1
    duration: root.fadeDuration
    easing.type: Easing.InOutQuad
  }

  // Placeholder: a theme-coloured tile with a note glyph.
  Rectangle {
    anchors.fill: parent
    visible: !root.hasImage
    radius: root.circle ? width / 2 : Style.cornerRadius
    color: root.shadow
    border.width: 1
    border.color: Qt.rgba(root.highlight.r, root.highlight.g, root.highlight.b, 0.25)

    Text {
      anchors.centerIn: parent
      text: root.placeholderGlyph
      color: root.highlight
      opacity: 0.6
      font.family: Style.font.menuFamily
      font.pixelSize: Math.max(10, parent.height * 0.36)
    }
  }

  component Layer: Item {
    id: layer
    property alias image: img
    anchors.fill: parent
    opacity: 0

    Image {
      id: img
      anchors.fill: parent
      visible: false
      asynchronous: true
      cache: true
      fillMode: Image.PreserveAspectCrop
      sourceSize.width: root.sourceSize
      sourceSize.height: root.sourceSize
      onStatusChanged: if (status === Image.Ready) root.promote(layer)
    }

    ShaderEffect {
      anchors.fill: parent
      visible: img.status === Image.Ready
      property var source: img
      property color shadow: root.shadow
      property color highlight: root.highlight
      property color peak: root.peak
      property real amount: root.amount
      property real contrast: root.contrast
      property real circle: root.circle ? 1 : 0
      property real hole: root.hole
      fragmentShader: Qt.resolvedUrl("shaders/duotone.frag.qsb")
    }
  }

  Layer { id: layerA }
  Layer { id: layerB }
}
