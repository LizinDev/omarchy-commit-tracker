import QtQuick
import qs.Commons
import qs.Ui
import "Palette.js" as Palette

// The right-click menu: everything the strip and the panel let you change
// without editing shell.json. Each choice goes straight back to this widget's
// entry through Widget.setSetting(), so the strip reacts as you click.
Item {
  id: root

  property var host: null

  readonly property QtObject bar: host ? host.bar : null
  readonly property bool open: host ? host.settingsOpen : false
  readonly property color ink: Color.popups.text
  readonly property color muted: Util.alpha(ink, 0.6)

  function set(key, value) {
    if (root.host) root.host.setSetting(key, value)
  }

  component MenuLabel: Text {
    textFormat: Text.PlainText
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  // Label on the left, one-of-N chips on the right.
  component ChoiceRow: Item {
    id: choice
    property string label: ""
    property var options: []
    property string value: ""
    signal chosen(string value)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(choiceLabel.implicitHeight, choiceGroup.implicitHeight)

    MenuLabel {
      id: choiceLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: choice.label
    }

    ButtonGroup {
      id: choiceGroup
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      options: choice.options
      value: choice.value
      focusable: false
      spacing: Style.spacing.xs
      foreground: Color.popups.text
      fontSize: Style.font.bodySmall
      onChanged: function(value) { choice.chosen(value) }
    }
  }

  // Label on the left, switch on the right; the whole row is clickable.
  component SwitchRow: Item {
    id: row
    property string label: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)

    MenuLabel {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      interactive: false
      hasCursor: rowMouse.containsMouse
      foreground: Color.popups.text
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.toggled()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.host
    owner: root.host
    bar: root.bar
    open: root.open
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(menu.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: if (root.host) root.host.close()

      Column {
        id: menu
        width: parent.width
        spacing: Style.spacing.md

        Item {
          width: parent.width
          implicitHeight: Math.max(title.implicitHeight, historyButton.implicitHeight)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Commit Tracker"
            textFormat: Text.PlainText
            color: root.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          PanelActionButton {
            id: historyButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf1da"
            tooltipText: "Open the history panel"
            foreground: root.ink
            onClicked: if (root.host) root.host.openPanel()
          }
        }

        PanelSectionHeader { text: "Bar"; foreground: root.ink }

        ChoiceRow {
          label: "Days shown"
          options: ["3", "5", "7", "10", "14"]
          value: String(root.host ? root.host.dayCount : 5)
          onChosen: function(value) { root.set("days", Number(value)) }
        }

        ChoiceRow {
          label: "Shade by"
          options: [{ value: "commits", label: "Commits" }, { value: "lines", label: "Lines" }]
          value: root.host ? root.host.metric : "commits"
          onChosen: function(value) { root.set("metric", value) }
        }

        SwitchRow {
          label: "Outline today"
          checked: root.host ? root.host.highlightToday : true
          onToggled: root.set("highlightToday", !checked)
        }

        SwitchRow {
          label: "Dot for unpushed commits"
          checked: root.host ? root.host.showUnpushed : true
          onToggled: root.set("showUnpushed", !checked)
        }

        PanelSeparator { foreground: root.ink }
        PanelSectionHeader { text: "Colors"; foreground: root.ink }

        ChoiceRow {
          label: "Style"
          options: [{ value: "theme", label: "Theme" }, { value: "github", label: "GitHub" }]
          value: root.host ? root.host.appearance : "theme"
          onChosen: function(value) { root.set("appearance", value) }
        }

        // What the chosen style looks like on this theme, level 0 to 4.
        Item {
          width: parent.width
          implicitHeight: preview.implicitHeight

          Row {
            id: preview
            anchors.right: parent.right
            spacing: Style.space(3)

            Repeater {
              model: 5

              Rectangle {
                required property int index
                width: Style.space(14)
                height: width
                radius: Math.min(Style.cornerRadius, Math.floor(width / 4))
                color: root.host
                  ? Palette.levelColor(index, root.host.appearance, Color.popups.background, root.ink, root.host.baseColor)
                  : "transparent"
              }
            }
          }
        }

        PanelSeparator { foreground: root.ink }
        PanelSectionHeader { text: "History panel"; foreground: root.ink }

        ChoiceRow {
          label: "Graph"
          options: [{ value: "13", label: "3 months" }, { value: "26", label: "6 months" }, { value: "52", label: "1 year" }]
          value: String(root.host ? root.host.graphWeeks : 26)
          onChosen: function(value) { root.set("graphWeeks", Number(value)) }
        }

        SwitchRow {
          label: "Count merge commits"
          checked: root.host ? root.host.includeMerges : false
          onToggled: root.set("includeMerges", !checked)
        }

        PanelSeparator { foreground: root.ink }

        Item {
          width: parent.width
          implicitHeight: Math.max(refreshButton.implicitHeight, hint.implicitHeight)

          Button {
            id: refreshButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Refresh now"
            iconText: "\uf021"
            bordered: true
            foreground: root.ink
            fontSize: Style.font.bodySmall
            onClicked: if (root.host) root.host.refresh()
          }

          Text {
            id: hint
            anchors.right: parent.right
            anchors.left: refreshButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: "More options in shell.json"
            textFormat: Text.PlainText
            color: root.muted
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
