import QtQuick
import qs.Commons
import "Palette.js" as Palette
import "History.js" as History

// GitHub-style contribution graph: one column per week, one row per weekday,
// oldest week on the left and today in the last column. One MouseArea serves
// the whole grid, so a year of cells costs no more input handling than a week.
Item {
  id: root

  // Collector history days, oldest to newest, ending today.
  property var days: []
  property string metric: "commits"
  // "" shades by every repository; a name shades by that repository only.
  property string repo: ""
  property var thresholds: [1, 2, 4, 8]
  property string appearance: "theme"
  property color surface: Color.popups.background
  property color ink: Color.popups.text
  property color base: Color.accent
  property string selectedDate: ""
  // First weekday of a column, as Date.getDay() counts: 0 is Sunday.
  property int weekStart: 0

  property int cellSize: Style.space(11)
  property int gap: Style.space(3)
  readonly property int pitch: cellSize + gap
  readonly property int labelGutter: Style.space(30)
  readonly property int monthRowHeight: Style.font.caption + Style.space(6)

  property int hoveredCell: -1
  readonly property var hoveredDay: dayAtCell(hoveredCell)

  signal dayClicked(string date)

  function dateOf(key) {
    var parts = String(key).split("-")
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
  }

  // Empty cells before the first day, so every column starts on weekStart.
  readonly property int leading: days.length > 0 ? (dateOf(days[0].date).getDay() - weekStart + 7) % 7 : 0
  readonly property int weeks: Math.max(1, Math.ceil((leading + days.length) / 7))

  function dayAtCell(cell) {
    var i = cell - leading
    return cell >= 0 && i >= 0 && i < days.length ? days[i] : null
  }

  function cellAt(x, y) {
    var col = Math.floor(x / pitch)
    var row = Math.floor(y / pitch)
    if (col < 0 || col >= weeks || row < 0 || row > 6) return -1
    return col * 7 + row
  }

  function levelOf(day) {
    if (!day) return 0
    if (repo === "") return Palette.clampLevel(day.level)
    return Palette.levelFor(History.dayValue(day, metric, repo), thresholds)
  }

  // A month is labelled over the first column that reaches it, and dropped
  // when the next label would crowd it (a sliver of a month at the left edge).
  readonly property var monthLabels: {
    var names = Qt.locale("en_US")
    var changes = []
    var lastMonth = -1
    for (var c = 0; c < weeks; c++) {
      var i = Math.max(0, c * 7 - leading)
      if (i >= days.length) break
      var month = dateOf(days[i].date).getMonth()
      if (month !== lastMonth) changes.push({ col: c, text: names.monthName(month, Locale.ShortFormat) })
      lastMonth = month
    }
    var out = []
    for (var k = 0; k < changes.length; k++)
      if (k === changes.length - 1 || changes[k + 1].col - changes[k].col >= 3) out.push(changes[k])
    return out
  }

  implicitWidth: labelGutter + weeks * pitch - gap
  implicitHeight: monthRowHeight + 7 * pitch - gap

  Repeater {
    model: root.monthLabels

    Text {
      required property var modelData
      x: root.labelGutter + modelData.col * root.pitch
      y: 0
      text: modelData.text
      textFormat: Text.PlainText
      color: Util.alpha(root.ink, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // Mon, Wed and Fri, wherever they fall for this week start.
  Repeater {
    model: 7

    Text {
      required property int index
      readonly property int weekday: (root.weekStart + index) % 7
      visible: weekday === 1 || weekday === 3 || weekday === 5
      x: 0
      y: root.monthRowHeight + index * root.pitch + (root.cellSize - height) / 2
      text: Qt.locale("en_US").dayName(weekday, Locale.ShortFormat)
      textFormat: Text.PlainText
      color: Util.alpha(root.ink, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Repeater {
    model: root.weeks * 7

    Rectangle {
      required property int index
      readonly property var day: root.dayAtCell(index)
      readonly property bool marked: day !== null && (day.date === root.selectedDate || index === root.hoveredCell)

      visible: day !== null
      x: root.labelGutter + Math.floor(index / 7) * root.pitch
      y: root.monthRowHeight + (index % 7) * root.pitch
      width: root.cellSize
      height: root.cellSize
      radius: Math.min(Style.cornerRadius, Math.floor(root.cellSize / 4))
      color: Palette.levelColor(root.levelOf(day), root.appearance, root.surface, root.ink, root.base)
      border.width: marked ? 1 : 0
      border.color: Util.alpha(root.ink, 0.85)
    }
  }

  MouseArea {
    x: root.labelGutter
    y: root.monthRowHeight
    width: root.weeks * root.pitch
    height: 7 * root.pitch
    hoverEnabled: true
    cursorShape: root.hoveredDay ? Qt.PointingHandCursor : Qt.ArrowCursor
    onPositionChanged: function(mouse) { root.hoveredCell = root.cellAt(mouse.x, mouse.y) }
    onExited: root.hoveredCell = -1
    onClicked: function(mouse) {
      var day = root.dayAtCell(root.cellAt(mouse.x, mouse.y))
      if (day) root.dayClicked(day.date)
    }
  }
}
