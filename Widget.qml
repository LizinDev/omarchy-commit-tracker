import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// Commit Tracker: a one-row, GitHub-style contribution strip. One box per day
// for the last `days` days (oldest on the left, today on the right), shaded
// by how much was committed that day.
//
// The numbers come from bin/commit-tracker, which scans local git repositories
// and prints one JSON object (see README.md). It runs on a slow poll and,
// right after a commit, when an inotifywait on each repository's reflog
// directory wakes it.
//
// Left click opens the history panel (HistoryPanel.qml), right click the
// settings menu (SettingsMenu.qml), middle click refreshes. The left button is
// never taken by a MouseArea here: the bar delivers it through triggerPress(),
// which keeps drag-to-reorder working.
BarWidget {
  id: root
  moduleName: "io.github.lizindev.commit-tracker"

  // ---------------------------------------------------------------- settings
  //
  // Manifest defaults are catalogue metadata only; nothing merges them into
  // `settings`, so every read carries its own fallback.

  readonly property int dayCount: intSetting("days", 5, 1, 31)
  readonly property var roots: listSetting("roots", ["~"])
  readonly property var authors: listSetting("authors", [])
  readonly property int maxDepth: intSetting("maxDepth", 4, 0, 8)
  readonly property string metric: setting("metric", "commits") === "lines" ? "lines" : "commits"
  readonly property string levels: String(setting("levels", "default")).trim()
  readonly property bool includeMerges: boolSetting("includeMerges", false)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 15, 3600)
  readonly property string colorToken: String(setting("color", "accent"))
  readonly property string appearance: setting("appearance", "theme") === "github" ? "github" : "theme"
  readonly property bool highlightToday: boolSetting("highlightToday", true)
  readonly property bool showUnpushed: boolSetting("showUnpushed", true)
  readonly property int graphWeeks: intSetting("graphWeeks", 26, 4, 53)

  function intSetting(name, fallback, min, max) {
    var n = Math.round(Number(setting(name, fallback)))
    return isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback
  }

  // `omarchy bar set` stores plain strings unless given --json, so "false"
  // has to read as false.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(text) !== -1) return true
    if (["false", "0", "no", "off"].indexOf(text) !== -1) return false
    return fallback
  }

  function isList(value) {
    return value !== null && typeof value === "object" && typeof value.length === "number"
  }

  // Lists accept a JSON array or a comma-separated string, so both a shell.json
  // array and `omarchy bar set <id> roots "~/src, ~/work"` work.
  function listSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "string") {
      var text = value.trim()
      var parsed = null
      if (text.charAt(0) === "[") {
        try { parsed = JSON.parse(text) } catch (e) { parsed = null }
      }
      value = isList(parsed) ? parsed : text.split(",")
    }
    if (!isList(value)) return fallback
    var out = []
    for (var i = 0; i < value.length; i++) {
      var item = value[i] === undefined || value[i] === null ? "" : String(value[i]).trim()
      if (item !== "" && out.indexOf(item) === -1) out.push(item)
    }
    return out.length > 0 ? out : fallback
  }

  // Written back to this entry in shell.json the way the clock persists its
  // label format; applied locally first so the strip and menus react at once.
  function setSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var name in root.settings) if (name !== "id") entry[name] = root.settings[name]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ------------------------------------------------------------------- data

  property var days: []
  property var thresholds: [1, 2, 4, 8]
  property var watchPaths: []
  property var warnings: []
  property var unpushed: null
  property string errorText: ""
  property bool loaded: false
  property bool awaitingOutput: false
  property bool refreshQueued: false
  property string runKey: ""
  property int hoveredIndex: -1

  // Omarchy 4.0.3 strips manifest.__sourceDir from third-party plugins, so the
  // collector is found relative to this file instead.
  readonly property string collectorPath: decodeURIComponent(String(Qt.resolvedUrl("bin/commit-tracker")).replace(/^file:\/\//, ""))

  // `--opt=value` keeps a value that starts with "-" from reading as a flag.
  readonly property var collectorCommand: {
    var cmd = ["python3", collectorPath,
               "--days=" + dayCount,
               "--max-depth=" + maxDepth,
               "--metric=" + metric]
    if (["", "default", "auto"].indexOf(levels.toLowerCase()) === -1) cmd.push("--levels=" + levels)
    for (var i = 0; i < roots.length; i++) cmd.push("--root=" + roots[i])
    for (var j = 0; j < authors.length; j++) cmd.push("--author=" + authors[j])
    if (includeMerges) cmd.push("--include-merges")
    return cmd
  }

  onCollectorCommandChanged: refreshDebounce.restart()

  // ------------------------------------------------------------- leadership
  //
  // The bar builds one instance of this widget per monitor. Only the first
  // one runs the collector and the watcher; it hands every result to the rest,
  // so extra monitors cost nothing.

  property bool leader: true

  function peers() {
    return root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : []
  }

  function leaderWidget() {
    var items = peers()
    return items.length > 0 && items[0] ? items[0] : root
  }

  // Automatic triggers (poll, settings, midnight) only ever run on the leader.
  function pollTick() {
    root.leader = leaderWidget() === root
    if (root.leader) runCollector()
    syncWatcher()
  }

  // User-initiated (click, IPC): hand the work to whichever instance leads.
  function refresh() {
    var lead = leaderWidget()
    if (lead !== root && typeof lead.runCollector === "function") lead.runCollector()
    else runCollector()
  }

  function publish() {
    var state = {
      days: root.days, thresholds: root.thresholds, watchPaths: root.watchPaths, warnings: root.warnings,
      unpushed: root.unpushed, errorText: root.errorText, loaded: root.loaded
    }
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && peer !== root && typeof peer.receive === "function") peer.receive(state)
    }
  }

  function receive(state) {
    root.days = state.days
    root.thresholds = state.thresholds
    root.watchPaths = state.watchPaths
    root.warnings = state.warnings
    root.unpushed = state.unpushed
    root.errorText = state.errorText
    root.loaded = state.loaded
    stripChanged()
  }

  // After every new strip result: the hovered tooltip and an open history
  // panel follow it.
  function stripChanged() {
    refreshHoveredTooltip()
    if (root.panelOpen) historyDebounce.restart()
  }

  // -------------------------------------------------------------- collector

  function runCollector() {
    if (collector.running) {
      refreshQueued = true
      return
    }
    refreshQueued = false
    awaitingOutput = true
    var command = collectorCommand
    runKey = JSON.stringify(command)
    collector.command = command
    collector.running = true
  }

  function applyOutput(text) {
    awaitingOutput = false
    // A result computed for settings that have changed since is dropped; the
    // settings change already queued a fresh run.
    if (runKey !== JSON.stringify(collectorCommand)) return

    var raw = String(text || "").trim()
    var data = null
    try { data = raw ? JSON.parse(raw) : null } catch (e) { data = null }

    if (!data || typeof data !== "object") {
      errorText = raw ? "Collector output was not valid JSON" : "Collector produced no output"
    } else if (data.error) {
      errorText = String(data.error)
    } else if (!isList(data.days)) {
      errorText = "Collector output has no days"
    } else {
      days = data.days
      thresholds = isList(data.thresholds) && data.thresholds.length === 4 ? data.thresholds : [1, 2, 4, 8]
      watchPaths = absolutePaths(data.watch)
      warnings = isList(data.warnings) ? data.warnings : []
      unpushed = data.unpushed && typeof data.unpushed === "object" ? data.unpushed : null
      errorText = ""
      loaded = true
    }
    stripChanged()
    publish()
    syncWatcher()
  }

  function absolutePaths(list) {
    var out = []
    if (!isList(list)) return out
    for (var i = 0; i < list.length && out.length < 512; i++) {
      var path = String(list[i] || "")
      if (path.charAt(0) === "/") out.push(path)
    }
    return out
  }

  // ---------------------------------------------------------------- history
  //
  // The panel's graph and commit list come from a second, heavier collector
  // run with --history-days. It belongs to whichever instance shows the panel
  // (the monitor that was clicked), so it never goes through the leader.

  property var history: null
  property bool historyLoading: false
  property string historyError: ""
  property bool historyQueued: false
  property string historyKey: ""

  // First weekday of a graph column, as Date.getDay() counts (0 is Sunday).
  readonly property int weekStart: Qt.locale().firstDayOfWeek % 7

  // Whole weeks: `graphWeeks` columns, the last one ending today.
  readonly property int historyDays: {
    var today = dateOfKey(todayKey)
    return (graphWeeks - 1) * 7 + (today.getDay() - weekStart + 7) % 7 + 1
  }

  readonly property var historyCommand: collectorCommand.concat(["--history-days=" + historyDays, "--commits=300"])

  onHistoryCommandChanged: if (root.panelOpen) historyDebounce.restart()

  function refreshHistory() {
    if (historyCollector.running) {
      historyQueued = true
      return
    }
    historyQueued = false
    historyLoading = true
    var command = historyCommand
    historyKey = JSON.stringify(command)
    historyCollector.command = command
    historyCollector.running = true
  }

  function applyHistory(text) {
    historyLoading = false
    if (historyKey !== JSON.stringify(historyCommand)) return

    var raw = String(text || "").trim()
    var data = null
    try { data = raw ? JSON.parse(raw) : null } catch (e) { data = null }

    if (!data || typeof data !== "object") {
      historyError = raw ? "Collector output was not valid JSON" : "Collector produced no output"
    } else if (data.error) {
      historyError = String(data.error)
    } else if (!data.history || typeof data.history !== "object") {
      historyError = "This collector has no history mode"
    } else {
      history = data.history
      historyError = ""
    }
  }

  // ----------------------------------------------------------------- popups
  //
  // Both popups use this widget as their popout owner. That makes the bar
  // close them when another bar popup opens, and gives `omarchy-shell shell
  // toggle <id>` the open/close/opened contract it looks for.

  property bool panelOpen: false
  property bool settingsOpen: false
  property bool popoutSwitchClosing: false
  readonly property bool opened: panelOpen || settingsOpen

  function open() { openPanel() }

  function close() {
    panelOpen = false
    settingsOpen = false
    // A history run queued behind one in flight is only ever for an open panel.
    historyQueued = false
  }

  function toggle() {
    if (opened) close()
    else openPanel()
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  // The other popup closes first: with one shared owner, a close landing
  // after the open would release the bar's claim on the popup still showing.
  function openPanel() {
    hideStripTooltip()
    settingsOpen = false
    panelOpen = true
    refreshHistory()
  }

  function openSettings() {
    hideStripTooltip()
    panelOpen = false
    settingsOpen = true
  }

  function togglePanel() {
    if (panelOpen) close()
    else openPanel()
  }

  function toggleSettings() {
    if (settingsOpen) close()
    else openSettings()
  }

  // Registered the way WidgetButton does it, so a click on this strip while
  // one of the popups is open reaches triggerPress() instead of only
  // dismissing the popup.
  property var registeredBar: null

  function syncClickRegistration() {
    if (registeredBar && typeof registeredBar.unregisterClickTarget === "function") registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && typeof registeredBar.registerClickTarget === "function") registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()

  // ---------------------------------------------------------------- watcher
  //
  // One inotifywait over every repository's logs/ directory: a commit appends
  // to logs/HEAD, so the box lights up a moment later instead of on the next
  // poll. A repository with no commits yet is watched through its git
  // directory until the first commit creates logs/. Fetched remote commits
  // still arrive with the poll.

  property string watchKey: ""
  property int watchFailures: 0
  property double watchStartedAt: 0
  property bool watchRestarting: false

  function syncWatcher() {
    var wanted = root.leader && root.watchPaths.length > 0
    var key = wanted ? root.watchPaths.join("\n") : ""
    if (watcher.running) {
      if (key !== root.watchKey) {
        // A deliberate restart for a new path list, not a failure.
        root.watchRestarting = true
        watcher.running = false
      }
      return
    }
    root.watchKey = key
    if (!wanted) return
    watcher.command = ["inotifywait", "-m", "-q", "-e", "create,close_write,moved_to", "--format", "%w%f"]
      .concat(root.watchPaths)
    root.watchStartedAt = Date.now()
    watcher.running = true
  }

  // ------------------------------------------------------------------ dates
  //
  // Boxes are keyed by local date rather than by position in the collector
  // output, so a stale result (say, just after midnight) never shifts a day
  // into the wrong box.

  readonly property string todayKey: Qt.formatDate(clock.date, "yyyy-MM-dd")

  onTodayKeyChanged: refreshDebounce.restart()

  readonly property var dayMap: {
    var map = {}
    for (var i = 0; i < days.length; i++) {
      if (days[i] && days[i].date) map[String(days[i].date)] = days[i]
    }
    return map
  }

  // Local midnight for a "yyyy-MM-dd" key; parsing the string directly would
  // give UTC midnight, the wrong day west of Greenwich.
  function dateOfKey(key) {
    var parts = String(key).split("-")
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  }

  // `new Date(y, m, d - n)` rolls months and DST over correctly.
  function dateForIndex(index) {
    var today = dateOfKey(todayKey)
    return new Date(today.getFullYear(), today.getMonth(), today.getDate() - (dayCount - 1 - index))
  }

  function dayForIndex(index) {
    return dayMap[Qt.formatDate(dateForIndex(index), "yyyy-MM-dd")] || null
  }

  // "Today", "Yesterday", a weekday within the week, a date beyond that.
  function dayLabel(key) {
    var date = dateOfKey(key)
    var ago = Math.round((dateOfKey(todayKey) - date) / 86400000)
    if (ago === 0) return "Today"
    if (ago === 1) return "Yesterday"
    return Qt.formatDate(date, ago < 7 ? "dddd" : "ddd d MMM")
  }

  // ----------------------------------------------------------------- colors

  readonly property color inkColor: root.bar ? root.bar.barForeground : Color.bar.text
  readonly property color surfaceColor: Color.background
  readonly property color baseColor: resolveColor(colorToken)
  readonly property color todayRingColor: Util.alpha(inkColor, 0.6)

  function resolveColor(token) {
    var value = String(token || "").trim()
    var role = value.toLowerCase()
    if (role === "" || role === "accent") return Color.accent
    if (role === "foreground" || role === "text") return inkColor
    if (role === "urgent" || role === "active") return Color.urgent
    if (role === "muted") return Color.muted
    if (/^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(value)) return value
    return Color.accent
  }

  function levelColor(level) {
    return Palette.levelColor(level, root.appearance, root.surfaceColor, root.inkColor, root.baseColor)
  }

  // ---------------------------------------------------------------- tooltip

  function formatCount(value) {
    return Number(Number(value) || 0).toLocaleString(Qt.locale(), "f", 0)
  }

  function dayTitle(index) {
    var label = Qt.formatDate(dateForIndex(index), "ddd d MMM")
    var fromEnd = dayCount - 1 - index
    if (fromEnd === 0) return "Today · " + label
    if (fromEnd === 1) return "Yesterday · " + label
    return label
  }

  function firstWarning() {
    if (!isList(warnings) || warnings.length === 0) return ""
    var text = String(warnings[0])
    if (text.length > 72) text = text.slice(0, 71) + "…"
    return "\uf071 " + text + (warnings.length > 1 ? " (+" + (warnings.length - 1) + " more)" : "")
  }

  function tooltipFor(index) {
    if (index === dayCount) return unpushedTooltip()

    var lines = [dayTitle(index)]
    var day = dayForIndex(index)

    if (!loaded) {
      lines.push(errorText !== "" ? errorText : "Counting commits…")
      return lines.join("\n")
    }

    var commits = day ? Number(day.commits) || 0 : 0
    if (commits === 0) {
      lines.push("No commits")
    } else {
      lines.push(formatCount(commits) + (commits === 1 ? " commit" : " commits")
        + "  +" + formatCount(day.added) + " −" + formatCount(day.deleted))
      // One repository per line keeps the tooltip narrow under a bar box.
      var repos = isList(day.repos) ? day.repos : []
      for (var i = 0; i < repos.length && i < 3; i++)
        lines.push(String(repos[i].name) + "  " + formatCount(repos[i].commits))
      if (repos.length > 3) lines.push("+" + (repos.length - 3) + " more")
    }

    if (metric === "lines") lines.push("Shaded by lines changed")
    if (errorText !== "") lines.push("Last refresh failed: " + errorText)
    else if (index === dayCount - 1 && firstWarning() !== "") lines.push(firstWarning())
    return lines.join("\n")
  }

  function unpushedTooltip() {
    if (!unpushed) return ""
    var n = Number(unpushed.commits) || 0
    var lines = [formatCount(n) + (n === 1 ? " commit" : " commits") + " not pushed"]
    var list = isList(unpushed.repos) ? unpushed.repos : []
    for (var i = 0; i < list.length && i < 4; i++)
      lines.push(String(list[i].name) + "  " + formatCount(list[i].commits))
    if (list.length > 4) lines.push("+" + (list.length - 4) + " more")
    return lines.join("\n")
  }

  function hoverTarget(index) {
    if (index === dayCount) return dotTarget
    return index >= 0 ? boxes.itemAt(index) : null
  }

  function refreshHoveredTooltip() {
    var target = hoverTarget(hoveredIndex)
    if (target && target.tooltipHovered && root.bar) root.bar.showTooltip(target, tooltipFor(hoveredIndex))
  }

  function hideStripTooltip() {
    var target = hoverTarget(hoveredIndex)
    if (target && root.bar) root.bar.hideTooltip(target)
  }

  // Which box (or the unpushed dot, as index dayCount) the pointer is over.
  // Gaps and edge padding snap to the nearest one, so the tooltip never
  // flickers while moving along the strip.
  function indexAt(x, y) {
    var point = root.mapToItem(strip, x, y)
    var along = vertical ? point.y : point.x
    var length = vertical ? strip.height : strip.width
    if (unpushedVisible && along > length + boxGap / 2) return dayCount
    var cell = boxSize + boxGap
    return Math.max(0, Math.min(dayCount - 1, Math.floor((along + boxGap / 2) / cell)))
  }

  // ------------------------------------------------------------------ input

  function triggerPress(button) {
    if (button === Qt.RightButton) {
      toggleSettings()
    } else if (button === Qt.MiddleButton) {
      pulse.restart()
      refresh()
    } else {
      togglePanel()
    }
  }

  // ----------------------------------------------------------------- layout

  readonly property int boxSize: Math.max(6, Math.round(barSize * 0.42))
  readonly property int boxGap: Math.max(2, Math.round(boxSize * 0.28))
  // Follows the theme's rounding (Hyprland decoration:rounding), capped so a
  // heavily rounded theme still draws squares rather than dots.
  readonly property int boxRadius: Math.min(Style.cornerRadius, Math.floor(boxSize / 4))
  readonly property int edgePadding: Style.space(8)
  readonly property bool unpushedVisible: showUnpushed && unpushed !== null && Number(unpushed.commits) > 0
  readonly property int dotSize: Math.max(3, Math.round(boxSize * 0.45))
  readonly property int dotExtent: unpushedVisible ? boxGap + dotSize : 0

  implicitWidth: vertical ? barSize : strip.implicitWidth + dotExtent + edgePadding * 2
  implicitHeight: vertical ? strip.implicitHeight + dotExtent + edgePadding * 2 : barSize

  Grid {
    id: strip
    x: root.vertical ? (root.width - width) / 2 : root.edgePadding
    y: root.vertical ? root.edgePadding : (root.height - height) / 2
    columns: root.vertical ? 1 : root.dayCount
    spacing: root.boxGap
    opacity: !root.loaded ? 0.35 : (root.errorText !== "" ? 0.55 : 1)

    Behavior on opacity {
      NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    Repeater {
      id: boxes
      model: root.dayCount

      Rectangle {
        id: box
        required property int index

        readonly property var day: root.dayForIndex(index)
        readonly property int level: day ? Math.max(0, Math.min(4, Math.round(Number(day.level) || 0))) : 0
        // Read by the bar's tooltip host (Bar.targetTooltipHovered).
        readonly property bool tooltipHovered: hoverArea.containsMouse && root.hoveredIndex === index

        width: root.boxSize
        height: root.boxSize
        radius: root.boxRadius
        color: root.levelColor(level)
        border.width: root.highlightToday && index === root.dayCount - 1 ? 1 : 0
        border.color: root.todayRingColor

        Behavior on color {
          ColorAnimation { duration: 240; easing.type: Easing.OutCubic }
        }

        onTooltipHoveredChanged: {
          if (!root.bar) return
          if (tooltipHovered) root.bar.showTooltip(box, root.tooltipFor(index))
          else root.bar.hideTooltip(box)
        }
      }
    }
  }

  // Commits that no remote has yet: a dot in the bar's attention color.
  Item {
    id: dotTarget
    readonly property bool tooltipHovered: hoverArea.containsMouse && root.hoveredIndex === root.dayCount

    visible: root.unpushedVisible
    x: root.vertical ? (root.width - width) / 2 : strip.x + strip.width + root.boxGap
    y: root.vertical ? strip.y + strip.height + root.boxGap : (root.height - height) / 2
    width: root.dotSize
    height: root.dotSize

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Color.bar.active
    }

    onTooltipHoveredChanged: {
      if (!root.bar) return
      if (tooltipHovered) root.bar.showTooltip(dotTarget, root.unpushedTooltip())
      else root.bar.hideTooltip(dotTarget)
    }
  }

  SequentialAnimation {
    id: pulse
    NumberAnimation { target: strip; property: "scale"; to: 0.88; duration: 90; easing.type: Easing.OutQuad }
    NumberAnimation { target: strip; property: "scale"; to: 1; duration: 180; easing.type: Easing.OutBack }
  }

  // Hover for the tooltips plus right/middle clicks. Left is left to the bar
  // (see the header comment).
  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor
    onEntered: root.hoveredIndex = root.indexAt(mouseX, mouseY)
    onPositionChanged: function(mouse) { root.hoveredIndex = root.indexAt(mouse.x, mouse.y) }
    onExited: root.hoveredIndex = -1
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
  }

  // ---------------------------------------------------------------- popups

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("HistoryPanel.qml")
    onLoaded: item.host = root
  }

  Loader {
    id: settingsLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("SettingsMenu.qml")
    onLoaded: item.host = root
  }

  // --------------------------------------------------------------- plumbing

  Process {
    id: collector
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("commit-tracker:", text.trim())
    }

    onRunningChanged: {
      if (running) return
      outputGrace.restart()
      if (root.refreshQueued) Qt.callLater(root.runCollector)
    }
  }

  // A process that never starts (no python3) produces no stdout at all, so
  // this catches runs that ended without handing us any output.
  Timer {
    id: outputGrace
    interval: 1500
    onTriggered: {
      if (!root.awaitingOutput || collector.running) return
      root.awaitingOutput = false
      root.errorText = "Could not run the collector (is python3 installed?)"
      root.refreshHoveredTooltip()
      root.publish()
    }
  }

  Process {
    id: historyCollector
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyHistory(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("commit-tracker:", text.trim())
    }

    onRunningChanged: {
      if (running) return
      historyGrace.restart()
      if (root.historyQueued && root.panelOpen) Qt.callLater(root.refreshHistory)
    }
  }

  Timer {
    id: historyGrace
    interval: 1500
    onTriggered: {
      if (!root.historyLoading || historyCollector.running) return
      root.historyLoading = false
      root.historyError = "Could not run the collector (is python3 installed?)"
    }
  }

  // New strip data or a settings change while the panel is open.
  Timer {
    id: historyDebounce
    interval: 400
    onTriggered: if (root.panelOpen) root.refreshHistory()
  }

  Process {
    id: watcher
    running: false

    // Only reflog writes (logs/HEAD) and a first commit creating logs/
    // matter; the index and lock files churn on every git status.
    stdout: SplitParser {
      onRead: function(line) { if (/\/(HEAD|logs)$/.test(line)) watchDebounce.restart() }
    }

    // Stopped for a new path list, or died (a watched directory vanished,
    // inotifywait missing). A quick death backs off up to ~2.5 minutes and
    // re-runs the collector first, so a stale path list heals itself instead
    // of spinning.
    onRunningChanged: {
      if (running) return
      if (root.watchRestarting) {
        root.watchRestarting = false
        root.watchFailures = 0
        watcherRestart.interval = 100
      } else {
        var quick = Date.now() - root.watchStartedAt < 10000
        root.watchFailures = quick ? Math.min(root.watchFailures + 1, 6) : 0
        watcherRestart.interval = root.watchFailures === 0 ? 100 : 2500 * Math.pow(2, root.watchFailures)
      }
      watcherRestart.restart()
    }
  }

  Timer {
    id: watcherRestart
    onTriggered: {
      if (root.watchFailures > 0 && root.leader) root.runCollector()
      else root.syncWatcher()
    }
  }

  // A commit, rebase or pull writes the reflog several times in a burst.
  Timer {
    id: watchDebounce
    interval: 1500
    onTriggered: root.runCollector()
  }

  // Settings arrive a tick after creation; the debounce folds that and any
  // burst of edits into a single run.
  Timer {
    id: refreshDebounce
    interval: 300
    onTriggered: root.pollTick()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.pollTick()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  // `omarchy-shell commit-tracker refresh` (e.g. from a git hook), plus the
  // two popups and the metric switch for keybinds.
  IpcHandler {
    target: "commit-tracker"

    function refresh(): void { root.refresh() }
    function togglePanel(): void { root.togglePanel() }
    function toggleSettings(): void { root.toggleSettings() }
    function toggleMetric(): void { root.setSetting("metric", root.metric === "lines" ? "commits" : "lines") }
  }

  Component.onCompleted: {
    syncClickRegistration()
    refreshDebounce.restart()
  }

  Component.onDestruction: {
    if (registeredBar && typeof registeredBar.unregisterClickTarget === "function") registeredBar.unregisterClickTarget(root)
    if (!root.leader) return
    // Hand the collector and the watcher to the next instance now rather than
    // on its next poll (a monitor was unplugged, the widget was removed).
    var items = peers()
    for (var i = 0; i < items.length; i++) {
      var peer = items[i]
      if (peer && peer !== root && typeof peer.pollTick === "function") Qt.callLater(peer.pollTick)
    }
  }
}
