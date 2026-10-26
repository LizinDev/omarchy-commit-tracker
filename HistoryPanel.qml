import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Palette.js" as Palette
import "History.js" as History

// The left-click panel: a GitHub-style contribution graph for the last few
// months, streaks and totals, a repository filter, and the commits
// themselves. A pushed commit opens on its forge (GitHub, GitLab, …); one that
// only exists locally cannot, so clicking it copies its hash instead.
//
// Widget.qml owns the data and the open state and hands itself over as
// `host`; this file only presents.
Item {
  id: root

  property var host: null

  readonly property QtObject bar: host ? host.bar : null
  readonly property bool open: host ? host.panelOpen : false
  readonly property var history: host ? host.history : null
  readonly property var days: history && History.isList(history.days) ? history.days : []
  readonly property var commits: history && History.isList(history.commits) ? history.commits : []
  readonly property var repos: history && History.isList(history.repos) ? history.repos : []
  readonly property var unpushed: host ? host.unpushed : null
  readonly property var warnings: host ? host.warnings : []

  // Filters. Cleared when the panel closes, so it always reopens on the
  // whole picture.
  property string repo: ""
  property string selectedDate: ""
  property string notice: ""
  property var hoveredCommit: null
  property string hoverRepo: ""

  onOpenChanged: {
    if (open) return
    repo = ""
    selectedDate = ""
    notice = ""
    hoveredCommit = null
    hoverRepo = ""
  }

  // The picker writes its own `value` when you choose from it, which would
  // cut a binding, so every other way of changing the filter (a repository
  // name in the list, clearing) pushes the value across instead.
  onRepoChanged: repoPicker.value = repo

  // A refresh can drop the chosen repository out of the window; a filter that
  // matches nothing would leave an empty panel behind a stale label.
  onReposChanged: {
    if (repo === "") return
    for (var i = 0; i < repos.length; i++) if (repos[i].name === repo) return
    repo = ""
  }

  // The list carries only the newest commits (--commits); the graph and the
  // totals still count all of them, so an older day can be active on the
  // graph yet have no rows here.
  readonly property bool listCapped: history && history.totals ? Number(history.totals.commits) > commits.length : false
  readonly property string oldestListed: commits.length > 0 ? String(commits[commits.length - 1].date) : ""

  readonly property int allCommits: history && history.totals ? Number(history.totals.commits) || 0 : 0

  readonly property var dayCounts: days.map(function(day) { return History.dayCommits(day, root.repo) })
  readonly property var streak: History.streaks(dayCounts)
  readonly property int totalCommits: dayCounts.reduce(function(sum, n) { return sum + n }, 0)
  readonly property int activeDays: dayCounts.filter(function(n) { return n > 0 }).length
  readonly property var rows: History.groupedRows(commits, repo, selectedDate)
  readonly property string githubId: History.githubHandle(host ? host.githubId : "", repos)

  readonly property color ink: Color.popups.text
  readonly property color muted: Util.alpha(ink, 0.6)
  readonly property color accent: Color.accent
  readonly property bool railOnRight: host && host.barSection === "right"
  readonly property int railWidth: Style.space(34)
  readonly property int railGap: Style.space(8)
  readonly property int railDividerGap: Style.space(4)
  // One left column for the graph's weekday labels, the scope row and the
  // commit timeline, so the three read as one surface.
  readonly property int gutter: Style.space(28)

  function count(n, word) {
    return n + " " + word + (n === 1 ? "" : "s")
  }

  function forgeHost(url) {
    var match = String(url || "").match(/^https?:\/\/([^\/]+)/)
    return match ? match[1] : "the web"
  }

  function activate(commit) {
    if (!commit) return
    if (commit.url) {
      Qt.openUrlExternally(commit.url)
      if (root.host) root.host.close()
    } else {
      Quickshell.execDetached(["wl-copy", String(commit.hash)])
      root.notice = "Copied " + commit.short + (commit.pushed ? " (its remote has no web page)" : " (not on any remote yet)")
    }
  }

  // The header's second line answers whatever the pointer is on (a day on
  // the graph, a commit in the list) and otherwise sums up the period.
  readonly property bool readoutLive: !!heatmap.hoveredDay || !!hoveredCommit
  readonly property string readout: {
    var day = heatmap.hoveredDay
    if (day) {
      var n = History.dayCommits(day, repo)
      var line = Qt.formatDate(heatmap.dateOf(day.date), "ddd d MMM") + " · " + (n === 0 ? "no commits" : count(n, "commit"))
      if (n > 0 && repo === "") line += " · +" + day.added + " \u2212" + day.deleted
      return line
    }
    var commit = hoveredCommit
    if (commit) {
      if (hoverRepo !== "" && hoverRepo !== repo) return "Show only " + hoverRepo
      if (commit.url) return commit.short + " · opens on " + forgeHost(commit.url)
      return commit.short + (commit.pushed ? " · its remote has no web page" : " · not pushed") + " · click to copy"
    }
    if (notice !== "") return notice
    if (!history) return root.host && root.host.historyError !== "" ? root.host.historyError : "Counting commits\u2026"
    if (root.host && root.host.historyError !== "") return "Last refresh failed: " + root.host.historyError
    var text = count(totalCommits, "commit") + " in the last " + History.periodLabel(root.host ? root.host.graphWeeks : 26)
    if (repo !== "") text += " in " + repo
    return text
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.host
    owner: root.host
    bar: root.bar
    open: root.open
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(460), heatmap.minimumWidth)
      + panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The repository search field owns the keys while its list is open.
      blocked: repoPicker.popupOpen
      onCloseRequested: if (root.host) root.host.close()
      onTextKey: function(t) {
        if (!root.host) return
        if (t === "r") root.host.refreshHistory()
        else if (t === "s") root.host.openSettings()
        else if (t === "a") {
          root.repo = ""
          root.selectedDate = ""
        }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: body.width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Item {
          id: body
          // The rail and graph retain their real size together. A capped popup
          // scrolls sideways instead of dropping the newest weeks.
          width: Math.max(scroller.width, root.railWidth + root.railDividerGap
            + Style.spacing.hairline + root.railGap + heatmap.minimumWidth)
          implicitHeight: mainColumn.implicitHeight

          // A persistent activity spine: the three numbers that used to take
          // a full row stay visible without stealing width from the logbook.
          Item {
            id: rail
            anchors.left: root.railOnRight ? undefined : parent.left
            anchors.right: root.railOnRight ? parent.right : undefined
            anchors.top: parent.top
            width: root.railWidth
            height: mainColumn.implicitHeight

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              width: Style.space(2)
              height: Style.space(28)
              color: root.accent
            }

            Rectangle {
              id: railMark
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(28)
              height: width
              radius: Style.cornerRadius
              color: Util.alpha(root.accent, 0.12)

              Text {
                anchors.centerIn: parent
                text: "\uf1da"
                textFormat: Text.PlainText
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }
            }

            Column {
              anchors.top: railMark.bottom
              anchors.topMargin: Style.space(12)
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              spacing: Style.space(12)

              Repeater {
                model: [
                  { value: root.streak.current, label: "NOW", accent: true },
                  { value: root.streak.longest, label: "BEST", accent: false },
                  { value: root.activeDays, label: "DAYS", accent: false }
                ]

                Column {
                  required property var modelData
                  width: root.railWidth
                  spacing: 0

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: String(modelData.value)
                    textFormat: Text.PlainText
                    color: modelData.accent ? root.accent : root.ink
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: modelData.label
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: Style.spaceReal(0.5)
                  }
                }
              }
            }
          }

          Rectangle {
            id: railDivider
            anchors.left: root.railOnRight ? undefined : rail.right
            anchors.right: root.railOnRight ? rail.left : undefined
            anchors.leftMargin: root.railOnRight ? 0 : root.railDividerGap
            anchors.rightMargin: root.railOnRight ? root.railDividerGap : 0
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.spacing.hairline
            color: Util.alpha(root.ink, 0.1)
          }

          Column {
            id: mainColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.railOnRight ? 0 : root.railWidth + root.railDividerGap
              + Style.spacing.hairline + root.railGap
            anchors.rightMargin: root.railOnRight ? root.railWidth + root.railDividerGap
              + Style.spacing.hairline + root.railGap : 0
            anchors.top: parent.top
            spacing: Style.space(8)

          // ---- Who and what: the GitHub id, a live readout, the actions.
          Item {
            id: header
            width: parent.width
            implicitHeight: Math.max(idMark.height, idText.implicitHeight)

            Rectangle {
              id: idMark
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(34)
              height: width
              radius: Style.cornerRadius
              color: Util.alpha(root.accent, 0.12)

              Text {
                anchors.centerIn: parent
                text: root.githubId ? "\uf09b" : "\ue702"
                textFormat: Text.PlainText
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }
            }

            Column {
              id: idText
              anchors.left: idMark.right
              anchors.leftMargin: Style.space(12)
              anchors.right: actions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.githubId ? "@" + root.githubId : "Commit activity"
                textFormat: Text.PlainText
                color: root.ink
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                width: parent.width
                text: root.readout
                textFormat: Text.PlainText
                color: root.readoutLive ? root.ink : root.muted
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              TintButton {
                glyph: "\uf021"
                tooltip: "Refresh (r)"
                spinning: !!root.host && root.host.historyLoading
                onClicked: if (root.host) root.host.refreshHistory()
              }

              TintButton {
                glyph: "\uf013"
                tooltip: "Settings (s)"
                onClicked: if (root.host) root.host.openSettings()
              }
            }
          }

          // ---- The graph spans the column; its weekday labels sit in the
          //      same gutter as the commit timeline below.
          Heatmap {
            id: heatmap
            width: parent.width
            fitWidth: width
            labelGutter: root.gutter
            days: root.days
            metric: root.host ? root.host.metric : "commits"
            repo: root.repo
            thresholds: root.host ? root.host.thresholds : [1, 2, 4, 8]
            appearance: root.host ? root.host.appearance : "theme"
            surface: Color.popups.background
            ink: root.ink
            base: root.host ? root.host.baseColor : Color.accent
            selectedDate: root.selectedDate
            pointedDate: root.hoveredCommit ? String(root.hoveredCommit.date) : ""
            weekStart: root.host ? root.host.weekStart : 0
            onDayClicked: function(date) { root.selectedDate = root.selectedDate === date ? "" : date }
          }

          // ---- Scope: which repository and which day the list shows, as
          //      plain-text controls, with the color key at the far end.
          Item {
            id: filterRow
            width: parent.width
            implicitHeight: Math.max(scopeRow.implicitHeight, legend.implicitHeight) + Style.space(4)

            // The native searchable picker does the choosing; only its boxed
            // trigger is hidden, behind the text link that opens it.
            SearchableDropdown {
              id: repoPicker
              anchors.left: parent.left
              anchors.leftMargin: root.gutter
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(220)
              rowHeight: filterRow.height
              opacity: 0
              visible: root.repos.length > 1
              showLabel: false
              value: root.repo
              foreground: root.ink
              placeholderText: "Search repositories"
              emptyText: "No repository matches"
              options: [{ value: "", label: "All repositories", description: root.count(root.allCommits, "commit") }]
                .concat(root.repos.map(function(r) {
                  return { value: r.name, label: r.name, description: root.count(r.commits, "commit") }
                }))
              onChanged: function(value) { root.repo = value }
            }

            Row {
              id: scopeRow
              anchors.left: parent.left
              anchors.leftMargin: root.gutter
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              FilterLink {
                visible: root.repos.length > 1
                text: "\uf126  " + (root.repo !== "" ? root.repo : "All repositories") + "  \uf107"
                active: root.repo !== ""
                tooltip: "Filter by repository"
                onClicked: repoPicker.toggle()
              }

              FilterLink {
                visible: root.repo !== ""
                text: "\uf00d"
                tooltip: "Show all repositories"
                onClicked: root.repo = ""
              }

              FilterLink {
                visible: root.selectedDate !== ""
                text: "\uf073  " + (root.host ? root.host.dayLabel(root.selectedDate) : root.selectedDate) + "  \uf00d"
                active: true
                tooltip: "Show every day"
                onClicked: root.selectedDate = ""
              }
            }

            Row {
              id: legend
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                rightPadding: Style.space(2)
                text: "Less"
                textFormat: Text.PlainText
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: 5

                Rectangle {
                  required property int index
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(9)
                  height: width
                  radius: heatmap.cellRadius
                  color: Palette.levelColor(index, heatmap.appearance, heatmap.surface, heatmap.ink, heatmap.base)
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(2)
                text: "More"
                textFormat: Text.PlainText
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Connections {
            target: root
            function onRepoChanged() {
              if (repoPicker.value !== root.repo) repoPicker.value = root.repo
            }
          }

          Text {
            visible: root.rows.length === 0
            width: parent.width
            leftPadding: root.gutter
            text: !root.history
              ? (root.host && root.host.historyError !== "" ? "Could not load the history." : "Counting commits…")
              : (root.listCapped && (root.selectedDate === "" || root.selectedDate < root.oldestListed)
                  ? "Only the latest " + root.commits.length + " commits are listed; these are older."
                  : (root.selectedDate !== "" ? "No commits that day." : "No commits in this period."))
            textFormat: Text.PlainText
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: list
            visible: root.rows.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(320))
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: rowItem
              required property var modelData
              readonly property bool isDay: modelData.kind === "day"
              readonly property var commit: isDay ? null : modelData.commit

              // A thin time spine turns the flat rows into a logbook. The
              // repository still doubles as a filter; the rest opens/copies.
              readonly property real timelineCenter: Math.round(root.gutter * 0.4)
              readonly property real contentStart: root.gutter
              readonly property real repoStart: contentStart + Style.spacing.sm
              readonly property real repoEnd: repoStart + Style.space(92)
              readonly property bool repoHot: rowMouse.containsMouse && rowMouse.mouseX >= repoStart && rowMouse.mouseX <= repoEnd

              function syncHover() {
                if (rowMouse.containsMouse) {
                  root.hoveredCommit = commit
                  root.hoverRepo = repoHot ? commit.repo : ""
                } else if (root.hoveredCommit === commit) {
                  root.hoveredCommit = null
                  root.hoverRepo = ""
                }
              }

              width: list.width
              height: isDay ? Style.space(20) : Style.space(22)

              Rectangle {
                x: rowItem.timelineCenter
                y: rowItem.isDay ? parent.height / 2 : 0
                width: Style.spacing.hairline
                height: rowItem.isDay ? parent.height / 2 : parent.height
                color: Util.alpha(root.ink, 0.14)
              }

              Rectangle {
                id: timelineDot
                anchors.verticalCenter: parent.verticalCenter
                x: rowItem.timelineCenter - width / 2 + Style.spacing.hairline / 2
                width: rowItem.isDay ? Style.space(7) : Style.space(5)
                height: width
                radius: width / 2
                color: rowItem.isDay ? root.accent
                  : (rowItem.commit && !rowItem.commit.pushed ? Color.bar.active : Util.alpha(root.ink, 0.35))
              }

              Text {
                id: dayText
                visible: rowItem.isDay
                anchors.left: parent.left
                anchors.leftMargin: rowItem.contentStart
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.isDay && root.host ? root.host.dayLabel(rowItem.modelData.date) : ""
                textFormat: Text.PlainText
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              CursorSurface {
                visible: !rowItem.isDay
                anchors.left: parent.left
                anchors.leftMargin: rowItem.contentStart
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                hasCursor: rowMouse.containsMouse
                foreground: root.ink

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.sm
                  anchors.rightMargin: Style.spacing.sm

                  Text {
                    id: repoText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(92)
                    text: rowItem.commit ? rowItem.commit.repo : ""
                    textFormat: Text.PlainText
                    color: rowItem.repoHot ? root.ink : root.muted
                    font.underline: rowItem.repoHot
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: metaText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.commit
                      ? "+" + rowItem.commit.added + " −" + rowItem.commit.deleted + "  "
                        + Qt.formatTime(new Date(rowItem.commit.ts * 1000), "HH:mm")
                      : ""
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.left: repoText.right
                    anchors.leftMargin: Style.spacing.sm
                    anchors.right: metaText.left
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.commit ? rowItem.commit.subject : ""
                    textFormat: Text.PlainText
                    color: root.ink
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                enabled: !rowItem.isDay
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: rowItem.syncHover()
                onPositionChanged: rowItem.syncHover()
                onClicked: {
                  if (rowItem.repoHot) root.repo = rowItem.commit.repo
                  else root.activate(rowItem.commit)
                }
              }
            }
          }

          // ---- Unpushed work and collector warnings.
          Text {
            visible: root.unpushed !== null && Number(root.unpushed.commits) > 0
            width: parent.width
            text: {
              if (!visible) return ""
              var parts = []
              var list = History.isList(root.unpushed.repos) ? root.unpushed.repos : []
              for (var i = 0; i < list.length && i < 3; i++) parts.push(list[i].name + " " + list[i].commits)
              return "● " + root.count(Number(root.unpushed.commits), "commit") + " not pushed · " + parts.join(" · ")
            }
            textFormat: Text.PlainText
            color: Color.bar.active
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: History.isList(root.warnings) && root.warnings.length > 0
            width: parent.width
            text: visible ? "\uf071 " + root.warnings[0] + (root.warnings.length > 1 ? " (+" + (root.warnings.length - 1) + " more)" : "") : ""
            textFormat: Text.PlainText
            color: root.muted
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          }
        }
      }
    }
  }

  // A tinted square, as in Omarchy's newer panels: accent at 12%, 30% under
  // the pointer. Spins its glyph while `spinning`.
  component TintButton: Rectangle {
    id: tint
    signal clicked()
    property string glyph: ""
    property string tooltip: ""
    property bool spinning: false

    implicitWidth: Style.space(30)
    implicitHeight: implicitWidth
    radius: Style.cornerRadius
    color: Util.alpha(root.accent, tintMouse.containsMouse ? 0.3 : 0.12)

    Behavior on color { ColorAnimation { duration: 140 } }

    Text {
      id: tintGlyph
      anchors.centerIn: parent
      text: tint.glyph
      textFormat: Text.PlainText
      color: root.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.title

      RotationAnimation on rotation {
        running: tint.spinning
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
        onRunningChanged: if (!running) tintGlyph.rotation = 0
      }
    }

    MouseArea {
      id: tintMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tint.clicked()
    }

    PanelToolTip {
      visible: tintMouse.containsMouse
      text: tint.tooltip
    }
  }

  // A plain-text control: muted until hovered, accent while it narrows the
  // view. Stands in for boxed buttons, which would pile up in one row.
  component FilterLink: Text {
    id: link
    signal clicked()
    property bool active: false
    property string tooltip: ""

    textFormat: Text.PlainText
    color: active ? root.accent : (linkMouse.containsMouse ? root.ink : root.muted)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: active

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }

    PanelToolTip {
      visible: linkMouse.containsMouse && link.tooltip !== ""
      text: link.tooltip
    }
  }
}
