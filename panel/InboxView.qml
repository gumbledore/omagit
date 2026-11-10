pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Format.js" as Format

// Inbox tab: review requests and my open PRs from panel.inbox. Renders panel
// state only; the fetch itself is Panel's Fetch all (omagit-autofetch --inbox).
//
// keys (Panel's PanelKeyCatcher delegates here; r / f / 1 / 2 / Tab are Panel's):
//   j k Up Down  move the highlight      Enter / Space  open the item in the browser
// A later ticket adds a section by appending to `sectionDefs` and, for row-scoped
// keys, handling them in handleKey() against `cursorItem`.
ColumnLayout {
  id: view

  required property var panel

  // ---- view interface (same shape as ReposView) ----
  readonly property bool textFocused: false

  function moveCursor(dy) {
    if (items.length === 0) return
    var i = Math.max(0, Math.min(items.length - 1, cursorIndex + dy))
    cursorUrl = items[i].url
    list.positionViewAtIndex(rowIndexOf(cursorUrl), ListView.Contain)
  }

  function activate() {
    var it = cursorItem
    if (it) panel.openUrl(it.url)
  }

  function handleKey(text) { return false }

  function handleEscape() { return false }

  function resetCursor() {
    cursorUrl = ""
    list.positionViewAtBeginning()
  }

  // ---- sections: fixed order; add new ones here ----
  readonly property var sectionDefs: [
    { name: "reviews", title: "Review requests" },
    { name: "prs", title: "My pull requests" }
  ]

  // Flat [header | item] model for the list, and the items alone for the cursor.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < sectionDefs.length; i++) {
      var sec = panel.inbox.sections[sectionDefs[i].name]
      if (!sec) continue
      out.push({ type: "header", title: sectionDefs[i].title, count: sec.items.length,
                 status: sec.status, message: sec.message, url: "" })
      for (var j = 0; j < sec.items.length; j++)
        out.push({ type: "item", item: sec.items[j], url: sec.items[j].url })
    }
    return out
  }
  readonly property var items: rows.filter(function(r) { return r.type === "item" }).map(function(r) { return r.item })

  property string cursorUrl: ""
  // Falls back to the first item when cursorUrl is gone after a refresh.
  readonly property int cursorIndex: {
    for (var i = 0; i < items.length; i++)
      if (items[i].url === cursorUrl) return i
    return items.length > 0 ? 0 : -1
  }
  readonly property var cursorItem: cursorIndex >= 0 ? items[cursorIndex] : null

  function rowIndexOf(url) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].type === "item" && rows[i].url === url) return i
    return 0
  }

  spacing: Style.space(6)

  Text {
    Layout.fillWidth: true
    text: view.panel.inbox.fetchedAt > 0 ? Format.inboxCaption(view.panel.inbox, view.panel.nowMs)
        : "Press f to fetch your GitHub inbox"
    color: view.panel.muted
    elide: Text.ElideRight
    font.family: view.panel.fontFamily
    font.pixelSize: Style.font.caption
  }

  ListView {
    id: list
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.minimumHeight: Math.min(contentHeight, Style.space(120))
    implicitHeight: contentHeight
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: Item {
      id: entry
      required property var modelData
      readonly property bool isHeader: modelData.type === "header"
      readonly property bool highlighted: !isHeader && modelData.url === view.cursorItem?.url
      readonly property var it: modelData.item
      width: list.width
      height: isHeader ? headerCol.implicitHeight + Style.space(6) : Style.space(26)

      // header: title + count, and the section's failure message
      ColumnLayout {
        id: headerCol
        visible: entry.isHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 0
        PanelSectionHeader {
          text: entry.isHeader ? entry.modelData.title + " (" + entry.modelData.count + ")" : ""
          foreground: view.panel.fg
          fontFamily: view.panel.fontFamily
        }
        Text {
          visible: entry.isHeader && entry.modelData.status === "ERR"
          Layout.fillWidth: true
          text: entry.isHeader ? "Failed to load: " + entry.modelData.message : ""
          color: view.panel.urgent
          wrapMode: Text.Wrap
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // item row
      Rectangle {
        visible: !entry.isHeader
        anchors.fill: parent
        radius: Style.cornerRadius
        color: entry.highlighted ? Util.alpha(view.panel.fg, 0.06) : "transparent"
      }
      Rectangle {  // keyboard cursor marker
        visible: entry.highlighted
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(2)
        width: Style.space(3)
        radius: width / 2
        color: view.panel.accent
      }
      RowLayout {
        visible: !entry.isHeader
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(6)
        opacity: entry.it && entry.it.draft ? 0.6 : 1

        Rectangle {  // CI rollup dot (PRs only)
          visible: entry.it !== undefined && entry.it.kind === "pr"
          implicitWidth: Style.space(8)
          implicitHeight: Style.space(8)
          radius: width / 2
          color: entry.it ? Format.ciColor(entry.it.ci, view.panel.accent, view.panel.urgent, view.panel.muted) : "transparent"
        }
        Text {
          Layout.fillWidth: true
          text: entry.it ? entry.it.title + (entry.it.draft ? " (draft)" : "") : ""
          color: entry.it && entry.it.draft ? view.panel.muted : view.panel.fg
          elide: Text.ElideRight
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: entry.it ? entry.it.repo + "#" + entry.it.number : ""
          color: view.panel.muted
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {  // tracked in a local repo
          visible: entry.it !== undefined && entry.it.localPath !== ""
          text: "\udb81\ude2c"
          color: view.panel.accent
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      MouseArea {
        visible: !entry.isHeader
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          view.cursorUrl = entry.modelData.url
          view.panel.openUrl(entry.modelData.url)
        }
      }
    }
  }
}
