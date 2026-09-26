import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Small 4-bar audio-reactive equalizer + scrolling now-playing text.
// Track info/controls come from `playerctl` (generic MPRIS client — works
// with Spotify, browser tabs, VLC, etc.); the bar levels come from a local
// `cava` process reading the system audio output in raw/ascii mode (see
// cava.conf). Third-party plugins cannot use Omarchy's built-in first-party
// media service (bar.shell.firstPartyServiceFor) — that API is restricted to
// the trusted bar and its clones — so this talks to MPRIS directly instead.
BarWidget {
  id: root
  moduleName: "io.github.taiku666.music-eq"

  // User settings from this widget's shell.json entry (see manifest schema).
  // `player` / `ignorePlayers` are handed to playerctl as-is, so they accept
  // its full syntax: a name ("spotify"), a comma-separated priority list
  // ("spotify,firefox") and "%any" as a wildcard. Empty follows whatever
  // playerctl picks.
  readonly property string player: String(setting("player", "")).trim()
  readonly property string ignorePlayers: String(setting("ignorePlayers", "")).trim()
  readonly property int noiseGate: Math.max(0, Math.min(100, Number(setting("noiseGate", 14)) || 0))
  readonly property real maxLabelWidth: Math.max(40, Number(setting("maxLabelWidth", 160)) || 160)
  readonly property real scrollSpeed: Math.max(5, Number(setting("scrollSpeed", 40)) || 40)
  readonly property bool showText: String(setting("showText", true)) !== "false"
  readonly property string colorSetting: String(setting("color", "accent")).trim()
  readonly property color barColor: resolveColor(colorSetting)

  // Every `key = "#rrggbb"` from the active theme's colors.toml. Color only
  // exposes the named roles (accent, foreground, urgent, muted), so hues are
  // read here. Reassigned as a whole so bindings re-evaluate.
  property var themePalette: ({})

  // Themes name their hues in one of two ways: directly (`red = …`) or as
  // terminal colours (`color1 = …`). Each hue lists the named key first and
  // the ANSI slot as fallback.
  readonly property var hueSources: ({
    red: ["red", "color1"],
    orange: ["orange"],
    yellow: ["yellow", "color3"],
    green: ["green", "color2"],
    cyan: ["cyan", "color6"],
    blue: ["blue", "color4"],
    magenta: ["magenta", "color5"]
  })
  readonly property var roleNames: ["accent", "foreground", "urgent", "muted", "background"]

  // Theme value for a name, or "" if the theme doesn't define it.
  function themeValue(name) {
    var key = String(name || "").trim().toLowerCase()
    if (roleNames.indexOf(key) >= 0) return String(Color.flatColor(key, Color.accent))
    var sources = hueSources[key] || [key]
    for (var i = 0; i < sources.length; i++)
      if (themePalette[sources[i]]) return themePalette[sources[i]]
    return ""
  }

  function resolveColor(name) {
    var value = themeValue(name)
    return value !== "" ? value : Color.flatColor(name, Color.accent)
  }

  function loadPalette(raw) {
    var palette = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) palette[match[1].toLowerCase()] = match[2]
    }
    themePalette = palette
  }

  // Swatches for the settings view: accent, foreground, then the hues this
  // theme actually defines, each colour only once (many themes reuse
  // accent as blue, or foreground as a hue). The current setting always
  // stays pickable, even if it is a duplicate, a hex value or an old
  // colorN name.
  readonly property var swatchNames: {
    var names = []
    var seen = {}
    var candidates = ["accent", "foreground", "red", "orange", "yellow", "green", "cyan", "blue", "magenta"]
    for (var i = 0; i < candidates.length; i++) {
      var value = themeValue(candidates[i]).toLowerCase()
      if (value === "" || seen[value]) continue
      seen[value] = true
      names.push(candidates[i])
    }
    var current = colorSetting.toLowerCase()
    if (current !== "" && names.indexOf(current) < 0) names.push(colorSetting)
    return names
  }

  readonly property var playerArgs: {
    var args = []
    if (player !== "") args.push("--player=" + player)
    if (ignorePlayers !== "") args.push("--ignore-player=" + ignorePlayers)
    return args
  }

  readonly property string fieldSep: ""

  property string status: "Stopped"
  property string title: ""
  property string artist: ""
  property string artUrl: ""

  readonly property bool isPlaying: status === "Playing"
  readonly property bool hasMedia: title !== "" || artist !== ""
  readonly property string nowPlayingText: (isPlaying && hasMedia) ? (title + (artist ? "  ·  " + artist : "")) : "Nothing playing"

  property real level0: 0
  property real level1: 0
  property real level2: 0
  property real level3: 0

  readonly property string cavaConfigPath: Qt.resolvedUrl("cava.conf").toString().replace(/^file:\/\//, "")

  property bool popupOpen: false
  property bool settingsOpen: false
  function close() { popupOpen = false }

  onPopupOpenChanged: if (!popupOpen) settingsOpen = false
  onSettingsOpenChanged: if (settingsOpen) refreshPlayers()

  // Names from `playerctl -l`, with the ".instance…" suffix some players
  // (browsers) add stripped — playerctl matches the bare name to every
  // instance, and the bare name is what users recognise.
  property var availablePlayers: []

  readonly property var ignoredList: ignorePlayers === "" ? []
    : ignorePlayers.split(",").map(function(p) { return p.trim() }).filter(function(p) { return p !== "" })

  // Options for the player picker: Auto, every running player, and the
  // current setting even if that player isn't running right now (or is a
  // hand-written priority list), so the picker always shows what's active.
  readonly property var playerOptions: {
    var opts = [{ value: "", label: "Auto" }]
    var seen = {}
    for (var i = 0; i < availablePlayers.length; i++) {
      opts.push({ value: availablePlayers[i], label: availablePlayers[i] })
      seen[availablePlayers[i]] = true
    }
    if (player !== "" && !seen[player]) opts.push({ value: player, label: player })
    return opts
  }

  function refreshPlayers() {
    listProc.running = false
    listProc.running = true
  }

  // Same write path as the host's own settings editing: update the inline
  // shell.json entry, which re-injects `settings` and re-evaluates every
  // setting() binding above.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setSetting(key, value) {
    var values = {}
    values[key] = value
    persistSettings(values)
  }

  function toggleIgnored(name) {
    var list = ignoredList.slice()
    var i = list.indexOf(name)
    if (i >= 0) list.splice(i, 1)
    else list.push(name)
    setSetting("ignorePlayers", list.join(","))
  }

  function resetLevels() {
    level0 = 0; level1 = 0; level2 = 0; level3 = 0
  }

  function runPlayerctl(args) {
    ctlProc.command = ["playerctl"].concat(root.playerArgs, args)
    ctlProc.running = true
  }

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  onIsPlayingChanged: {
    cavaProc.running = isPlaying
    if (!isPlaying) resetLevels()
  }

  // A changed player filter only reaches playerctl on a fresh process, so
  // drop the old state and restart both watchers with the new arguments.
  // The commands are rebuilt here rather than left to their bindings: this
  // handler can run before those bindings update, and the one-shot query
  // would then start with the old filter and report the just-ignored
  // player as Playing again.
  onPlayerArgsChanged: Qt.callLater(root.restartWatchers)

  function metadataCommand(follow) {
    return ["playerctl"].concat(root.playerArgs, follow ? ["--follow"] : [], ["metadata", "--format", root.metadataFormat])
  }

  function restartWatchers() {
    initProc.running = false
    followProc.running = false
    clearMedia()
    initProc.command = metadataCommand(false)
    followProc.command = metadataCommand(true)
    // Start the fresh query a moment later so any line the killed processes
    // still had in flight lands before it, not after it.
    initRestart.restart()
    followRestart.restart()
  }

  function clearMedia() {
    status = "Stopped"; title = ""; artist = ""; artUrl = ""
  }

  Timer { id: initRestart; interval: 200; repeat: false; onTriggered: initProc.running = true }

  readonly property string metadataFormat:
    "{{status}}" + root.fieldSep + "{{artist}}" + root.fieldSep + "{{title}}" + root.fieldSep + "{{mpris:artUrl}}"

  function applyMetadataLine(line) {
    var parts = String(line || "").split(root.fieldSep)
    if (parts.length < 3) return
    root.status = parts[0] || "Stopped"
    root.artist = parts[1] || ""
    root.title = parts[2] || ""
    root.artUrl = parts.length > 3 ? (parts[3] || "") : ""
  }

  FileView {
    id: paletteFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    printErrors: false
    onLoaded: root.loadPalette(text())
    onLoadFailed: root.loadPalette("")
  }

  // Omarchy pushes theme switches over IPC instead of watching colors.toml,
  // so follow the same signal: any change of the foundational colours means
  // a new theme, and the numbered palette is re-read with it.
  Connections {
    target: Color
    function onAccentChanged() { paletteFile.reload() }
    function onForegroundChanged() { paletteFile.reload() }
    function onBackgroundChanged() { paletteFile.reload() }
  }

  // `omarchy-shell io.github.taiku666.music-eq <function>`, for keybindings.
  IpcHandler {
    target: root.moduleName

    function toggle(): void { root.popupOpen = !root.popupOpen }
    function open(): void { root.popupOpen = true }
    function close(): void { root.popupOpen = false }
    function settings(): void { root.popupOpen = true; root.settingsOpen = true }
    function playPause(): void { root.runPlayerctl(["play-pause"]) }
    function next(): void { root.runPlayerctl(["next"]) }
    function previous(): void { root.runPlayerctl(["previous"]) }
  }

  // Fire-and-forget control commands (play-pause / next / previous).
  Process { id: ctlProc }

  Process {
    id: listProc
    command: ["playerctl", "-l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = []
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var name = lines[i].trim().replace(/\.instance.*$/, "")
          if (name !== "" && names.indexOf(name) < 0) names.push(name)
        }
        root.availablePlayers = names
      }
    }
  }

  // One-shot query so the widget already has correct title/artist (and
  // therefore correct label width) on its very first layout pass. Without
  // this, the widget starts with an empty label — width 0 — and only grows
  // once followProc's first line arrives; that later width change is not
  // reliably picked up by the bar's layout, leaving the label permanently
  // collapsed until a full `omarchy restart shell`.
  Process {
    id: initProc
    command: root.metadataCommand(false)
    running: true
    stdout: SplitParser { onRead: function(line) { root.applyMetadataLine(line) } }
    // Non-zero means no (unignored) player; that is a real "stopped" answer
    // and has to override whatever state a previous filter left behind.
    onExited: function(exitCode) { if (exitCode !== 0) root.clearMedia() }
  }

  // Long-running MPRIS watcher: prints a new line on every status/track
  // change instead of polling. Restarted if it exits (no player yet, or the
  // active player disappeared).
  Process {
    id: followProc
    command: root.metadataCommand(true)
    running: true
    stdout: SplitParser { onRead: function(line) { root.applyMetadataLine(line) } }
    onExited: followRestart.start()
  }

  Timer { id: followRestart; interval: 1500; repeat: false; onTriggered: followProc.running = true }

  // Values below noiseGate (0-100 cava scale) are treated as silence/noise
  // floor and clamped to exactly 0, so quiet passages rest flat instead of
  // constantly re-triggering the height animation for imperceptible jitter.
  function gated(raw) {
    var n = Number(raw)
    if (!isFinite(n) || n < root.noiseGate) return 0
    return Math.max(0, Math.min(1, n / 100))
  }

  Process {
    id: cavaProc
    command: ["cava", "-p", root.cavaConfigPath]
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line || "").split(";").filter(function(p) { return p.length > 0 })
        if (parts.length < 4) return
        root.level0 = root.gated(parts[0])
        root.level1 = root.gated(parts[1])
        root.level2 = root.gated(parts[2])
        root.level3 = root.gated(parts[3])
      }
    }
    onExited: function() { if (root.isPlaying) cavaRestart.start() }
  }

  Timer { id: cavaRestart; interval: 500; repeat: false; onTriggered: if (root.isPlaying) cavaProc.running = true }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Plain Item (not a Row) with explicit, fixed geometry — avoids any
    // layout-engine recalculation of the container's own size/position as
    // bar heights change, so the bottom edge is a hard pixel value, never
    // a value derived from the tallest current child.
    Item {
      id: eq
      readonly property real barWidth: Style.space(3)
      readonly property real barSpacing: Style.space(2)
      readonly property real barMaxHeight: Style.space(12)
      readonly property real barMinHeight: Style.space(2)
      width: 4 * barWidth + 3 * barSpacing
      height: barMaxHeight
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: root.isPlaying ? [root.level0, root.level1, root.level2, root.level3] : [0, 0, 0, 0]

        Rectangle {
          id: bar
          required property var modelData
          required property int index
          width: eq.barWidth
          radius: width / 2
          x: index * (eq.barWidth + eq.barSpacing)
          y: eq.barMaxHeight - height
          height: eq.barMinHeight + (eq.barMaxHeight - eq.barMinHeight) * modelData
          opacity: root.isPlaying ? 1 : 0.35
          color: index === 0 ? Qt.lighter(root.barColor, 1.5)
               : index === 1 ? Qt.lighter(root.barColor, 1.2)
               : index === 2 ? root.barColor
               : Qt.darker(root.barColor, 1.3)

          Behavior on height {
            NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
          }
          Behavior on opacity {
            NumberAnimation { duration: 200 }
          }
        }
      }
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: labelText.implicitHeight
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showText && !root.vertical && root.isPlaying && root.hasMedia

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.nowPlayingText
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter

        property bool needsScroll: implicitWidth > scrollClip.width
        x: needsScroll ? x : 0

        NumberAnimation on x {
          running: labelText.needsScroll && !root.popupOpen && !root.vertical
          loops: Animation.Infinite
          duration: Math.max(6000, (scrollClip.width + labelText.implicitWidth) / root.scrollSpeed * 1000)
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.runPlayerctl(["play-pause"])
      } else if (mouse.button === Qt.RightButton) {
        root.runPlayerctl(["next"])
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (wheel.angleDelta.y > 0) root.runPlayerctl(["previous"])
      else if (wheel.angleDelta.y < 0) root.runPlayerctl(["next"])
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.nowPlayingText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(root.settingsOpen ? settingsView.implicitHeight : playerView.implicitHeight)

    // Player view: art, title/artist, transport controls. The gear in the
    // top-right corner swaps the card to the settings view below.
    Column {
      id: playerView
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)
      visible: !root.settingsOpen

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(56)
          height: Style.space(56)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.artUrl
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: root.artUrl === ""
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(66) - settingsButton.width

          Text {
            textFormat: Text.PlainText
            text: root.title || "Nothing playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }

        Button {
          id: settingsButton
          iconText: "󰒓"
          tooltipText: "Settings"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingY
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.settingsOpen = true
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.hasMedia
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runPlayerctl(["previous"])
        }

        Button {
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.hasMedia
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runPlayerctl(["play-pause"])
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.hasMedia
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runPlayerctl(["next"])
        }
      }
    }

    // Settings view. Everything is pointer-driven (the popup card never
    // takes keyboard focus), and every change is written straight to this
    // widget's shell.json entry via persistSettings().
    Column {
      id: settingsView
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(10)
      visible: root.settingsOpen

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          id: backButton
          iconText: "󰁍"
          tooltipText: "Back"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingY
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.settingsOpen = false
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Music EQ settings"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }

      PanelSeparator { foreground: root.bar.foreground }
      PanelSectionHeader { text: "PLAYER"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.playerOptions

          Button {
            required property var modelData
            text: modelData.label
            fontSize: Style.font.bodySmall
            fontFamily: root.bar.fontFamily
            foreground: root.bar.foreground
            bordered: true
            active: root.player === modelData.value
            onClicked: root.setSetting("player", modelData.value)
          }
        }
      }

      Text {
        width: parent.width
        visible: root.availablePlayers.length === 0
        text: "No players running. Start one to pick it here."
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Ignoring only matters when following "Auto"; with a fixed player
      // the other players are never looked at anyway.
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.player === "" && root.availablePlayers.length > 0

        Text {
          width: parent.width
          text: "Ignore while on Auto"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.availablePlayers

          Item {
            required property var modelData
            width: parent.width
            height: ignoreSwitch.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: modelData
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            ToggleSwitch {
              id: ignoreSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.ignoredList.indexOf(modelData) >= 0
              foreground: root.bar.foreground
              onToggled: root.toggleIgnored(modelData)
            }
          }
        }
      }

      PanelSeparator { foreground: root.bar.foreground }
      PanelSectionHeader { text: "BARS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

      // Colour swatches (see swatchNames). Only the name is stored, so the
      // bars follow theme switches.
      Flow {
        width: parent.width
        spacing: Style.space(8)

        Repeater {
          model: root.swatchNames
          ColorSwatch {
            required property var modelData
            colorName: modelData
          }
        }
      }

      Item {
        width: parent.width
        height: gateSlider.height + gateLabel.height + Style.space(4)

        Text {
          id: gateLabel
          anchors.left: parent.left
          text: "Noise gate"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.right: parent.right
          text: Math.round(gateSlider.dragging ? gateSlider.liveValue : root.noiseGate)
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSlider {
          id: gateSlider
          bar: root.bar
          anchors.bottom: parent.bottom
          width: parent.width
          minimum: 0
          maximum: 50
          step: 1
          integer: true
          value: root.noiseGate
          onReleased: function(v) { root.setSetting("noiseGate", Math.round(v)) }
        }
      }

      PanelSeparator { foreground: root.bar.foreground }
      PanelSectionHeader { text: "TEXT"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

      Item {
        width: parent.width
        height: textSwitch.implicitHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Show now-playing text"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ToggleSwitch {
          id: textSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.showText
          foreground: root.bar.foreground
          onToggled: root.setSetting("showText", !root.showText)
        }
      }

      Item {
        width: parent.width
        height: widthSlider.height + widthLabel.height + Style.space(4)
        visible: root.showText

        Text {
          id: widthLabel
          anchors.left: parent.left
          text: "Max width"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.right: parent.right
          text: Math.round(widthSlider.dragging ? widthSlider.liveValue : root.maxLabelWidth) + " px"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSlider {
          id: widthSlider
          bar: root.bar
          anchors.bottom: parent.bottom
          width: parent.width
          minimum: 40
          maximum: 600
          step: 10
          integer: true
          value: root.maxLabelWidth
          onReleased: function(v) { root.setSetting("maxLabelWidth", Math.round(v)) }
        }
      }

      Item {
        width: parent.width
        height: speedSlider.height + speedLabel.height + Style.space(4)
        visible: root.showText

        Text {
          id: speedLabel
          anchors.left: parent.left
          text: "Scroll speed"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.right: parent.right
          text: Math.round(speedSlider.dragging ? speedSlider.liveValue : root.scrollSpeed) + " px/s"
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelSlider {
          id: speedSlider
          bar: root.bar
          anchors.bottom: parent.bottom
          width: parent.width
          minimum: 5
          maximum: 200
          step: 5
          integer: true
          value: root.scrollSpeed
          onReleased: function(v) { root.setSetting("scrollSpeed", Math.round(v)) }
        }
      }
    }
  }

  component ColorSwatch: Rectangle {
    id: swatch
    property string colorName: ""
    readonly property bool selected: root.colorSetting.toLowerCase() === colorName.toLowerCase()
    readonly property color swatchColor: root.resolveColor(colorName)
    width: Style.space(22)
    height: width
    radius: width / 2
    color: swatchColor
    // Faint ring on unselected swatches so dark colours (muted, color0)
    // stay visible against the card background.
    border.width: selected ? Style.space(2) : 1
    border.color: selected ? root.bar.foreground : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.3)

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(3)
      cursorShape: Qt.PointingHandCursor
      hoverEnabled: true
      onClicked: root.setSetting("color", swatch.colorName)
      onEntered: if (root.bar) root.bar.showTooltip(swatch, swatch.colorName + "  " + String(swatch.swatchColor))
      onExited: if (root.bar) root.bar.hideTooltip(swatch)
    }
  }
}
