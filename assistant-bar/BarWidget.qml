import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Voice-assistant state indicator for the Omarchy bar.
//
// Reads a one-line state file written by ~/bin/assistant:
//   ~/.local/state/assistant/state  ->  idle | listening | thinking | speaking
// and shows the matching glyph.
//
// A plain file rather than an IPC call, on purpose: the bar widget survives
// daemon restarts, never blocks the shell, and the same file drives a waybar
// module if you ever switch bars.

Item {
  id: root

  property string stateFile: Quickshell.env("HOME") + "/.local/state/assistant/state"
  property string state: "idle"

  readonly property string glyph: {
    switch (root.state) {
      case "listening": return "󰍉"
      case "thinking":  return "󰭎"
      case "speaking":  return "󰓃"
      default:          return "󰍁"
    }
  }

  readonly property string label: {
    switch (root.state) {
      case "listening": return "Assistant is listening"
      case "thinking":  return "Assistant is thinking"
      case "speaking":  return "Assistant is speaking"
      default:          return "Assistant"
    }
  }

  readonly property bool active: root.state !== "idle"

  // Brighter while working, dimmed at rest.
  readonly property color glyphColor: root.active
    ? (root.bar ? root.bar.foreground : Color.foreground)
    : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.8)

  FileView {
    id: stateView
    path: root.stateFile
    printErrors: false
    onLoaded: root.state = root.readState()
    onFileChanged: root.state = root.readState()
  }

  function readState() {
    var raw = String(stateView.text() || "").trim()
    return ["idle", "listening", "thinking", "speaking"].indexOf(raw) !== -1 ? raw : "idle"
  }

  // FileView has no poll option in this Quickshell build, so poll on a timer.
  // One second is plenty for a state indicator and costs nothing.
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.state = root.readState()
  }

  BarIconButton {
    id: button
    bar: root.bar
    text: root.glyph
    tooltipText: root.label
    foreground: root.glyphColor
    // Keep the icon's own color rather than swapping to the urgent color.
    useActiveColor: false
    active: root.active

    onPressed: function(button) {
      // A click is a handy manual trigger: push-to-talk without the keybind.
      if (button === Qt.LeftButton) {
        Quickshell.execDetached(["bash", "-lc", "assistant listen"])
      }
    }
  }
}
