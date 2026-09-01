import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Claude Code usage on the bar: the same pill clusage-waybar has always
// printed, but clicking it opens a shell popup instead of firing a
// notification, so it behaves like every other clickable bar icon.
//
// `clusage-waybar --panel` prints the bar text and the limits as data in one
// object, so the popup reads what the bar already fetched — one call per
// refresh, not one per view. The endpoint 429s under repeat calls, so opening
// the panel only refetches when the last fetch is older than staleAfterMs.
//
// Reset times arrive as ISO timestamps and count down against a local clock,
// so an open panel stays honest between refreshes.
Panel {
  id: root
  moduleName: "io.github.ncr.clusage"
  ipcTarget: "io.github.ncr.clusage"

  readonly property string exec: String(setting("command", "~/.local/bin/clusage-waybar")) + " --panel"
  readonly property int refreshMs: Math.max(15, Number(setting("refreshIntervalSec", 60)) || 60) * 1000
  readonly property int staleAfterMs: 30000
  // The endpoint 429s readily, and a refresh or two bouncing off it says
  // nothing about the numbers — they are still minutes old. Only dim the pill
  // once the cached figures are old enough to actually mislead.
  readonly property int dimAfterMs: 600000

  property string barText: ""
  readonly property var segments: root.splitSegments(root.barText)
  property bool critical: false
  property bool stale: false
  property real fetchedAtMs: 0
  property string updated: ""
  property string errorText: ""
  property var limits: []
  property var overage: null
  property real lastFetchMs: 0
  property bool refreshing: false

  // Ticks the countdowns without touching the API.
  property date now: new Date()

  readonly property bool outdated: stale && fetchedAtMs > 0
    && root.now.getTime() - fetchedAtMs > dimAfterMs

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The bar draws its open-panel dot under the module; without this hint it
  // sizes the dot off the whole slot, which on a text pill is far too wide.
  readonly property real openPanelIndicatorWidth: content.implicitWidth

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (proc.running) return
    refreshing = true
    proc.running = true
  }

  function open() {
    if (Date.now() - lastFetchMs > staleAfterMs) refresh()
    root.controller.show()
  }

  function apply(raw) {
    var data = {}
    try {
      data = JSON.parse(String(raw || "").trim() || "{}")
    } catch (e) {
      errorText = "clusage: unreadable output"
      return
    }

    var klass = String(data["class"] || "")
    barText = String(data.text || "")
    critical = klass.indexOf("critical") !== -1
    var panel = data.panel || {}
    stale = panel.stale === true
    fetchedAtMs = Number(panel.fetched_at || 0) * 1000
    updated = String(panel.updated || "")
    errorText = String(panel.error || "")
    limits = panel.limits || []
    overage = panel.overage || null
    if (panel.ok === true && !stale) lastFetchMs = Date.now()
  }

  // Splits the bar text into runs of icon glyphs and runs of ordinary text.
  // Nerd Font marks live in the private use areas, so a codepoint test is
  // enough — no need to know which glyph is which.
  function splitSegments(text) {
    var s = String(text || "")
    var segments = []
    var current = null
    for (var i = 0; i < s.length; ) {
      var cp = s.codePointAt(i)
      var len = cp > 0xFFFF ? 2 : 1
      var chunk = s.substr(i, len)
      i += len
      var icon = (cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0x10FFFD)
      if (!current || current.icon !== icon) {
        current = { icon: icon, text: "" }
        segments.push(current)
      }
      current.text += chunk
    }
    return segments
  }

  // Blocks reset on the hour, but the API jitters either side of it
  // ("15:00:00.97" one call, "14:59:59.95" the next), so truncating renders a
  // 17:00 reset as 16:59. Round to the minute instead, the same way the
  // Python side does.
  function resetDate(iso) {
    if (!iso) return null
    var t = Date.parse(iso)
    if (isNaN(t)) return null
    return new Date(Math.floor((t + 30000) / 60000) * 60000)
  }

  // "3h 34m", "2d 12h", "47m" — the same shape the agents panel uses, so the
  // two limit popups read alike.
  function countdown(at) {
    if (!at) return ""
    var secs = Math.round((at.getTime() - root.now.getTime()) / 1000)
    if (secs <= 0) return "now"
    var mins = Math.floor(secs / 60)
    var hours = Math.floor(mins / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (mins % 60) + "m"
    return mins + "m"
  }

  function resetLabel(limit) {
    var at = resetDate(limit ? limit.resets_at : "")
    if (!at) return ""
    var left = countdown(at)
    if (left === "now") return "Resetting now"
    // A same-day reset is legible as a clock time; a weekly one needs the day.
    var sameDay = at.toDateString() === root.now.toDateString()
    var stamp = sameDay ? Qt.formatTime(at, "HH:mm") : Qt.formatDateTime(at, "ddd HH:mm")
    return "Resets in " + left + " · " + stamp
  }

  function fraction(limit) {
    var p = limit ? Number(limit.pct) : NaN
    if (!isFinite(p)) return -1
    return Math.max(0, Math.min(1, p / 100))
  }

  function percentLabel(limit) {
    var p = limit ? Number(limit.pct) : NaN
    return isFinite(p) ? Math.round(p) + "%" : "—"
  }

  Process {
    id: proc
    command: ["bash", "-c", root.exec]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: root.refreshing = false
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.now = new Date()
  }

  // The pill is icons and digits in one line, and holding them in a single
  // Text is what pushed it out of line with the clock: a nerd-font glyph has
  // a taller ascent than the digits, so the shared line box grew and the
  // centred text dropped two pixels. Each run gets its own Text instead, all
  // sharing one baseline, and that baseline sits where the clock and the
  // treadmill put theirs.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: root.barText !== ""
    fontSize: Style.font.body
    active: root.critical
    dimmed: root.outdated
    // The same slot padding the clock uses, so the two pills sit in the bar
    // with the same breathing room.
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fixedWidth: root.bar && root.bar.vertical
      ? -1
      : Math.round(content.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    // Suppressed on purpose: the panel is the detail view now, and a tooltip
    // racing it on hover is what this module used to do wrong.
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }

    // Reference line: a plain digit in the bar font gives the line height and
    // the baseline every piece of the pill lines up on.
    Text {
      id: metric
      visible: false
      text: "0"
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }

    Row {
      id: content
      spacing: 0
      height: metric.implicitHeight
      // Centred on a line box the height of one plain digit, which is what
      // the clock centres too — measured, the digits land on the same rows.
      anchors.centerIn: parent

      Repeater {
        model: root.segments

        Item {
          required property var modelData
          implicitWidth: piece.implicitWidth
          height: content.height

          Text {
            id: piece
            y: metric.baselineOffset - baselineOffset
            text: modelData.text
            color: button.active && button.useActiveColor ? button.activeColor : button.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.refresh()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Claude Code"
          meta: {
            if (root.refreshing) return "refreshing…"
            if (root.errorText !== "") return "unavailable"
            if (root.updated === "") return ""
            return (root.stale ? "cached " : "updated ") + root.updated
          }
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: "\u{f06a9}"  // nf-md-robot, the same mark the bar pill carries
              color: root.critical ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Column {
          width: parent.width
          spacing: Style.space(14)

          PanelSectionHeader {
            width: parent.width
            text: "LIMITS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.limits

            LimitRow {
              width: column.width
              limit: modelData
            }
          }
        }

        PanelSeparator {
          visible: !!root.overage
          foreground: root.foreground
        }

        Item {
          width: parent.width
          visible: !!root.overage
          implicitHeight: overageLabel.implicitHeight

          PanelSectionHeader {
            id: overageLabel
            text: "OVERAGE"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.left: parent.left
          }

          Text {
            anchors.right: parent.right
            anchors.baseline: overageLabel.baseline
            text: root.overage
              ? Math.round(root.overage.used) + "/" + Math.round(root.overage.limit) + " " + root.overage.currency
              : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

      }
    }
  }

  // One limit: name and percentage over a meter, with its countdown below.
  component LimitRow: Column {
    id: limitRow
    property var limit: null

    readonly property real value: root.fraction(limitRow.limit)
    readonly property bool alarming: value >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameText.implicitHeight, valueText.implicitHeight)

      Text {
        id: nameText
        text: limitRow.limit ? limitRow.limit.label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
      }

      // The binding cap — the one that will actually stop you — is the reason
      // this panel exists, so it gets the marker the tooltip used to carry.
      Text {
        id: bindingMark
        visible: limitRow.limit && limitRow.limit.active === true
        text: "◀"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: nameText.right
        anchors.leftMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: subText
        text: limitRow.limit ? limitRow.limit.sublabel : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: bindingMark.visible ? bindingMark.right : nameText.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: valueText.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
      }

      Text {
        id: valueText
        text: root.percentLabel(limitRow.limit)
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      implicitHeight: meterThickness

      readonly property real meterThickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

      Rectangle {
        id: meterTrack
        anchors.fill: parent
        radius: height / 2
        color: root.track
      }

      Rectangle {
        anchors.left: meterTrack.left
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: meterTrack.width * Math.max(0, limitRow.value)
        color: limitRow.alarming ? root.urgent : root.foreground

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      width: parent.width
      text: root.resetLabel(limitRow.limit)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
