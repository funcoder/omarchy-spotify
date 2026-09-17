import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// First-run checklist: your own Spotify app's client ID, then a browser
// login. Playback on this computer (spotifyd) is set up later from Devices,
// so a phone or speaker can be used straight away.
Item {
  id: root

  property var service: null
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property string fontFamily: Style.font.menuFamily

  signal closeRequested()

  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property string dashboardUrl: "https://developer.spotify.com/dashboard"
  readonly property string redirectUri: service && service.status.redirectUri ? service.status.redirectUri : "http://127.0.0.1:8989/callback"

  readonly property bool step1Done: !!(service && service.hasClientId)
  readonly property bool step2Done: !!(service && service.loggedIn)
  property int step: step1Done ? 1 : 0

  onStep1DoneChanged: { step = step1Done ? 1 : 0; focusCurrent() }

  function focusCurrent() {
    Qt.callLater(function() {
      if (step === 0) { clientField.forceActiveFocus(); clientField.selectAll() }
      else keys.forceActiveFocus()
    })
  }

  function copy(text, label) {
    Quickshell.execDetached(["wl-copy", "--", text])
    if (service) service.showFlash("Copied " + label)
  }

  function saveClientId() {
    if (!service) return
    service.setClientId(clientField.text.trim(), function(data) {
      if (!data.error) service.showFlash("Client ID saved")
    })
  }

  function handleCommon(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Escape) { root.closeRequested(); return true }
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) { step = Math.min(1, step + 1); focusCurrent(); return true }
    if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) { step = Math.max(0, step - 1); focusCurrent(); return true }
    if (ctrl && event.key === Qt.Key_O) { service.request("open_url", { url: dashboardUrl }); return true }
    if (ctrl && event.key === Qt.Key_Y) { copy(redirectUri, "the redirect URI"); return true }
    return false
  }

  Item {
    id: keys
    Keys.onPressed: function(event) {
      if (root.handleCommon(event)) { event.accepted = true; return }
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.step === 1) {
        root.service.login()
        event.accepted = true
      }
    }
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width, Style.space(820))
    spacing: Style.spacing.lg

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "Connect your Spotify account"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "Spotify only lets personal players talk to it through an app you register yourself. It takes a minute, is free, and needs Spotify Premium."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // ---- step 1 ----
    StepCard {
      index: 0
      title: "Create a Spotify app and paste its client ID"
      done: root.step1Done

      Column {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.StyledText
          text: "1. Open the Spotify developer dashboard (<b>Ctrl+O</b>) and choose <b>Create app</b>.<br>"
            + "2. Any name. Tick <b>Web API</b>. Redirect URI: <b>" + root.redirectUri + "</b> (<b>Ctrl+Y</b> copies it).<br>"
            + "3. Open the app's settings, copy the <b>Client ID</b> and paste it below, then press <b>Enter</b>."
          color: root.foreground
          linkColor: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          lineHeight: 1.25
        }

        TextField {
          id: clientField
          width: parent.width
          placeholderText: "Client ID (32 characters)"
          text: root.service ? (root.service.status.clientId || "") : ""
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.saveClientId()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
              if (root.step1Done) { root.step = 1; root.focusCurrent() }
              event.accepted = true
            } else if (root.handleCommon(event)) {
              event.accepted = true
            }
          }
        }
      }
    }

    // ---- step 2 ----
    StepCard {
      index: 1
      title: "Log in to Spotify"
      done: root.step2Done
      enabled: root.step1Done
      opacity: enabled ? 1 : 0.45

      Text {
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.StyledText
        text: root.service && root.service.busyStep === "login"
          ? "Waiting for you to approve access in your browser…"
          : "Press <b>Enter</b> to open Spotify's login page. The login is kept in your desktop keyring."
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      width: parent.width
      visible: !!(root.service && root.service.errorText)
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.service ? root.service.errorText : ""
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "Next, to play on this computer, open Devices (d) once you're logged in."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component StepCard: CursorSurface {
    id: card
    property int index: 0
    property string title: ""
    property bool done: false
    default property alias content: body.data

    width: parent ? parent.width : 0
    height: inner.implicitHeight + Style.spacing.lg * 2
    hasCursor: root.step === index
    foreground: root.foreground

    Row {
      id: inner
      x: Style.spacing.lg
      y: Style.spacing.lg
      width: card.width - Style.spacing.lg * 2
      spacing: Style.spacing.lg

      Rectangle {
        width: Style.space(30)
        height: width
        radius: width / 2
        color: card.done ? root.accent : "transparent"
        border.width: 2
        border.color: card.done || root.step === card.index ? root.accent : root.dim
        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: card.done ? "" : String(card.index + 1)
          color: card.done ? Color.menu.background : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      Column {
        width: inner.width - Style.space(30) - inner.spacing
        spacing: Style.spacing.sm
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: card.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Item {
          id: body
          width: parent.width
          implicitHeight: childrenRect.height
          height: implicitHeight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      z: -1
      onClicked: { if (card.enabled) { root.step = card.index; root.focusCurrent() } }
    }
  }
}
