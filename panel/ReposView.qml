pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Repos tab content: add/tracking form, empty state, and the repo list.
// Renders panel state and dispatches to panel functions; owns no processes.
ColumnLayout {
  id: view

  required property var panel
  property alias addFormVisible: addForm.visible

  spacing: Style.space(6)

  ColumnLayout {
    id: addForm
    visible: false
    Layout.fillWidth: true
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      TextField {
        id: addField
        Layout.fillWidth: true
        placeholderText: "~/projects or ~/Work/foo"
        font.family: view.panel.fontFamily
        onAccepted: { view.panel.trackPath("root", text); text = "" }
      }
      Button { text: "Add root"; onClicked: { view.panel.trackPath("root", addField.text); addField.text = "" } }
      Button { text: "Add repo"; onClicked: { view.panel.trackPath("repo", addField.text); addField.text = "" } }
    }
    Repeater {
      model: view.panel.tracking.roots || []
      delegate: RowLayout {
        required property string modelData
        Layout.fillWidth: true
        spacing: Style.space(6)
        Text {
          Layout.fillWidth: true
          text: "root  " + modelData
          color: view.panel.muted
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
        PanelActionButton {
          iconText: "\udb80\udd56"
          size: Style.space(18)
          tooltipText: "Stop tracking this root and everything under it"
          onClicked: view.panel.untrackRoot(modelData)
        }
      }
    }
    Text {
      visible: view.panel.headerMessage !== ""
      Layout.fillWidth: true
      text: view.panel.headerMessage + "  ✕"
      color: view.panel.urgent
      wrapMode: Text.Wrap
      font.family: view.panel.fontFamily
      font.pixelSize: Style.font.caption
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: view.panel.headerMessage = "" }
    }
  }

  PanelSeparator { Layout.fillWidth: true }

  // ------------------------------------------------------------- repo list
  Text {
    visible: view.panel.repos.length === 0
    Layout.fillWidth: true
    Layout.topMargin: Style.space(8)
    Layout.bottomMargin: Style.space(8)
    text: view.panel.discovering ? "Scanning…" : "No repos tracked yet. Use \udb81\udc15 to add a scan root or a single repo."
    color: view.panel.muted
    wrapMode: Text.Wrap
    font.family: view.panel.fontFamily
    font.pixelSize: Style.font.body
  }

  ListView {
    id: list
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.minimumHeight: Math.min(contentHeight, Style.space(120))
    implicitHeight: contentHeight
    clip: true
    spacing: Style.space(2)
    cacheBuffer: 10000
    boundsBehavior: Flickable.StopAtBounds
    model: view.panel.repos

    delegate: RepoRow {
      required property var modelData
      width: list.width
      panel: view.panel
      repo: modelData
    }
  }
}
