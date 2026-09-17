import QtQuick
import qs.Commons

// A record with the artwork as its label. Spins up at 33⅓ rpm while playing
// and eases to a stop on pause; the light sheen stays put while the grooves
// turn underneath it.
Item {
  id: root

  property string source: ""
  property bool spinning: false
  property real amount: 1
  property color shadow: Color.background
  property color highlight: Color.accent
  property color peak: Color.foreground
  property real beat: 0

  property real angle: 0
  property real speed: 0

  implicitWidth: 300
  implicitHeight: 300

  FrameAnimation {
    running: root.visible && (root.spinning || root.speed > 0.002)
    onTriggered: {
      var target = root.spinning ? 1 : 0
      var rate = root.spinning ? 1.6 : 1.1
      root.speed += (target - root.speed) * Math.min(1, frameTime * rate)
      if (!root.spinning && root.speed < 0.002) root.speed = 0
      root.angle = (root.angle + root.speed * frameTime * 200) % 360
    }
  }

  Item {
    id: disc
    anchors.centerIn: parent
    width: Math.min(parent.width, parent.height)
    height: width
    rotation: root.angle

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Qt.darker(root.shadow, 1.35)
      border.width: 1
      border.color: Qt.rgba(root.peak.r, root.peak.g, root.peak.b, 0.12)
    }

    // Grooves, plus a faint accent ring that lights up on bass hits.
    Canvas {
      id: grooves
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      property color line: root.peak
      onLineChanged: requestPaint()
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var c = width / 2
        for (var r = width * 0.235; r < c - 3; r += 2.2) {
          var t = (r - width * 0.235) / (c - width * 0.235)
          ctx.strokeStyle = Qt.rgba(line.r, line.g, line.b, 0.035 + 0.035 * Math.sin(t * 37.0) * Math.sin(t * 11.0))
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.arc(c, c, r, 0, Math.PI * 2)
          ctx.stroke()
        }
        // A couple of track gaps.
        ctx.strokeStyle = Qt.rgba(0, 0, 0, 0.35)
        ctx.lineWidth = 2
        var gaps = [0.52, 0.71, 0.86]
        for (var i = 0; i < gaps.length; i++) {
          ctx.beginPath()
          ctx.arc(c, c, c * gaps[i], 0, Math.PI * 2)
          ctx.stroke()
        }
      }
    }

    Artwork {
      id: label
      anchors.centerIn: parent
      width: parent.width * 0.42
      height: width
      circle: true
      hole: 0.07
      sourceSize: 320
      source: root.source
      amount: root.amount
      shadow: root.shadow
      highlight: root.highlight
      peak: root.peak
    }
  }

  // Beat ring around the label.
  Rectangle {
    anchors.centerIn: disc
    width: disc.width * (0.44 + root.beat * 0.03)
    height: width
    radius: width / 2
    color: "transparent"
    border.width: 2
    border.color: root.highlight
    opacity: root.beat * 0.8
  }

  // Static sheen, drawn once.
  Canvas {
    anchors.fill: disc
    property color glint: root.peak
    onGlintChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var c = width / 2
      var g = ctx.createConicalGradient(c, c, Math.PI / 4)
      g.addColorStop(0.0, Qt.rgba(glint.r, glint.g, glint.b, 0.0))
      g.addColorStop(0.08, Qt.rgba(glint.r, glint.g, glint.b, 0.13))
      g.addColorStop(0.16, Qt.rgba(glint.r, glint.g, glint.b, 0.0))
      g.addColorStop(0.5, Qt.rgba(glint.r, glint.g, glint.b, 0.0))
      g.addColorStop(0.58, Qt.rgba(glint.r, glint.g, glint.b, 0.09))
      g.addColorStop(0.66, Qt.rgba(glint.r, glint.g, glint.b, 0.0))
      g.addColorStop(1.0, Qt.rgba(glint.r, glint.g, glint.b, 0.0))
      ctx.fillStyle = g
      ctx.beginPath()
      ctx.arc(c, c, c - 1, 0, Math.PI * 2)
      ctx.arc(c, c, width * 0.215, 0, Math.PI * 2, true)
      ctx.fill()
    }
  }

  // Spindle.
  Rectangle {
    anchors.centerIn: disc
    width: Math.max(6, disc.width * 0.028)
    height: width
    radius: width / 2
    color: root.peak
    opacity: 0.85
  }
}
