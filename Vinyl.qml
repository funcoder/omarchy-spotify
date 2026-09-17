import QtQuick
import qs.Commons

// A record with the artwork as its label. Spins up at 33⅓ rpm while playing
// and eases to a stop on pause; the light sheen stays put while the grooves
// turn underneath it. A tonearm tracks the song: the needle starts on the
// outer groove and creeps towards the label as `progress` goes 0 → 1. It
// lifts, swings and lowers whenever it has to travel (play, pause, seek,
// track change), like a real turntable.
Item {
  id: root

  property string source: ""
  property bool spinning: false
  property real amount: 1
  property color shadow: Color.background
  property color highlight: Color.accent
  property color peak: Color.foreground
  property real beat: 0
  property real progress: 0      // 0..1 through the current song
  property bool armDown: false   // needle on the record

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

  // ---- tonearm -------------------------------------------------------------------

  // Everything below is in units of the disc width, with the disc centre at 0,0.
  readonly property real armPivotX: 0.47
  readonly property real armPivotY: -0.40
  readonly property real armLength: 0.62
  readonly property real outerGroove: 0.455
  readonly property real innerGroove: 0.245
  readonly property real restRadius: 0.585

  // Radius from the centre the needle is heading for, and where it is now.
  readonly property real targetRadius: armDown
    ? outerGroove + (innerGroove - outerGroove) * Math.max(0, Math.min(1, progress))
    : restRadius
  property real needleRadius: restRadius
  property real lift: 0          // 0 set down (on the record or its rest), 1 raised
  property real wobble: 0

  // Angle (degrees) of the arm about its pivot that puts the needle `r` from
  // the centre: law of cosines on pivot, centre and needle.
  function armAngleFor(r) {
    var d = Math.sqrt(armPivotX * armPivotX + armPivotY * armPivotY)
    var L = armLength
    var c = (d * d + L * L - r * r) / (2 * d * L)
    var phi = Math.acos(Math.max(-1, Math.min(1, c)))
    var toCentre = Math.atan2(-armPivotY, -armPivotX)
    return (toCentre - phi) * 180 / Math.PI
  }

  FrameAnimation {
    running: root.visible
    onTriggered: {
      var dt = Math.min(0.05, frameTime)
      var gap = root.targetRadius - root.needleRadius
      // Small gaps (the song playing on) are tracked on the record. Anything
      // bigger means a real move: lift first, travel, then set down.
      var travelling = Math.abs(gap) > 0.006
      var wantLift = travelling ? 1 : 0
      var liftRate = wantLift > root.lift ? 5.5 : 3.2
      root.lift += (wantLift - root.lift) * Math.min(1, dt * liftRate)
      if (!travelling) {
        root.needleRadius = root.targetRadius
      } else if (root.lift > 0.85) {
        // Ease towards the target with a speed cap, like a cueing lever.
        var step = gap * Math.min(1, dt * 2.6)
        var cap = dt * 0.35
        root.needleRadius += Math.max(-cap, Math.min(cap, step))
        if (Math.abs(root.targetRadius - root.needleRadius) < 0.002) root.needleRadius = root.targetRadius
      }
      // A slightly warped record rocks the arm once per revolution.
      root.wobble = root.armDown && root.lift < 0.1 ? Math.sin(root.angle * Math.PI / 180) * 0.35 * root.speed : root.wobble * 0.9
    }
  }

  Item {
    id: arm
    readonly property real unit: disc.width
    x: disc.x + disc.width / 2 + root.armPivotX * unit
    y: disc.y + disc.height / 2 + root.armPivotY * unit
    z: 5

    readonly property real angle: root.armAngleFor(root.needleRadius) + root.wobble
    readonly property real tube: Math.max(2, unit * 0.014)
    readonly property color metal: root.peak

    // Shadow: the arm's silhouette, pushed further away as it lifts.
    Item {
      x: arm.unit * (0.008 + root.lift * 0.018)
      y: arm.unit * (0.012 + root.lift * 0.03)
      rotation: arm.angle
      transformOrigin: Item.TopLeft
      opacity: 0.4 - root.lift * 0.15

      Rectangle {
        x: 0; y: -arm.tube / 2
        width: arm.unit * root.armLength * 0.8
        height: arm.tube
        radius: height / 2
        color: "black"
      }
      Rectangle {
        x: arm.unit * root.armLength * 0.78
        y: -arm.tube * 1.4
        width: arm.unit * root.armLength * 0.24
        height: arm.tube * 2.8
        radius: 2
        color: "black"
      }
    }

    // The arm itself.
    Item {
      rotation: arm.angle
      transformOrigin: Item.TopLeft
      scale: 1 + root.lift * 0.015

      // Counterweight behind the pivot.
      Rectangle {
        x: -arm.unit * 0.13
        y: -arm.unit * 0.028
        width: arm.unit * 0.075
        height: arm.unit * 0.056
        radius: 3
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.lighter(root.shadow, 2.2) }
          GradientStop { position: 1; color: Qt.darker(root.shadow, 1.2) }
        }
        border.width: 1
        border.color: Qt.rgba(arm.metal.r, arm.metal.g, arm.metal.b, 0.25)
      }
      Rectangle {
        x: -arm.unit * 0.06
        y: -arm.tube * 0.4
        width: arm.unit * 0.06
        height: arm.tube * 0.8
        color: Qt.rgba(arm.metal.r, arm.metal.g, arm.metal.b, 0.6)
      }

      // Tube, with a highlight along its top.
      Rectangle {
        x: 0; y: -arm.tube / 2
        width: arm.unit * root.armLength * 0.8
        height: arm.tube
        radius: height / 2
        gradient: Gradient {
          GradientStop { position: 0; color: Qt.lighter(arm.metal, 1.15) }
          GradientStop { position: 0.5; color: arm.metal }
          GradientStop { position: 1; color: Qt.darker(arm.metal, 1.8) }
        }
      }

      // Headshell and cartridge; the needle tip sits exactly armLength out.
      Rectangle {
        x: arm.unit * root.armLength * 0.78
        y: -arm.tube * 1.4
        width: arm.unit * root.armLength * 0.22
        height: arm.tube * 2.8
        radius: 2
        color: Qt.darker(root.shadow, 1.1)
        border.width: 1
        border.color: Qt.rgba(arm.metal.r, arm.metal.g, arm.metal.b, 0.5)

        Rectangle {
          anchors.right: parent.right
          anchors.rightMargin: -1
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width * 0.45
          height: parent.height * 0.62
          radius: 1
          color: root.highlight
        }
      }

      // Finger lift.
      Rectangle {
        x: arm.unit * root.armLength * 0.86
        y: -arm.tube * 3.2
        width: arm.tube * 0.8
        height: arm.tube * 2
        radius: width / 2
        color: Qt.rgba(arm.metal.r, arm.metal.g, arm.metal.b, 0.7)
      }

      // Needle glint where it meets the record.
      Rectangle {
        x: arm.unit * root.armLength - width / 2
        y: -width / 2
        width: Math.max(3, arm.tube * 0.9)
        height: width
        radius: width / 2
        color: root.highlight
        opacity: 1 - root.lift
      }
    }

    // Pivot base, drawn over the arm's root.
    Rectangle {
      x: -width / 2; y: -height / 2
      width: arm.unit * 0.1
      height: width
      radius: width / 2
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.lighter(root.shadow, 2.4) }
        GradientStop { position: 1; color: Qt.darker(root.shadow, 1.3) }
      }
      border.width: 1
      border.color: Qt.rgba(arm.metal.r, arm.metal.g, arm.metal.b, 0.3)

      Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.42
        height: width
        radius: width / 2
        color: arm.metal
        opacity: 0.85
      }
    }
  }
}
