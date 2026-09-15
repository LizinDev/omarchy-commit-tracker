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

  readonly property int allCommits: history && history.totals ? Number(history.totals.commits) || 0 : 0

  readonly property var dayCounts: days.map(function(day) { return History.dayCommits(day, root.repo) })
  readonly property var streak: History.streaks(dayCounts)
  readonly property int totalCommits: dayCounts.reduce(function(sum, n) { return sum + n }, 0)
  readonly property int activeDays: dayCounts.filter(function(n) { return n > 0 }).length
  readonly property var rows: History.groupedRows(commits, repo, selectedDate)

  readonly property color ink: Color.popups.text
  readonly property color muted: Util.alpha(ink, 0.6)

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

  readonly property string summary: {
    if (!history) return root.host && root.host.historyError !== "" ? root.host.historyError : "Counting commits…"
    var text = count(totalCommits, "commit") + " in the last " + History.periodLabel(root.host ? root.host.graphWeeks : 26)
    if (repo !== "") text += " in " + repo
    if (root.host && root.host.historyLoading) text += " · refreshing"
    return text
  }

  // One line under the graph that answers whatever the pointer is on.
  readonly property string status: {
    var day = heatmap.hoveredDay
    if (day) {
      var n = History.dayCommits(day, repo)
      var line = Qt.formatDate(heatmap.dateOf(day.date), "ddd d MMM yyyy") + " · " + (n === 0 ? "no commits" : count(n, "commit"))
      if (n > 0 && repo === "") line += "  +" + day.added + " −" + day.deleted
      return line
    }
    var commit = hoveredCommit
    if (commit) {
      if (hoverRepo !== "" && hoverRepo !== repo) return "Show only " + hoverRepo
      if (commit.url) return commit.short + " · opens on " + forgeHost(commit.url)
      return commit.short + (commit.pushed ? " · its remote has no web page" : " · not pushed") + ", click to copy the hash"
    }
    if (notice !== "") return notice
    if (root.host && root.host.historyError !== "") return "Last refresh failed: " + root.host.historyError
    return "Click a day to filter"
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.host
    owner: root.host
    bar: root.bar
    open: root.open
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(460), heatmap.implicitWidth)
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

        Column {
          id: body
          // Never narrower than the graph: a capped popup scrolls sideways
          // rather than dropping the newest weeks off the edge.
          width: Math.max(scroller.width, heatmap.implicitWidth)
          spacing: Style.space(10)

          // ---- Title, summary, actions.
          Item {
            width: parent.width
            implicitHeight: Math.max(titleColumn.implicitHeight, actions.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Text {
                text: "Commit activity"
                textFormat: Text.PlainText
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                text: root.summary
                textFormat: Text.PlainText
                color: root.muted
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

              PanelActionButton {
                iconText: "\uf021"
                tooltipText: "Refresh (r)"
                foreground: root.ink
                onClicked: if (root.host) root.host.refreshHistory()
              }

              PanelActionButton {
                iconText: "\uf013"
                tooltipText: "Settings (s)"
                foreground: root.ink
                onClicked: if (root.host) root.host.openSettings()
              }
            }
          }

          // ---- Streaks and totals on the left, the repository picker on the
          //      right: one searchable list instead of a chip per repository,
          //      so a hundred repositories cost no more room than five.
          Item {
            width: parent.width
            implicitHeight: Math.max(stats.implicitHeight, repoPicker.implicitHeight)

            Row {
              id: stats
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(20)

              Repeater {
                model: [
                  { value: root.streak.current, label: "current streak", days: true },
                  { value: root.streak.longest, label: "longest streak", days: true },
                  { value: root.activeDays, label: "active days", days: false }
                ]

                Column {
                  required property var modelData
                  spacing: 0

                  Text {
                    text: modelData.days ? root.count(modelData.value, "day") : String(modelData.value)
                    textFormat: Text.PlainText
                    color: root.ink
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                  }

                  Text {
                    text: modelData.label
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            SearchableDropdown {
              id: repoPicker
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(Style.space(130), Math.min(Style.space(200), parent.width - stats.implicitWidth - Style.spacing.lg))
              visible: root.repos.length > 1
              showLabel: false
              foreground: root.ink
              placeholderText: "Search repositories"
              emptyText: "No repository matches"
              options: [{ value: "", label: "All repositories", description: root.count(root.allCommits, "commit") }]
                .concat(root.repos.map(function(r) {
                  return { value: r.name, label: r.name, description: root.count(r.commits, "commit") }
                }))
              onChanged: function(value) { root.repo = value }
            }
          }

          Heatmap {
            id: heatmap
            days: root.days
            metric: root.host ? root.host.metric : "commits"
            repo: root.repo
            thresholds: root.host ? root.host.thresholds : [1, 2, 4, 8]
            appearance: root.host ? root.host.appearance : "theme"
            ink: root.ink
            base: root.host ? root.host.baseColor : Color.accent
            selectedDate: root.selectedDate
            weekStart: root.host ? root.host.weekStart : 0
            onDayClicked: function(date) { root.selectedDate = root.selectedDate === date ? "" : date }
          }

          // ---- What the pointer is on, and the color key.
          Item {
            width: parent.width
            implicitHeight: Math.max(statusLine.implicitHeight, legend.implicitHeight)

            Text {
              id: statusLine
              anchors.left: parent.left
              anchors.right: legend.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: root.status
              textFormat: Text.PlainText
              color: root.muted
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              id: legend
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                anchors.verticalCenter: parent.verticalCenter
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
                  width: heatmap.cellSize
                  height: heatmap.cellSize
                  radius: Math.min(Style.cornerRadius, Math.floor(heatmap.cellSize / 4))
                  color: Palette.levelColor(index, heatmap.appearance, heatmap.surface, heatmap.ink, heatmap.base)
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "More"
                textFormat: Text.PlainText
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { foreground: root.ink }

          // ---- Commits.
          Item {
            width: parent.width
            implicitHeight: commitsHeader.implicitHeight

            PanelSectionHeader {
              id: commitsHeader
              foreground: root.ink
              text: root.selectedDate !== "" && root.host ? root.host.dayLabel(root.selectedDate) : "Commits"
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.repo !== "" || root.selectedDate !== ""
              text: "Clear filter \uf00d"
              textFormat: Text.PlainText
              color: clearMouse.containsMouse ? root.ink : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.repo = ""
                  root.selectedDate = ""
                }
              }
            }
          }

          Text {
            visible: root.rows.length === 0
            width: parent.width
            text: !root.history
              ? (root.host && root.host.historyError !== "" ? "Could not load the history." : "Counting commits…")
              : (root.selectedDate !== "" ? "No commits that day." : "No commits in this period.")
            textFormat: Text.PlainText
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: list
            visible: root.rows.length > 0
            width: parent.width
            height: Math.min(contentHeight, Style.space(280))
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: rowItem
              required property var modelData
              readonly property bool isDay: modelData.kind === "day"
              readonly property var commit: isDay ? null : modelData.commit

              // The repository name doubles as a filter: click it to show
              // only that repository; the rest of the row opens the commit.
              readonly property real repoStart: Style.spacing.sm + Style.space(6) + Style.spacing.sm
              readonly property real repoEnd: repoStart + Style.space(104)
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
              height: isDay ? dayText.implicitHeight + Style.spacing.sm : Style.space(26)

              Text {
                id: dayText
                visible: rowItem.isDay
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.spacing.xxs
                text: rowItem.isDay && root.host ? root.host.dayLabel(rowItem.modelData.date) : ""
                textFormat: Text.PlainText
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              CursorSurface {
                visible: !rowItem.isDay
                anchors.fill: parent
                hasCursor: rowMouse.containsMouse
                foreground: root.ink

                Item {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.sm
                  anchors.rightMargin: Style.spacing.sm

                  // Only-local commits carry the same dot as the bar strip.
                  Rectangle {
                    id: localDot
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: rowItem.commit && !rowItem.commit.pushed ? Color.bar.active : "transparent"
                  }

                  Text {
                    id: repoText
                    anchors.left: localDot.right
                    anchors.leftMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(104)
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
                    font.pixelSize: Style.font.body
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
