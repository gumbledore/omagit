pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Format.js" as Format

// Inbox tab: notifications, review requests, my PRs and issues, and Actions runs from panel.inbox. Renders panel
// state only; the fetch itself is Panel's Fetch all (omagit-autofetch --inbox).
//
// keys (Panel's PanelKeyCatcher delegates here; r / f / 1 / 2 / Tab are Panel's):
//   j k Up Down  move the highlight      Enter / Space  open the item in the browser
//   m  mark the highlighted notification read (Enter on a notification opens + marks it)
//   PR / review request in a tracked repo:  c  checkout locally   o  show the repo in Repos
// A later ticket adds a section by appending to `sectionDefs` and, for row-scoped
// keys, handling them in handleKey() against `cursorItem` (return true when handled).
ColumnLayout {
  id: view

  required property var panel

  // ---- view interface (same shape as ReposView) ----
  readonly property bool textFocused: false

  function moveCursor(dy) {
    if (items.length === 0) return
    var i = Math.max(0, Math.min(items.length - 1, cursorIndex + dy))
    cursorKey = itemKey(items[i])
    list.positionViewAtIndex(rowIndexOf(cursorKey), ListView.Contain)
  }

  // Unique per item: notifications can share a URL with other sections' items.
  function itemKey(it) { return it.kind + ":" + (it.id || it.url) }

  // Open in the browser; a notification is also marked read.
  function openItem(it) {
    panel.openUrl(it.url)
    if (it.kind === "notification") panel.markNotificationRead(it.id)
  }

  function activate() {
    var it = cursorItem
    if (it) openItem(it)
  }

  // PRs and review requests whose repo is tracked locally.
  function hasLocalPr(it) { return !!it && (it.kind === "pr" || it.kind === "review") && it.localPath !== "" }

  property string checkoutKey: ""   // item whose checkout was last requested

  function checkout(it) {
    if (panel.checkoutPr(it.localPath, it.number)) checkoutKey = itemKey(it)
  }

  function handleKey(text) {
    if (text === "c" && hasLocalPr(cursorItem)) { checkout(cursorItem); return true }
    if (text === "o" && hasLocalPr(cursorItem)) { panel.jumpToRepo(cursorItem.localPath); return true }
    if (text === "m" && cursorItem && cursorItem.kind === "notification") {
      panel.markNotificationRead(cursorItem.id)
      return true
    }
    return false
  }

  function handleEscape() { return false }

  function resetCursor() {
    cursorKey = ""
    list.positionViewAtBeginning()
  }

  // ---- sections: fixed order; add new ones here ----
  readonly property var sectionDefs: [
    { name: "notifications", title: "Notifications" },
    { name: "reviews", title: "Review requests" },
    { name: "prs", title: "My pull requests" },
    { name: "issues", title: "Assigned issues" },
    { name: "actions", title: "Actions" }
  ]

  // Flat [header | item] model for the list, and the items alone for the cursor.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < sectionDefs.length; i++) {
      var sec = panel.inbox.sections[sectionDefs[i].name]
      if (!sec) continue
      out.push({ type: "header", name: sectionDefs[i].name, title: sectionDefs[i].title, count: sec.items.length,
                 status: sec.status, message: sec.message, key: "" })
      for (var j = 0; j < sec.items.length; j++)
        out.push({ type: "item", item: sec.items[j], key: itemKey(sec.items[j]) })
    }
    return out
  }
  readonly property var items: rows.filter(function(r) { return r.type === "item" }).map(function(r) { return r.item })

  property string cursorKey: ""
  // Falls back to the first item when cursorKey is gone after a refresh.
  readonly property int cursorIndex: {
    for (var i = 0; i < items.length; i++)
      if (itemKey(items[i]) === cursorKey) return i
    return items.length > 0 ? 0 : -1
  }
  readonly property var cursorItem: cursorIndex >= 0 ? items[cursorIndex] : null

  function rowIndexOf(key) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].type === "item" && rows[i].key === key) return i
    return 0
  }

  // "Mark all read": arms on the first click, fires on the second. Lapses after 6 s,
  // when the panel closes, and when the notifications list changes.
  property bool markAllArmed: false
  readonly property string notificationIds: (panel.inbox.sections.notifications
    ? panel.inbox.sections.notifications.items : []).map(function(n) { return n.id }).join(",")
  onNotificationIdsChanged: markAllArmed = false
  onMarkAllArmedChanged: if (markAllArmed) lapseTimer.restart(); else lapseTimer.stop()
  Timer {
    id: lapseTimer
    interval: 6000
    onTriggered: view.markAllArmed = false
  }
  Connections {
    target: view.panel
    function onOpenedChanged() { if (!view.panel.opened) view.markAllArmed = false }
  }

  function markAllClicked() {
    if (!markAllArmed) { markAllArmed = true; return }
    markAllArmed = false
    panel.markAllNotificationsRead()
  }

  spacing: Style.space(6)

  Text {  // last mark-read / mark-all failure; click to dismiss
    visible: view.panel.inboxMessage !== ""
    Layout.fillWidth: true
    text: view.panel.inboxMessage
    color: view.panel.urgent
    wrapMode: Text.Wrap
    font.family: view.panel.fontFamily
    font.pixelSize: Style.font.caption
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: view.panel.inboxMessage = ""
    }
  }

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
      readonly property bool highlighted: !isHeader && modelData.key === (view.cursorItem ? view.itemKey(view.cursorItem) : "")
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
        RowLayout {
          Layout.fillWidth: true
          PanelSectionHeader {
            Layout.fillWidth: true
            text: entry.isHeader ? entry.modelData.title + " (" + entry.modelData.count + ")" : ""
            foreground: view.panel.fg
            fontFamily: view.panel.fontFamily
          }
          Button {
            visible: entry.isHeader && entry.modelData.name === "notifications" && entry.modelData.count > 0
            text: view.markAllArmed ? "Confirm mark all read" : "Mark all read"
            foreground: view.markAllArmed ? view.panel.urgent : view.panel.muted
            fontSize: Style.font.caption
            tooltipText: "Marks only the notifications shown here as read"
            onClicked: view.markAllClicked()
          }
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

        Rectangle {  // CI rollup dot (PRs) / run state dot
          visible: entry.it !== undefined && (entry.it.kind === "pr" || entry.it.kind === "run")
          implicitWidth: Style.space(8)
          implicitHeight: Style.space(8)
          radius: width / 2
          color: !entry.it ? "transparent"
               : entry.it.kind === "run" ? Format.ciColor(entry.it.state === "failed" ? "failing" : "pending", view.panel.accent, view.panel.urgent, view.panel.muted)
               : Format.ciColor(entry.it.ci, view.panel.accent, view.panel.urgent, view.panel.muted)
        }
        Text {
          Layout.fillWidth: true
          text: !entry.it ? ""
              : entry.it.kind === "run" ? entry.it.workflow + " \u2014 " + entry.it.title
              : entry.it.title + (entry.it.draft ? " (draft)" : "")
          color: entry.it && entry.it.draft ? view.panel.muted : view.panel.fg
          elide: Text.ElideRight
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: !entry.it ? ""
              : entry.it.kind === "notification" ? entry.it.repo + " \u00b7 " + entry.it.reason
              : entry.it.kind === "run" ? entry.it.repo + " \u00b7 " + entry.it.branch
              : entry.it.repo + "#" + entry.it.number
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
        Text {  // checkout status for the PR last checked out
          readonly property var st: entry.it && view.checkoutKey === entry.modelData.key
            ? view.panel.rowStatus[entry.it.localPath] : null
          visible: !!st && st.verb === "checkout-pr"
          text: !st ? "" : st.busy ? "checking out\u2026" : st.message
          color: !st ? view.panel.muted : st.busy ? view.panel.muted : st.ok ? view.panel.accent : view.panel.urgent
          font.family: view.panel.fontFamily
          font.pixelSize: Style.font.caption
        }
        PanelActionButton {  // PR / review in a tracked repo: checkout locally
          visible: view.hasLocalPr(entry.it)
          iconText: "\udb81\ude2c"
          size: Style.space(18)
          fontSize: Style.font.caption
          foreground: view.panel.muted
          hoverColor: view.panel.accent
          tooltipText: "Checkout locally (c)"
          onClicked: view.checkout(entry.it)
        }
        PanelActionButton {  // PR / review in a tracked repo: show it in Repos
          visible: view.hasLocalPr(entry.it)
          iconText: "\udb80\udc54"
          size: Style.space(18)
          fontSize: Style.font.caption
          foreground: view.panel.muted
          hoverColor: view.panel.accent
          tooltipText: "Show in Repos (o)"
          onClicked: view.panel.jumpToRepo(entry.it.localPath)
        }
        PanelActionButton {  // notification: mark read in place
          visible: entry.it !== undefined && entry.it.kind === "notification"
          iconText: "\udb80\udd2c"
          size: Style.space(18)
          fontSize: Style.font.caption
          foreground: view.panel.muted
          hoverColor: view.panel.accent
          tooltipText: "Mark read (m)"
          onClicked: view.panel.markNotificationRead(entry.it.id)
        }
      }
      MouseArea {
        visible: !entry.isHeader
        anchors.fill: parent
        z: -1
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          view.cursorKey = entry.modelData.key
          view.openItem(entry.it)
        }
      }
    }
  }
}
