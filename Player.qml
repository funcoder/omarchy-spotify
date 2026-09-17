import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Spotify, the Omarchy way: one keyboard-driven window.
//
// Left: the now-playing stage (sleeve + spinning vinyl, theme-duotone art,
// ambient glow and a cava visualizer). Right: tabs for playlists, liked
// songs, recently played, the queue, search and devices. The playlist that's
// playing is pinned to the top of Playlists, and `c` jumps straight into it.
//
// Keys: ↑↓/jk move · Enter play/open · Shift+Enter play a playlist without
// opening it · Esc/Backspace back · Tab/1-6 tabs · / search ·
// Space play/pause · ←→ seek · n/p next/previous · +/- volume · m mute ·
// s shuffle · r repeat · l like playing track · a add to queue ·
// c open what's playing · o toggle omarchified art
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "funcoder.spotify"
  // Injected by the shell from our service entry point.
  property var service: null

  property bool opened: false

  // ---- style ------------------------------------------------------------------
  // Opaque: menu backgrounds can be translucent, which suits popups, not windows.
  property color background: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 1)
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color accent: Color.accent
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.3)
  readonly property color shadowTone: service ? service.shadowTone : Qt.darker(background, 1.4)
  readonly property color peakTone: service ? service.peakTone : foreground
  property string fontFamily: Style.font.menuFamily
  property int gap: Style.spacing.lg
  readonly property string windowTitle: "Spotify"
  property bool closingFromHost: false
  property int rowHeight: Style.font.body + Style.font.caption + Style.spacing.controlPaddingY * 2 + Style.space(16)

  // Tiled windows can be small: tabs lose their labels when compact, and the
  // stage stacks above the browser when narrow.
  readonly property bool compact: panel.width < Style.space(1100)
  readonly property bool narrow: panel.width < Style.space(820)

  property bool omarchify: true
  readonly property real artAmount: omarchify ? 1 : 0

  // Nerd Font glyphs.
  readonly property var glyph: ({
    spotify: "", play: "", pause: "", next: "", prev: "",
    shuffle: "", repeat: "", heart: "", heartEmpty: "",
    volume: "", mute: "", list: "", search: "", device: "",
    speaker: "", phone: "", clock: "", queue: "", back: "",
    music: "", user: "", check: "", dot: "", key: "", disc: ""
  })

  // ---- tabs & data ---------------------------------------------------------------
  readonly property var tabs: [
    { id: "playlists", label: "Playlists", glyph: glyph.list },
    { id: "liked", label: "Liked", glyph: glyph.heart },
    { id: "recent", label: "Recent", glyph: glyph.clock },
    { id: "queue", label: "Queue", glyph: glyph.queue },
    { id: "search", label: "Search", glyph: glyph.search },
    { id: "devices", label: "Devices", glyph: glyph.device }
  ]
  property string tab: "playlists"
  property var detail: null       // { playlist, tracks, restricted, loading, error }
  property var data: ({})         // tab id -> { items, loading, error, loadedAt }
  property string query: ""
  property var searchResults: null
  property bool searching: false
  property int selectedIndex: 0
  property var selectionMemory: ({})

  readonly property bool setupNeeded: !service || !service.statusLoaded || !service.ready

  readonly property var rows: {
    if (!service) return []
    var t = service.track, ctx = service.player.contextUri || ""
    if (detail) return detailRows()
    var d = data[tab] || {}
    if (tab === "playlists") {
      var items = (d.items || []).slice()
      var current = null
      for (var i = 0; i < items.length; i++) if (items[i].uri === ctx) { current = items.splice(i, 1)[0]; break }
      var out = []
      if (current) out.push(Object.assign({ section: "Now playing" }, current))
      for (var j = 0; j < items.length; j++) out.push(Object.assign({ section: "Your playlists" }, items[j]))
      return out
    }
    if (tab === "queue") {
      var q = []
      if (d.current) q.push(Object.assign({ section: "Now playing" }, d.current))
      var list = d.items || []
      for (var k = 0; k < list.length; k++) q.push(Object.assign({ section: "Up next" }, list[k]))
      return q
    }
    if (tab === "search") {
      var r = searchResults
      if (!r) return []
      var s = []
      var groups = [["Songs", r.tracks], ["Playlists", r.playlists], ["Albums", r.albums], ["Artists", r.artists]]
      for (var g = 0; g < groups.length; g++) {
        var xs = groups[g][1] || []
        for (var n = 0; n < xs.length; n++) s.push(Object.assign({ section: groups[g][0] }, xs[n]))
      }
      return s
    }
    if (tab === "devices") {
      var devs = (d.items || []).map(function(x) { return Object.assign({ kind: "device", section: "Spotify Connect" }, x) })
      var local = service.local || {}
      var online = devs.some(function(x) { return x.name === local.name })
      if (!online) devs.unshift({ kind: "local", section: "This computer", name: local.name || "Omarchy", id: "" })
      return devs
    }
    return (d.items || []).map(function(x) { return Object.assign({ section: "" }, x) })
  }

  function detailRows() {
    var out = [{ kind: "action", section: "", name: "Play " + (detail.playlist.type === "album" ? "album" : "playlist"), uri: detail.playlist.uri }]
    if (detail.restricted) {
      out.push({ kind: "notice", section: "", name: "Spotify only lists the songs of playlists you own or collaborate on.",
        owner: "Enter plays it. Once it's playing, the Queue tab (4) shows what's coming up." })
    }
    var tracks = detail.tracks || []
    for (var i = 0; i < tracks.length; i++) out.push(Object.assign({ section: "", position: i + 1 }, tracks[i]))
    return out
  }

  readonly property var selectedRow: selectedIndex >= 0 && selectedIndex < rows.length ? rows[selectedIndex] : null

  onRowsChanged: if (selectedIndex >= rows.length) selectedIndex = Math.max(0, rows.length - 1)

  // ---- open / close ----------------------------------------------------------------

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (opened) raise()
    opened = true
    if (service) {
      service.overlayOpen = true
      service.refreshStatus()
      service.pollNow()
    }
    if (payload.tab) switchTab(payload.tab)
    else refreshTab(false)
    focusKeys()
  }

  // Host-initiated close (`shell hide`): the shell already knows.
  function close() {
    closingFromHost = true
    opened = false
    closingFromHost = false
    if (service) service.overlayOpen = false
  }

  // User-initiated close; tells the shell so `toggle` stays in step.
  function dismiss() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // Summoned while already open (maybe on another workspace): bring it here.
  function raise() {
    Quickshell.execDetached(["bash", "-c",
      "a=$(hyprctl clients -j | jq -r --arg t \"$1\" 'first(.[] | select(.title == $t) | .address) // empty'); "
      + "[ -n \"$a\" ] && hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$a\\\" })\"",
      "raise", windowTitle])
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function focusKeys() {
    Qt.callLater(function() {
      if (setupNeeded) setup.focusCurrent()
      else if (tab === "search" && !detail && selectedIndex < 0) searchField.forceActiveFocus()
      else keys.forceActiveFocus()
    })
  }

  onSetupNeededChanged: if (opened) { refreshTab(false); focusKeys() }

  // ---- data loading ------------------------------------------------------------------

  function setTabData(id, value) {
    var next = Object.assign({}, data)
    next[id] = Object.assign({}, data[id] || {}, value)
    data = next
  }

  function refreshTab(force) {
    if (!service || !service.ready) return
    var id = tab
    var d = data[id] || {}
    var fresh = d.loadedAt && Date.now() - d.loadedAt < (id === "queue" || id === "devices" ? 3000 : 60000)
    if (id === "search" || d.loading || (fresh && !force)) return
    var op = { playlists: "playlists", liked: "liked", recent: "recent", queue: "queue", devices: "devices" }[id]
    setTabData(id, { loading: true, error: "" })
    service.request(op, {}, function(res) {
      if (res.error) { setTabData(id, { loading: false, error: res.error }); return }
      setTabData(id, Object.assign({ loading: false, error: "", loadedAt: Date.now() }, res))
      if (id === "liked" || id === "recent" || id === "queue") {
        var uris = (res.items || []).slice(0, 40).map(function(x) { return x.uri })
        if (uris.length) service.checkSaved(uris)
      }
    })
  }

  Connections {
    target: root.service
    function onQueueSerialChanged() {
      if (!root.opened) return
      var next = Object.assign({}, root.data)
      delete next.queue
      if (root.tab !== "liked") delete next.liked
      root.data = next
      if (root.tab === "queue" && !root.detail) root.refreshTab(true)
    }
  }

  function switchTab(id) {
    if (!service) return
    var memo = Object.assign({}, selectionMemory)
    memo[detail ? "detail" : tab] = selectedIndex
    selectionMemory = memo
    detail = null
    tab = id
    selectedIndex = selectionMemory[id] !== undefined ? selectionMemory[id] : 0
    refreshTab(false)
    if (id === "search") Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
    else focusKeys()
    positionList()
  }

  function cycleTab(delta) {
    var i = tabs.findIndex(function(t) { return t.id === tab })
    switchTab(tabs[(i + delta + tabs.length) % tabs.length].id)
  }

  function openCollection(item) {
    if (!item) return
    var memo = Object.assign({}, selectionMemory)
    memo[tab] = selectedIndex
    selectionMemory = memo
    detail = { playlist: item, tracks: [], restricted: false, loading: true, error: "" }
    selectedIndex = 0
    positionList()
    service.request(item.type === "album" ? "album" : "playlist", { id: item.id }, function(res) {
      if (!detail || detail.playlist.uri !== item.uri) return
      if (res.error) { detail = Object.assign({}, detail, { loading: false, error: res.error }); return }
      detail = { playlist: Object.assign({}, item, res.playlist || {}), tracks: res.tracks || [], restricted: !!res.restricted, loading: false, error: "" }
      var ctx = service.player.contextUri, cur = service.track
      if (ctx === item.uri && cur) {
        for (var i = 0; i < rows.length; i++) if (rows[i].uri === cur.uri) { selectedIndex = i; break }
      }
      positionList()
      var uris = (res.tracks || []).slice(0, 40).map(function(x) { return x.uri })
      if (uris.length) service.checkSaved(uris)
    })
    focusKeys()
  }

  function back() {
    if (detail) {
      detail = null
      selectedIndex = selectionMemory[tab] !== undefined ? selectionMemory[tab] : 0
      positionList()
      return true
    }
    return false
  }

  // Opens whatever is playing: its playlist or album, else the queue.
  function openNowPlaying() {
    if (!service || !service.player.active) return
    var ctx = service.player.contextUri || "", type = service.player.contextType
    if (type === "playlist") {
      var id = ctx.split(":").pop()
      var known = ((data.playlists || {}).items || []).filter(function(p) { return p.uri === ctx })[0]
      if (tab !== "playlists") switchTab("playlists")
      openCollection(known || { type: "playlist", id: id, uri: ctx, name: "Playlist", owner: "" })
    } else if (type === "album" && ctx) {
      var t = service.track
      openCollection({ type: "album", id: ctx.split(":").pop(), uri: ctx, name: t ? t.album : "Album", owner: t ? t.artist : "", image: t ? t.image : "" })
    } else {
      switchTab("queue")
    }
  }

  Timer {
    id: searchTimer
    interval: 380
    onTriggered: root.runSearch()
  }

  function runSearch() {
    var q = query.trim()
    if (!q) { searchResults = null; return }
    searching = true
    service.request("search", { q: q }, function(res) {
      if (q !== query.trim()) return
      searching = false
      if (res.error) { searchResults = { tracks: [], playlists: [], albums: [], artists: [], error: res.error }; return }
      searchResults = res
      selectedIndex = -1
    })
  }

  // ---- actions --------------------------------------------------------------------

  function activate(row, playDirect) {
    if (!row || !service) return
    var kind = row.kind || row.type
    if (kind === "notice") return
    if (kind === "action") { service.playContext(row.uri); return }
    if (kind === "local") { service.connectLocal(); return }
    if (kind === "device") { if (!row.active) service.transfer(row.id); return }
    if (kind === "playlist" || kind === "album") {
      if (playDirect) service.playContext(row.uri)
      else openCollection(row)
      return
    }
    if (kind === "artist") { service.playContext(row.uri); service.showFlash("Playing " + row.name); return }
    if (kind === "track" || kind === "episode") {
      if (detail) { service.playContext(detail.playlist.uri, row.uri); return }
      if (tab === "liked" || tab === "queue") {
        var list = rows.filter(function(x) { return x.type === "track" || x.type === "episode" })
        var start = list.findIndex(function(x) { return x.uri === row.uri })
        service.playUris(list.slice(Math.max(0, start), start + 100).map(function(x) { return x.uri }))
        return
      }
      if (tab === "recent" && row.contextUri) { service.playContext(row.contextUri, row.uri); return }
      if (row.albumUri) { service.playContext(row.albumUri, row.uri); return }
      service.playUris([row.uri])
    }
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))
    positionList()
  }

  function positionList() {
    Qt.callLater(function() { if (selectedIndex >= 0) list.positionViewAtIndex(selectedIndex, ListView.Contain) })
  }

  function fmt(ms) {
    var s = Math.max(0, Math.floor((ms || 0) / 1000))
    var m = Math.floor(s / 60)
    s = s % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Key handling shared by the list and (for non-text keys) the search field.
  function handleKey(event, fromSearch) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var key = event.key
    var s = service
    if (!s) return false

    if (key === Qt.Key_Escape) {
      if (fromSearch && query !== "") { searchField.text = ""; return true }
      if (fromSearch) { selectedIndex = 0; keys.forceActiveFocus(); return true }
      back()
      return true
    }
    if (key === Qt.Key_Tab || key === Qt.Key_Backtab) { cycleTab(key === Qt.Key_Backtab || shift ? -1 : 1); return true }
    if (key === Qt.Key_Down || (ctrl && key === Qt.Key_J)) {
      if (fromSearch) keys.forceActiveFocus()
      moveSelection(1)
      return true
    }
    if (key === Qt.Key_Up || (ctrl && key === Qt.Key_K)) {
      if (!fromSearch && tab === "search" && !detail && selectedIndex <= 0) { selectedIndex = -1; searchField.forceActiveFocus(); return true }
      moveSelection(-1); return true
    }
    if (key === Qt.Key_PageDown) { moveSelection(Math.max(1, Math.floor(list.height / rowHeight) - 1)); return true }
    if (key === Qt.Key_PageUp) { moveSelection(-Math.max(1, Math.floor(list.height / rowHeight) - 1)); return true }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (fromSearch) { searchTimer.stop(); runSearch(); keys.forceActiveFocus(); selectedIndex = 0; return true }
      activate(selectedRow, shift)
      return true
    }
    if (ctrl && (key === Qt.Key_Right || key === Qt.Key_Left)) { key === Qt.Key_Right ? s.next() : s.previous(); return true }
    if (fromSearch) return false

    // List-only single keys.
    if (key === Qt.Key_Backspace || key === Qt.Key_H) { back(); return true }
    if (key === Qt.Key_J) { moveSelection(1); return true }
    if (key === Qt.Key_K) { moveSelection(-1); return true }
    if (key === Qt.Key_G) { selectedIndex = shift ? rows.length - 1 : 0; positionList(); return true }
    if (key === Qt.Key_Slash) { switchTab("search"); return true }
    if (key >= Qt.Key_1 && key <= Qt.Key_6) { switchTab(tabs[key - Qt.Key_1].id); return true }
    if (key === Qt.Key_D) { switchTab("devices"); return true }
    if (key === Qt.Key_Space) { s.togglePlay(); return true }
    if (key === Qt.Key_Right) { s.seekBy(shift ? 30000 : 10000); return true }
    if (key === Qt.Key_Left) { s.seekBy(shift ? -30000 : -10000); return true }
    if (key === Qt.Key_N) { s.next(); return true }
    if (key === Qt.Key_P) { s.previous(); return true }
    if (key === Qt.Key_Plus || key === Qt.Key_Equal) { s.setVolume(s.volume + 5); return true }
    if (key === Qt.Key_Minus || key === Qt.Key_Underscore) { s.setVolume(s.volume - 5); return true }
    if (key === Qt.Key_M) { s.toggleMute(); return true }
    if (key === Qt.Key_S) { s.toggleShuffle(); return true }
    if (key === Qt.Key_R) { s.cycleRepeat(); return true }
    if (key === Qt.Key_L) {
      var row = selectedRow
      if (shift && row && (row.type === "track" || row.type === "episode")) s.toggleLike(row.uri)
      else s.toggleLike()
      return true
    }
    if (key === Qt.Key_A) {
      var r = selectedRow
      if (r && (r.type === "track" || r.type === "episode")) s.addToQueue(r)
      return true
    }
    if (key === Qt.Key_C) { openNowPlaying(); return true }
    if (key === Qt.Key_O) { omarchify = !omarchify; s.showFlash(omarchify ? "Omarchified artwork" : "Original artwork"); return true }
    if (key === Qt.Key_F5 || (ctrl && key === Qt.Key_R)) { refreshTab(true); return true }
    return false
  }

  // ---- IPC ------------------------------------------------------------------------

  IpcHandler {
    target: root.pluginId
    function toggle(): void { root.shell ? root.shell.toggle(root.pluginId, "{}") : root.toggle() }
    function close(): void { root.dismiss() }
    function search(): void {
      var payload = JSON.stringify({ tab: "search" })
      if (root.opened) root.open(payload)
      else root.shell ? root.shell.summon(root.pluginId, payload) : root.open(payload)
    }
  }

  // ---- now-playing transition ------------------------------------------------------

  // What the stage shows. Lags the real track while the record swaps.
  property var shown: null
  readonly property string liveUri: service && service.track ? service.track.uri : ""
  property real vinylOut: 0          // 0 in the sleeve, 1 fully out
  property real titleShift: 0

  onLiveUriChanged: {
    if (!shown || !opened) { shown = service ? service.track : null; return }
    if (shown.uri === liveUri) { shown = service.track; return }
    swap.restart()
  }

  Connections {
    target: root.service
    function onTrackChanged() { if (root.shown && root.service.track && root.shown.uri === root.service.track.uri) root.shown = root.service.track }
  }

  SequentialAnimation {
    id: swap
    ParallelAnimation {
      NumberAnimation { target: root; property: "vinylOut"; to: 0; duration: 260; easing.type: Easing.InCubic }
      NumberAnimation { target: root; property: "titleShift"; to: -1; duration: 200; easing.type: Easing.InCubic }
    }
    ScriptAction { script: root.shown = root.service ? root.service.track : null }
    PropertyAction { target: root; property: "titleShift"; value: 1 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "vinylOut"; to: 1; duration: 620; easing.type: Easing.OutBack; easing.overshoot: 0.9 }
      NumberAnimation { target: root; property: "titleShift"; to: 0; duration: 380; easing.type: Easing.OutCubic }
    }
  }

  readonly property bool stagePlaying: !!(service && service.playing)
  Binding {
    target: root
    property: "vinylOut"
    value: root.stagePlaying ? 1 : 0.62
    when: !swap.running
    restoreMode: Binding.RestoreNone
  }
  Behavior on vinylOut {
    enabled: !swap.running
    NumberAnimation { duration: 700; easing.type: Easing.OutCubic }
  }

  // ---- window ------------------------------------------------------------------------

  FloatingWindow {
    id: panel
    title: root.windowTitle
    visible: root.opened
    color: root.background
    implicitWidth: Style.space(1220)
    implicitHeight: Style.space(780)
    minimumSize: Qt.size(Style.space(860), Style.space(560))

    onVisibleChanged: {
      if (visible || !root.opened) return
      // Closed by the window manager (Super+W).
      root.opened = false
      if (root.service) root.service.overlayOpen = false
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      color: root.background
      padding: Style.spacing.panelPadding
      clip: true

      // Ambient glow: a soft accent halo behind the record that breathes with the music.
      Shape {
        id: glow
        visible: !root.setupNeeded && stage.visible
        readonly property real size: stage.sleeveSize * 2.1
        readonly property real pulse: root.service ? root.service.level * 0.5 + root.service.beat * 0.35 : 0
        x: card.contentLeftInset + stage.x + vinyl.x + vinyl.width / 2 - size / 2
        y: card.contentTopInset + stageColumn.y + stage.y + stage.anchors.topMargin + stage.height / 2 - size / 2
        width: size
        height: size
        opacity: (root.stagePlaying ? 0.28 : 0.12) + pulse * 0.45
        scale: 0.92 + pulse * 0.12
        preferredRendererType: Shape.CurveRenderer
        Behavior on opacity { NumberAnimation { duration: 220 } }
        Behavior on scale { NumberAnimation { duration: 90 } }

        ShapePath {
          strokeWidth: -1
          fillGradient: RadialGradient {
            centerX: glow.size / 2; centerY: glow.size / 2; centerRadius: glow.size / 2
            focalX: centerX; focalY: centerY
            GradientStop { position: 0.0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55) }
            GradientStop { position: 0.45; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) }
            GradientStop { position: 1.0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0) }
          }
          startX: 0; startY: 0
          PathLine { x: glow.size; y: 0 }
          PathLine { x: glow.size; y: glow.size }
          PathLine { x: 0; y: glow.size }
          PathLine { x: 0; y: 0 }
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ---------- header ----------
        Item {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)
            + (root.narrow && tabStrip.visible ? tabStrip.height + Style.spacing.md : 0)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.top: parent.top
            textFormat: Text.PlainText
            text: root.glyph.spotify
            color: root.stagePlaying ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            Behavior on color { ColorAnimation { duration: 300 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: root.narrow ? 0 : tabStrip.width + root.gap
            anchors.verticalCenter: heroIcon.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Spotify"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: {
                var s = root.service
                if (!s || !s.ready) return "SETUP"
                var p = s.player
                if (!p.active) return "NOTHING PLAYING"
                var parts = [(p.playing ? "PLAYING ON " : "PAUSED ON ") + (p.device ? p.device.name : "").toUpperCase()]
                if (p.shuffle) parts.push("SHUFFLE")
                if (p.repeat === "context") parts.push("REPEAT")
                if (p.repeat === "track") parts.push("REPEAT ONE")
                if (s.volume >= 0) parts.push("VOL " + s.volume)
                return parts.join("  ·  ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          Row {
            id: tabStrip
            x: root.narrow ? 0 : parent.width - width
            y: root.narrow ? parent.height - height : heroIcon.y + (heroIcon.height - height) / 2
            spacing: Style.spacing.xs
            visible: !root.setupNeeded

            Repeater {
              model: root.tabs
              CursorSurface {
                id: tabChip
                required property var modelData
                required property int index
                readonly property bool isCurrent: root.tab === modelData.id && !root.detail
                readonly property bool isTab: root.tab === modelData.id
                width: chipRow.implicitWidth + Style.spacing.controlPaddingX * 2
                height: chipRow.implicitHeight + Style.spacing.controlPaddingY * 2
                foreground: root.foreground
                current: isTab
                hasCursor: chipMouse.containsMouse

                Row {
                  id: chipRow
                  anchors.centerIn: parent
                  spacing: Style.spacing.xs
                  Text {
                    textFormat: Text.PlainText
                    text: tabChip.modelData.glyph
                    color: tabChip.isTab ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    visible: !root.compact || tabChip.isTab
                    textFormat: Text.PlainText
                    text: tabChip.modelData.label
                    color: tabChip.isTab ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: tabChip.isTab
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: String(tabChip.index + 1)
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.switchTab(tabChip.modelData.id)
                }
              }
            }
          }
        }

        // ---------- setup ----------
        Setup {
          id: setup
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.topMargin: root.gap
          anchors.bottom: footer.top
          anchors.bottomMargin: root.gap
          visible: root.setupNeeded
          service: root.service
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
        }

        // ---------- stage (left) ----------
        Item {
          id: stageColumn
          anchors.left: parent.left
          anchors.top: header.bottom
          anchors.topMargin: root.gap
          anchors.bottom: root.narrow ? undefined : footer.top
          anchors.bottomMargin: root.narrow ? 0 : root.gap
          width: root.narrow ? parent.width : Math.round(parent.width * 0.42)
          height: root.narrow ? (stage.visible ? stage.height + root.gap : 0) + nowInfo.implicitHeight : undefined
          visible: !root.setupNeeded

          Item {
            id: stage
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            // With no visualizer below, centre the stage and song info in the column.
            anchors.topMargin: viz.visible || root.narrow ? 0 : Math.max(0, (parent.height - height - nowInfo.implicitHeight - root.gap) / 2)
            // Stacked (narrow): a modest stage, hidden when the window is too short for it.
            readonly property real stackedHeight: Math.round(Math.min(width * 0.45, stageColumn.parent.height * 0.3))
            visible: !root.narrow || stackedHeight >= Style.space(90)
            height: root.narrow
              ? (visible ? stackedHeight : 0)
              : Math.max(Style.space(120), Math.min(width * 0.64, parent.height - nowInfo.implicitHeight - (viz.visible ? Style.space(56) : 0) - root.gap * 2))
            readonly property bool hasArt: sleeveArt.hasImage
            readonly property real sleeveSize: height

            Vinyl {
              id: vinyl
              width: stage.sleeveSize * 0.94
              height: width
              y: (stage.height - height) / 2
              x: (stage.sleeveSize - width) / 2 + root.vinylOut * Math.min(stage.width - stage.sleeveSize, stage.sleeveSize * 0.58)
              source: root.shown ? root.shown.image : ""
              spinning: root.stagePlaying && !swap.running
              // The record label always shows the real colours.
              amount: 0
              shadow: root.shadowTone
              highlight: root.accent
              peak: root.peakTone
              beat: root.service ? root.service.beat : 0
              progress: root.service && root.service.duration > 0 ? root.service.progress / root.service.duration : 0
              armDown: root.stagePlaying && !swap.running && root.vinylOut > 0.9
            }

            // Sleeve.
            Item {
              id: sleeve
              width: stage.sleeveSize
              height: width

              Rectangle {
                anchors.fill: parent
                anchors.margins: -1
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              }

              Artwork {
                id: sleeveArt
                anchors.fill: parent
                source: root.shown ? root.shown.image : ""
                amount: root.artAmount
                shadow: root.shadowTone
                highlight: root.accent
                peak: root.peakTone
              }

              // Sleeve edge shading so the record reads as sliding out of it.
              Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.max(8, parent.width * 0.05)
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: "transparent" }
                  GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.3) }
                }
              }
            }
          }

          Column {
            id: nowInfo
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: stage.visible ? stage.bottom : parent.top
            anchors.topMargin: stage.visible ? root.gap : 0
            spacing: Style.spacing.sm
            clip: true

            Item {
              width: parent.width
              height: titleText.implicitHeight + artistText.implicitHeight + Style.space(2)
              opacity: 1 - Math.abs(root.titleShift)
              transform: Translate { x: root.titleShift * Style.space(40) }

              Text {
                id: titleText
                width: parent.width - likeGlyph.width - Style.spacing.sm
                textFormat: Text.PlainText
                text: root.shown ? root.shown.name : (root.service && root.service.ready ? "Nothing playing" : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                id: likeGlyph
                anchors.right: parent.right
                anchors.verticalCenter: titleText.verticalCenter
                visible: !!root.shown
                textFormat: Text.PlainText
                text: root.service && root.service.trackSaved ? root.glyph.heart : root.glyph.heartEmpty
                color: root.service && root.service.trackSaved ? root.accent : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                scale: likeMouse.pressed ? 0.85 : 1
                Behavior on scale { NumberAnimation { duration: 120 } }
                MouseArea { id: likeMouse; anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: root.service.toggleLike() }
              }

              Text {
                id: artistText
                anchors.top: titleText.bottom
                anchors.topMargin: Style.space(2)
                width: parent.width
                textFormat: Text.PlainText
                text: root.shown ? [root.shown.artist, root.shown.album].filter(function(x) { return !!x }).join("  ·  ")
                  : (root.service && root.service.ready
                    ? (root.service.local.running ? "Pick something on the right to start playing" : "Press d to set up playback on this computer, or pick another device")
                    : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
            }

            // Progress.
            Item {
              width: parent.width
              height: Style.space(18)
              visible: !!(root.service && root.service.track)

              Rectangle {
                id: track
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: seekMouse.containsMouse ? Style.space(6) : Style.space(3)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                Behavior on height { NumberAnimation { duration: 120 } }

                Rectangle {
                  width: root.service && root.service.duration > 0 ? parent.width * root.service.progress / root.service.duration : 0
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                }
              }

              MouseArea {
                id: seekMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) { root.service.seekTo(root.service.duration * mouse.x / width) }
              }
            }

            Item {
              width: parent.width
              height: timeLeft.implicitHeight
              visible: !!(root.service && root.service.track)

              Text {
                id: timeLeft
                anchors.left: parent.left
                textFormat: Text.PlainText
                text: root.service && root.service.track ? root.fmt(root.service.progress) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: root.service && root.service.track ? root.fmt(root.service.duration) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              width: parent.width
              height: transport.implicitHeight
              Row {
                id: transport
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.spacing.md

                PanelActionButton {
                  iconText: root.glyph.shuffle
                  foreground: root.service && root.service.player.shuffle ? root.accent : root.dim
                  fontFamily: root.fontFamily
                  tooltipText: "Shuffle  (s)"
                  onClicked: root.service.toggleShuffle()
                }
                PanelActionButton {
                  iconText: root.glyph.prev
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Previous  (p)"
                  onClicked: root.service.previous()
                }
                PanelActionButton {
                  iconText: root.stagePlaying ? root.glyph.pause : root.glyph.play
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.iconLarge
                  bordered: true
                  tooltipText: "Play / pause  (Space)"
                  onClicked: root.service.togglePlay()
                }
                PanelActionButton {
                  iconText: root.glyph.next
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: "Next  (n)"
                  onClicked: root.service.next()
                }
                PanelActionButton {
                  iconText: root.glyph.repeat + (root.service && root.service.player.repeat === "track" ? "¹" : "")
                  foreground: root.service && root.service.player.repeat && root.service.player.repeat !== "off" ? root.accent : root.dim
                  fontFamily: root.fontFamily
                  tooltipText: "Repeat  (r)"
                  onClicked: root.service.cycleRepeat()
                }
              }

            }
          }

          Visualizer {
            id: viz
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.max(0, parent.height - stage.height - nowInfo.implicitHeight - root.gap * 2)
            levels: root.service ? root.service.levels : []
            count: 48
            low: root.accent
            high: root.peakTone
            mirrored: true
            visible: !!(root.service && root.service.cavaAvailable) && !root.narrow
            // Fade the idle line out when there's no sound.
            opacity: root.service && root.service.level > 0.01 ? 1 : 0.2
            Behavior on opacity { NumberAnimation { duration: 400 } }
          }
        }

        // ---------- browser (right) ----------
        Item {
          id: browser
          anchors.left: root.narrow ? parent.left : stageColumn.right
          anchors.leftMargin: root.narrow ? 0 : root.gap * 2
          anchors.right: parent.right
          anchors.top: root.narrow ? stageColumn.bottom : header.bottom
          anchors.topMargin: root.gap
          anchors.bottom: footer.top
          anchors.bottomMargin: root.gap
          visible: !root.setupNeeded

          // Detail header: which playlist/album we're in.
          Item {
            id: detailHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.detail ? Style.space(84) : 0
            visible: !!root.detail
            clip: true

            Artwork {
              id: detailArt
              width: parent.height
              height: width
              source: root.detail ? (root.detail.playlist.image || "") : ""
              sourceSize: 200
              amount: root.artAmount
              shadow: root.shadowTone
              highlight: root.accent
              peak: root.peakTone
              placeholderGlyph: root.glyph.list
            }

            Column {
              anchors.left: detailArt.right
              anchors.leftMargin: root.gap
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: root.detail ? root.glyph.back + "  " + (root.detail.playlist.type === "album" ? "ALBUM" : "PLAYLIST") + "  ·  ESC TO GO BACK" : ""
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.detail ? root.detail.playlist.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: {
                  if (!root.detail) return ""
                  var p = root.detail.playlist
                  var parts = []
                  if (p.owner) parts.push(p.owner)
                  var n = root.detail.tracks.length || p.total
                  if (n) parts.push(n + (n === 1 ? " song" : " songs"))
                  if (root.detail.loading) parts.push("loading…")
                  return parts.join("  ·  ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: detailHeader.bottom
            anchors.topMargin: root.detail ? root.gap : 0
            visible: root.tab === "search" && !root.detail
            height: visible ? implicitHeight : 0
            placeholderText: "Search songs, playlists, albums and artists…"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            hasCursor: root.selectedIndex < 0
            onTextChanged: {
              if (text === root.query) return
              root.query = text
              searchTimer.restart()
            }
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) { if (root.handleKey(event, true)) event.accepted = true }
          }

          // Receives keys whenever the search field doesn't have focus.
          Item {
            id: keys
            focus: true
            Keys.onPressed: function(event) { if (root.handleKey(event, false)) event.accepted = true }
          }

          ListView {
            id: list
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: searchField.visible ? searchField.bottom : detailHeader.bottom
            anchors.topMargin: searchField.visible || root.detail ? root.gap : 0
            anchors.bottom: parent.bottom
            model: root.rows
            clip: true
            spacing: Style.spacing.xxs
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 0
            currentIndex: root.selectedIndex
            section.property: "section"
            section.delegate: Item {
              required property string section
              width: list.width
              height: section ? sectionLabel.implicitHeight + Style.spacing.md + (y > 0 ? Style.spacing.md : 0) : 0
              Text {
                id: sectionLabel
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.spacing.xs
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                textFormat: Text.PlainText
                text: parent.section.toUpperCase()
                color: parent.section === "Now playing" ? root.accent : root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.4
              }
            }
            delegate: BrowserRow {}

            add: Transition {
              NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 180 }
            }
          }

          Text {
            anchors.centerIn: list
            width: list.width * 0.8
            visible: list.count === 0
            textFormat: Text.PlainText
            text: {
              if (root.detail) return root.detail.error || (root.detail.loading ? "Loading…" : "")
              var d = root.data[root.tab] || {}
              if (d.error) return d.error
              if (d.loading) return "Loading…"
              if (root.tab === "search") {
                if (root.searching) return "Searching…"
                if (root.searchResults && root.searchResults.error) return root.searchResults.error
                return root.query ? "Nothing found for “" + root.query + "”" : "Type to search. ↓ moves into the results."
              }
              if (root.tab === "queue") return "The queue is empty. Play something first."
              if (root.tab === "liked") return "No liked songs yet. Press l on a playing song to like it."
              return "Nothing here yet"
            }
            color: (root.data[root.tab] || {}).error ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
          }
        }

        // ---------- footer ----------
        Item {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: hints.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.right: hints.left
            anchors.rightMargin: root.gap
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.service ? root.service.flash : ""
            color: root.service && root.service.flash && root.service.flash === root.service.errorText ? Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * (root.service && root.service.flash ? 0.62 : 1))
            textFormat: Text.PlainText
            text: root.setupNeeded
              ? "Enter do this step  ·  ↑↓ move  ·  Super+W close"
              : (root.tab === "search" && !root.detail && root.selectedIndex < 0
                ? "Enter search  ·  ↓ results  ·  Tab next tab  ·  Esc clear"
                : "Enter play/open  ·  Space pause  ·  ←→ seek  ·  n/p skip  ·  +/- vol  ·  l like  ·  a queue  ·  c now playing  ·  o art  ·  Esc back")
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
          }
        }
      }
    }
  }

  // ---- rows ------------------------------------------------------------------------

  component BrowserRow: CursorSurface {
    id: row

    required property int index
    required property var modelData

    readonly property string kind: modelData.kind || modelData.type || ""
    readonly property bool isTrack: kind === "track" || kind === "episode"
    readonly property bool isPlayingItem: !!(root.service && root.service.track && (
      (isTrack && modelData.uri === root.service.track.uri) ||
      (!isTrack && modelData.uri && modelData.uri === root.service.player.contextUri)))
    readonly property bool selected: index === root.selectedIndex

    width: list.width
    height: kind === "notice" ? noticeCol.implicitHeight + Style.spacing.md * 2 : root.rowHeight
    hasCursor: selected
    foreground: root.foreground

    // Leading slot: equalizer for what's playing, else track number / glyph.
    Item {
      id: lead
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      width: Style.font.body * 1.8
      height: Style.font.body

      Visualizer {
        anchors.fill: parent
        anchors.margins: 1
        visible: row.isPlayingItem && root.stagePlaying
        levels: root.service ? root.service.levels.slice(2, 26) : []
        count: 4
        gap: 0.3
        minimum: 2
        radius: 1
        low: root.accent
        high: root.accent
      }

      Text {
        anchors.centerIn: parent
        visible: !(row.isPlayingItem && root.stagePlaying)
        textFormat: Text.PlainText
        text: {
          var m = row.modelData
          if (row.kind === "action") return root.glyph.play
          if (row.kind === "notice") return root.glyph.key
          if (row.kind === "device" || row.kind === "local") {
            var t = (m.type || "").toLowerCase()
            return t === "smartphone" ? root.glyph.phone : (t === "speaker" ? root.glyph.speaker : root.glyph.device)
          }
          if (m.position) return String(m.position)
          return ""
        }
        color: row.isPlayingItem || row.kind === "action" ? root.accent : root.faint
        font.family: root.fontFamily
        font.pixelSize: row.modelData.position ? Style.font.caption : Style.font.body
      }
    }

    Artwork {
      id: thumb
      anchors.left: lead.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      width: visible ? root.rowHeight - Style.spacing.controlPaddingY * 2 : 0
      height: width
      visible: !!row.modelData.thumb || row.kind === "playlist" || row.kind === "album" || row.kind === "artist"
      source: row.modelData.thumb || ""
      sourceSize: 96
      fadeDuration: 200
      circle: row.kind === "artist"
      // The picked row shows its true colours.
      amount: row.selected ? 0 : root.artAmount
      shadow: root.shadowTone
      highlight: root.accent
      peak: root.peakTone
      placeholderGlyph: row.kind === "artist" ? root.glyph.user : root.glyph.music
    }

    Column {
      id: noticeCol
      visible: row.kind === "notice"
      anchors.left: thumb.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)
      Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: row.modelData.name || ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
      Text { width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: row.modelData.owner || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    }

    Column {
      visible: row.kind !== "notice"
      anchors.left: thumb.right
      anchors.leftMargin: thumb.visible ? Style.spacing.md : 0
      anchors.right: trailing.left
      anchors.rightMargin: Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: row.modelData.name || ""
        color: row.isPlayingItem || row.kind === "action" ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isPlayingItem || row.kind === "action"
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: {
          var m = row.modelData
          if (row.isTrack) return [m.artist, root.detail && root.detail.playlist.type === "album" ? "" : m.album].filter(function(x) { return !!x }).join("  ·  ")
          if (row.kind === "playlist" || row.kind === "album") {
            var parts = []
            if (m.owner) parts.push(m.owner)
            if (m.total) parts.push(m.total + (m.total === 1 ? " song" : " songs"))
            if (m.collaborative) parts.push("collaborative")
            return parts.join("  ·  ")
          }
          if (row.kind === "artist") return "Artist  ·  Enter plays"
          if (row.kind === "device") return m.active ? "Playing here" + (m.volume !== null && m.volume !== undefined ? "  ·  vol " + m.volume : "") : "Enter to play here"
          if (row.kind === "local") {
            var l = root.service ? root.service.local : {}
            if (root.service && root.service.busyStep === "local") return "Connecting… approve in your browser"
            if (!l.installed) return "Needs spotifyd: sudo pacman -S spotifyd cava"
            if (!l.authenticated) return "Enter to connect this computer (opens your browser once)"
            return l.running ? "Starting up…" : "Enter to start playback on this computer"
          }
          if (row.kind === "action") return root.detail && root.detail.playlist ? "Shuffle is " + (root.service && root.service.player.shuffle ? "on" : "off") : ""
          return ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: row.isTrack && root.service && !!root.service.saved[row.modelData.uri]
        textFormat: Text.PlainText
        text: root.glyph.heart
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        textFormat: Text.PlainText
        text: {
          var m = row.modelData
          if (row.isTrack) return root.fmt(m.duration)
          if (row.kind === "device" && m.active) return root.glyph.check
          if (row.isPlayingItem) return "NOW PLAYING"
          return ""
        }
        color: row.isPlayingItem || row.kind === "device" ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: row.isPlayingItem && !row.isTrack
        font.letterSpacing: row.isPlayingItem && !row.isTrack ? 1.2 : 0
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: if (root.selectedIndex !== row.index) root.selectedIndex = row.index
      onClicked: { root.selectedIndex = row.index; keys.forceActiveFocus(); root.activate(row.modelData, false) }
      onDoubleClicked: root.activate(row.modelData, true)
    }
  }

  Component.onCompleted: shown = service ? service.track : null
}
