pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Format.js" as Format

// Repos tab content: add/tracking form, filter, empty state, and the repo list.
// Renders panel state and dispatches to panel functions; owns no processes.
//
// keys (Panel's PanelKeyCatcher delegates here; r / f are handled by Panel):
//   j k Up Down  move the highlight      Enter / Space  expand or collapse
//   /  focus the filter (Enter keeps it, Esc clears it)   a  attention-only
//   Esc  clear filter, then close the panel
//   expanded + highlighted row:  c Commit  b Branch  s Switch  p PR  m FF main
//                                u Fetch   d Diff    t Term    g Agent
ColumnLayout {
  id: view

  required property var panel
  property alias addFormVisible: addForm.visible

  // ---- view interface (a second tab implements the same shape) ----
  readonly property bool textFocused: addField.activeFocus || filterField.activeFocus || rowTextPath !== ""

  function moveCursor(dy) {
    if (visibleRepos.length === 0) return
    var i = Math.max(0, Math.min(visibleRepos.length - 1, cursorIndex + dy))
    cursorPath = visibleRepos[i].path
    list.positionViewAtIndex(i, ListView.Contain)
  }

  function activate() {
    var row = list.itemAtIndex(cursorIndex)
    if (!row) return
    row.toggle()
    Qt.callLater(function() { list.positionViewAtIndex(view.cursorIndex, ListView.Contain) })
  }

  function handleKey(text) {
    if (text === "/") { filterField.forceActiveFocus(); return true }
    if (text === "a") { attentionOnly = !attentionOnly; return true }
    var action = actionKeys[text]
    var row = list.itemAtIndex(cursorIndex)
    if (!action || !row || !row.expanded) return false
    row.trigger(action)
    return true
  }

  function handleEscape() {
    if (filterField.text === "") return false
    filterField.text = ""
    return true
  }

  // Cursor to the expanded row if visible, else the first visible row.
  function resetCursor() {
    cursorPath = panel.expandedPath
    Qt.callLater(function() { list.positionViewAtIndex(view.cursorIndex, ListView.Contain) })
  }

  // Highlight and scroll to a repo, clearing filters that would hide it.
  function reveal(path) {
    filterField.text = ""
    attentionOnly = false
    cursorPath = path
    Qt.callLater(function() { list.positionViewAtIndex(view.cursorIndex, ListView.Contain) })
  }

  function releaseFocus() { panel.keyTarget.forceActiveFocus() }

  readonly property var actionKeys: ({
    c: "commit", b: "branch", s: "switch", p: "pr", m: "ff-main",
    u: "fetch", d: "diff", t: "term", g: "agent"
  })

  // ---- filter + cursor state (session only) ----
  property bool attentionOnly: false
  property string cursorPath: ""
  property string rowTextPath: ""   // path of the row whose text field has focus

  // Reads panel.states only while attention-only is on, so state ticks leave
  // the model alone otherwise.
  readonly property var matches: {
    var q = filterField.text.trim().toLowerCase()
    return panel.repos.filter(function(r) {
      if (q !== "" && r.label.toLowerCase().indexOf(q) < 0) return false
      return !view.attentionOnly || Format.needsAttention(view.panel.states[r.path])
    })
  }
  property var visibleRepos: []
  onMatchesChanged: {
    if (JSON.stringify(matches) !== JSON.stringify(visibleRepos)) visibleRepos = matches
  }
  Component.onCompleted: visibleRepos = matches

  // Falls back to the first visible row when cursorPath is hidden or gone.
  readonly property int cursorIndex: {
    for (var i = 0; i < visibleRepos.length; i++)
      if (visibleRepos[i].path === cursorPath) return i
    return visibleRepos.length > 0 ? 0 : -1
  }

  onAddFormVisibleChanged: if (!addFormVisible) releaseFocus()

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
        Keys.onEscapePressed: view.releaseFocus()
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

  // ------------------------------------------------------------- filter
  RowLayout {
    visible: view.panel.repos.length > 0
    Layout.fillWidth: true
    spacing: Style.space(6)
    TextField {
      id: filterField
      Layout.fillWidth: true
      placeholderText: "Filter repos ( / )"
      font.family: view.panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      verticalPadding: Style.space(3)
      Keys.onEscapePressed: { text = ""; view.releaseFocus() }
      onAccepted: view.releaseFocus()
    }
    Button {
      text: "Attention"
      fontSize: Style.font.caption
      selected: view.attentionOnly
      tooltipText: "Only repos needing attention (a)"
      onClicked: view.attentionOnly = !view.attentionOnly
    }
  }

  // ------------------------------------------------------------- repo list
  Text {
    visible: view.visibleRepos.length === 0
    Layout.fillWidth: true
    Layout.topMargin: Style.space(8)
    Layout.bottomMargin: Style.space(8)
    text: view.panel.repos.length > 0 ? "No repos match."
        : view.panel.discovering ? "Scanning…" : "No repos tracked yet. Use \udb81\udc15 to add a scan root or a single repo."
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
    model: view.visibleRepos

    delegate: RepoRow {
      required property var modelData
      width: list.width
      panel: view.panel
      repo: modelData
      highlighted: modelData.path === view.visibleRepos[view.cursorIndex]?.path
      onToggled: view.cursorPath = path
      onTextFocusedChanged: {
        if (textFocused) view.rowTextPath = path
        else if (view.rowTextPath === path) view.rowTextPath = ""
      }
      Component.onDestruction: if (view.rowTextPath === path) view.rowTextPath = ""
    }
  }
}
