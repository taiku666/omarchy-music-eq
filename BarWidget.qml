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

  readonly property string fieldSep: ""

  property string status: "Stopped"
  property string title: ""
  property string artist: ""
  property string artUrl: ""

  readonly property bool isPlaying: status === "Playing"
  readonly property bool hasMedia: title !== "" || artist !== ""
  readonly property string nowPlayingText: (isPlaying && hasMedia) ? (title + (artist ? "  ·  " + artist : "")) : "Nothing playing"
  property real maxLabelWidth: 160

  property real level0: 0
  property real level1: 0
  property real level2: 0
  property real level3: 0

  readonly property string cavaConfigPath: Qt.resolvedUrl("cava.conf").toString().replace(/^file:\/\//, "")

  property bool popupOpen: false
  function close() { popupOpen = false }

  function resetLevels() {
    level0 = 0; level1 = 0; level2 = 0; level3 = 0
  }

  function runPlayerctl(args) {
    ctlProc.command = ["playerctl"].concat(args)
    ctlProc.running = true
  }

  visible: true
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  onIsPlayingChanged: {
    cavaProc.running = isPlaying
    if (!isPlaying) resetLevels()
  }

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

  // Fire-and-forget control commands (play-pause / next / previous).
  Process { id: ctlProc }

  // One-shot query so the widget already has correct title/artist (and
  // therefore correct label width) on its very first layout pass. Without
  // this, the widget starts with an empty label — width 0 — and only grows
  // once followProc's first line arrives; that later width change is not
  // reliably picked up by the bar's layout, leaving the label permanently
  // collapsed until a full `omarchy restart shell`.
  Process {
    id: initProc
    command: ["playerctl", "metadata", "--format", root.metadataFormat]
    running: true
    stdout: SplitParser { onRead: function(line) { root.applyMetadataLine(line) } }
  }

  // Long-running MPRIS watcher: prints a new line on every status/track
  // change instead of polling. Restarted if it exits (no player yet, or the
  // active player disappeared).
  Process {
    id: followProc
    command: ["playerctl", "--follow", "metadata", "--format", root.metadataFormat]
    running: true
    stdout: SplitParser { onRead: function(line) { root.applyMetadataLine(line) } }
    onExited: followRestart.start()
  }

  Timer { id: followRestart; interval: 1500; repeat: false; onTriggered: followProc.running = true }

  // Values below this (0-100 cava scale) are treated as silence/noise floor
  // and clamped to exactly 0, so quiet passages rest flat instead of
  // constantly re-triggering the height animation for imperceptible jitter.
  readonly property int noiseGate: 14

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
          color: index === 0 ? Qt.lighter(Color.accent, 1.5)
               : index === 1 ? Qt.lighter(Color.accent, 1.2)
               : index === 2 ? Color.accent
               : Qt.darker(Color.accent, 1.3)

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
      visible: !root.vertical && root.isPlaying && root.hasMedia

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
          duration: Math.max(6000, labelText.implicitWidth * 25)
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
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

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
          width: parent.width - Style.space(66)

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
  }
}
