import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The Spotify engine, one per shell. Owns the spotify.py helper, the player
// state (polled, with progress interpolated between polls), the audio
// visualizer feed from cava and the theme palette. The overlay and every bar
// widget read from and drive this one instance.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var settings: ({})

  readonly property string pluginId: (manifest && manifest.id) || "funcoder.spotify"
  readonly property string helper: {
    var url = String(Qt.resolvedUrl("spotify.py"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : url
  }

  // ---- setup / auth ----------------------------------------------------------
  property var status: ({})
  property bool statusLoaded: false
  readonly property bool hasClientId: !!status.clientId
  readonly property bool loggedIn: !!status.loggedIn
  readonly property var local: status.local || ({})
  readonly property bool ready: hasClientId && loggedIn
  property string busyStep: ""   // "login" | "local" | ""
  property string errorText: ""

  // ---- player -----------------------------------------------------------------
  property var player: ({ active: false })
  property double fetchedAt: 0
  property double now: Date.now()
  readonly property var track: player.item || null
  readonly property bool playing: !!player.playing
  readonly property real duration: track ? track.duration : 0
  readonly property real progress: {
    if (!player.active) return 0
    var p = player.progress || 0
    if (playing) p += now - fetchedAt
    return Math.max(0, Math.min(duration, p))
  }
  readonly property int volume: player.device && player.device.volume !== undefined && player.device.volume !== null
    ? player.device.volume : -1
  property var saved: ({})
  readonly property bool trackSaved: !!(track && saved[track.uri])
  property int pendingCommands: 0
  property string flash: ""

  // Increases whenever the user's library/queue likely changed, so open lists refresh.
  property int queueSerial: 0

  // ---- surfaces -------------------------------------------------------------------
  property bool overlayOpen: false
  property int barWidgets: 0

  // ---- visualizer ---------------------------------------------------------------
  readonly property int bars: 48
  property var levels: []
  property real level: 0      // smoothed overall loudness 0..1
  property real beat: 0       // decays after bass hits, 0..1
  readonly property bool cavaAvailable: !!status.cava
  readonly property bool demo: !!status.demo
  readonly property bool visualizerWanted: cavaAvailable && playing && (overlayOpen || barWidgets > 0)

  // ---- theme ----------------------------------------------------------------------
  property var themeColors: ({})
  function themeColor(name, fallback) {
    var v = themeColors[name]
    return v ? v : fallback
  }
  readonly property color accent: Color.accent
  readonly property color foreground: Color.menu.text
  readonly property color background: Color.menu.background
  readonly property color shadowTone: themeColor("darker_background", themeColor("dark_background", Qt.darker(background, 1.4)))
  readonly property color peakTone: themeColor("bright_foreground", Qt.lighter(foreground, 1.2))

  FileView {
    path: Color.currentThemePath ? Color.currentThemePath + "/colors.toml" : ""
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var out = {}
      var lines = String(text()).split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
        if (m) out[m[1]] = m[2]
      }
      root.themeColors = out
    }
  }

  // ---- helper process -------------------------------------------------------------

  property int nextId: 1
  property var callbacks: ({})

  Process {
    id: helperProcess
    command: ["python3", root.helper, "serve"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.receive(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (line.trim()) console.warn(root.pluginId + ": helper: " + line) }
    }
    onExited: function(code) {
      console.warn(root.pluginId + ": helper exited (" + code + "), restarting")
      var pending = root.callbacks
      root.callbacks = {}
      for (var id in pending) {
        try { pending[id]({ error: "The Spotify helper restarted, try again" }) } catch (e) {}
      }
      restartHelper.start()
    }
  }

  Timer {
    id: restartHelper
    interval: 1500
    onTriggered: { helperProcess.running = true; root.refreshStatus() }
  }

  function receive(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    var cb = callbacks[msg.id]
    if (!cb) return
    delete callbacks[msg.id]
    try { cb(msg.error ? { error: msg.error, status: msg.status || 0 } : (msg.data || {})) }
    catch (e) { console.warn(root.pluginId + ": callback failed", e) }
  }

  // request("playlists", {}, function(data) { data.error ? ... : ... })
  function request(op, args, callback) {
    if (!helperProcess.running) {
      if (callback) callback({ error: "The Spotify helper isn't running" })
      return
    }
    var id = nextId++
    if (callback) callbacks[id] = callback
    helperProcess.write(JSON.stringify({ id: id, op: op, args: args || {} }) + "\n")
  }

  // ---- setup ----------------------------------------------------------------------

  function refreshStatus(then) {
    request("status", {}, function(data) {
      if (!data.error) {
        status = data
        statusLoaded = true
        if (ready) pollNow()
      }
      if (then) then(data)
    })
  }

  function setClientId(value, then) {
    errorText = ""
    request("set_client_id", { clientId: value }, function(data) {
      if (data.error) errorText = data.error
      else status = data
      if (then) then(data)
    })
  }

  function login() {
    if (busyStep) return
    errorText = ""
    busyStep = "login"
    request("login", {}, function(data) {
      busyStep = ""
      if (data.error) errorText = data.error
      else { status = data; showFlash("Logged in to Spotify"); pollNow() }
    })
  }

  function logout() {
    request("logout", {}, function(data) {
      if (!data.error) status = data
      player = { active: false }
    })
  }

  function connectLocal() {
    if (busyStep) return
    errorText = ""
    busyStep = "local"
    var op = local.authenticated ? "local_start" : "local_auth"
    request(op, {}, function(data) {
      busyStep = ""
      if (data.error) { errorText = data.error; refreshStatus() }
      else { refreshStatus(); showFlash(data.running ? local.name + " is ready to play" : "Playback set up") }
    })
  }

  function stopLocal() {
    request("local_stop", {}, function() { refreshStatus() })
  }

  // ---- polling --------------------------------------------------------------------

  Timer {
    id: pollTimer
    running: root.ready
    repeat: true
    interval: root.overlayOpen ? 1000 : (root.playing ? 3000 : 8000)
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Timer {
    id: clock
    running: root.playing && (root.overlayOpen || root.barWidgets > 0)
    repeat: true
    interval: 250
    onTriggered: root.now = Date.now()
  }

  Timer {
    id: soonPoll
    interval: 350
    onTriggered: root.poll()
  }

  property bool polling: false
  property string lastTrackUri: ""

  function pollNow() { soonPoll.restart() }

  function poll() {
    if (!ready || polling || pendingCommands > 0) return
    polling = true
    request("player", {}, function(data) {
      polling = false
      if (data.error) {
        if (data.status === 401) refreshStatus()
        return
      }
      now = Date.now()
      fetchedAt = now
      player = data
      var uri = data.item ? data.item.uri : ""
      if (uri && uri !== lastTrackUri) {
        lastTrackUri = uri
        checkSaved([uri])
        queueSerial++
      }
    })
  }

  function checkSaved(uris) {
    request("saved", { uris: uris }, function(data) {
      if (data.error || !data.saved) return
      var next = Object.assign({}, saved)
      for (var k in data.saved) next[k] = data.saved[k]
      saved = next
    })
  }

  // ---- commands -------------------------------------------------------------------

  Timer {
    id: flashTimer
    interval: 2600
    onTriggered: root.flash = ""
  }

  // Errors stay up long enough to read.
  function showFlash(text, error) {
    flash = text
    flashTimer.interval = error ? 7000 : 2600
    flashTimer.restart()
  }

  // Emitted when playback needs this computer connected first; the player
  // window opens Devices so the fix is one Enter away.
  signal localSetupNeeded()

  // Applies `optimistic` to the player state straight away, sends the
  // command, then re-polls to pick up what Spotify actually did.
  function command(op, args, optimistic, done) {
    if (!ready) return
    if (optimistic) {
      var next = Object.assign({}, player)
      optimistic(next)
      now = Date.now()
      fetchedAt = now
      player = next
    }
    pendingCommands++
    request(op, args || {}, function(data) {
      pendingCommands = Math.max(0, pendingCommands - 1)
      if (data.error) {
        errorText = data.error
        showFlash(data.error, true)
        if (data.status === 428) {
          refreshStatus()
          localSetupNeeded()
        }
      } else {
        errorText = ""
      }
      pollNow()
      if (done) done(data)
    })
  }

  function togglePlay() {
    if (!player.active) { command("resume", {}); return }
    var progressNow = progress
    command(playing ? "pause" : "resume", {}, function(p) { p.progress = progressNow; p.playing = !p.playing })
  }

  function next() { command("next", {}, function(p) { p.progress = 0 }) }
  function previous() {
    if (progress > 4000) { seekTo(0); return }
    command("previous", {}, function(p) { p.progress = 0 })
  }

  function seekTo(ms) {
    if (!track) return
    var pos = Math.max(0, Math.min(duration - 500, ms))
    command("seek", { position: Math.round(pos) }, function(p) { p.progress = pos })
  }

  function seekBy(deltaMs) { seekTo(progress + deltaMs) }

  Timer {
    id: volumeTimer
    interval: 180
    property int target: 0
    onTriggered: root.command("volume", { volume: target })
  }

  function setVolume(v) {
    if (!player.device) return
    var clamped = Math.max(0, Math.min(100, Math.round(v)))
    var next = Object.assign({}, player)
    next.device = Object.assign({}, player.device, { volume: clamped })
    player = next
    volumeTimer.target = clamped
    volumeTimer.restart()
    showFlash("Volume " + clamped + "%")
  }

  property int mutedVolume: -1
  function toggleMute() {
    if (volume > 0) { mutedVolume = volume; setVolume(0) }
    else setVolume(mutedVolume > 0 ? mutedVolume : 50)
  }

  function toggleShuffle() {
    var state = !player.shuffle
    command("shuffle", { state: state }, function(p) { p.shuffle = state })
    showFlash(state ? "Shuffle on" : "Shuffle off")
  }

  function cycleRepeat() {
    var order = ["off", "context", "track"]
    var state = order[(order.indexOf(player.repeat || "off") + 1) % order.length]
    command("repeat", { state: state }, function(p) { p.repeat = state })
    showFlash(state === "off" ? "Repeat off" : (state === "track" ? "Repeat this track" : "Repeat on"))
  }

  function toggleLike(uri) {
    uri = uri || (track && track.uri)
    if (!uri) return
    var save = !saved[uri]
    var next = Object.assign({}, saved)
    next[uri] = save
    saved = next
    request("like", { uri: uri, save: save }, function(data) {
      if (data.error) {
        var undo = Object.assign({}, saved)
        undo[uri] = !save
        saved = undo
        showFlash(data.error, true)
      } else {
        showFlash(save ? "Added to Liked Songs" : "Removed from Liked Songs")
        queueSerial++
      }
    })
  }

  function playContext(contextUri, offsetUri) {
    command("play", { contextUri: contextUri, offsetUri: offsetUri || "" }, function(p) { p.playing = true; p.progress = 0 })
  }

  function playUris(uris, offsetUri) {
    command("play", { uris: uris, offsetUri: offsetUri || "" }, function(p) { p.playing = true; p.progress = 0 })
  }

  function addToQueue(item) {
    if (!item || !item.uri) return
    request("queue_add", { uri: item.uri }, function(data) {
      if (data.error) showFlash(data.error, true)
      else { showFlash("Queued “" + item.name + "”"); queueSerial++ }
    })
  }

  function transfer(deviceId) {
    command("transfer", { deviceId: deviceId, play: playing || !player.active }, null, function(data) {
      if (!data.error) showFlash("Playing on another device")
    })
  }

  // ---- visualizer (cava) ------------------------------------------------------------

  property string cavaConfig: ""

  onVisualizerWantedChanged: {
    if (visualizerWanted && !cavaConfig) {
      request("cava_config", { bars: bars }, function(data) {
        if (!data.error) cavaConfig = data.path
      })
    }
    if (!visualizerWanted) decay.start()
  }

  Process {
    id: cava
    running: root.visualizerWanted && root.cavaConfig !== "" && !root.demo
    command: ["cava", "-p", root.cavaConfig]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.frame(line) }
    }
  }

  function frame(line) {
    var parts = line.split(";")
    var out = new Array(bars)
    var sum = 0, bass = 0
    for (var i = 0; i < bars; i++) {
      var v = Math.min(1, (parseInt(parts[i]) || 0) / 1000)
      out[i] = v
      sum += v
      if (i < 6) bass += v
    }
    levels = out
    level = level * 0.7 + (sum / bars) * 0.3
    bass /= 6
    beat = bass > 0.55 && bass > beat ? bass : beat * 0.9
  }

  // Demo mode: a made-up spectrum (bassy on the left, beats every ~0.47 s).
  FrameAnimation {
    id: demoSpectrum
    property real t: 0
    running: root.demo && root.visualizerWanted
    onTriggered: {
      t += frameTime
      var beatPhase = (t % 0.47) / 0.47
      var kick = Math.exp(-beatPhase * 7)
      var parts = []
      for (var i = 0; i < root.bars; i++) {
        var f = i / root.bars
        var v = (0.55 - f * 0.4) * (0.55 + 0.45 * Math.sin(t * (2.1 + f * 5.3) + i * 0.7))
          + 0.18 * Math.sin(t * 7.7 + i * 1.9) * Math.sin(t * 1.3 + f * 4)
          + kick * Math.max(0, 0.5 - f * 1.6)
        parts.push(Math.round(Math.max(0, Math.min(1, v)) * 1000))
      }
      root.frame(parts.join(";"))
    }
  }

  // Lets the bars fall to rest instead of freezing when playback stops.
  Timer {
    id: decay
    interval: 33
    repeat: true
    onTriggered: {
      if (root.visualizerWanted) { stop(); return }
      var out = [], any = false
      for (var i = 0; i < root.levels.length; i++) {
        var v = root.levels[i] * 0.82
        if (v > 0.005) any = true
        out.push(v > 0.005 ? v : 0)
      }
      root.levels = out
      root.level *= 0.82
      root.beat *= 0.8
      if (!any) stop()
    }
  }

  // ---- IPC --------------------------------------------------------------------------

  IpcHandler {
    target: "funcoder.spotify.player"
    function playPause(): void { root.togglePlay() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function volumeUp(): void { root.setVolume(root.volume + 5) }
    function volumeDown(): void { root.setVolume(root.volume - 5) }
    function like(): void { root.toggleLike() }
    // Jump to a position, in seconds, or a percentage of the song with a trailing %.
    function seek(position: string): void {
      var v = String(position).trim()
      if (v.slice(-1) === "%") root.seekTo(root.duration * (parseFloat(v) || 0) / 100)
      else root.seekTo((parseFloat(v) || 0) * 1000)
    }
    function status(): string {
      return JSON.stringify({
        ready: root.ready, playing: root.playing,
        title: root.track ? root.track.name : "", artist: root.track ? root.track.artist : "",
        device: root.player.device ? root.player.device.name : ""
      })
    }
  }

  Component.onCompleted: refreshStatus()
}
