import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry for omagit: a git-branch glyph with an attention badge (repos that
// are dirty, ahead, or behind; hidden at zero). The panel is loaded eagerly so
// the watcher runs and the badge stays live while the popup is closed.
BarWidget {
  id: root
  moduleName: "gumbledore.omagit"

  // The widget, not the panel, is the bar's popout identity (see omaplug).
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function togglePanel() { if (panelItem) panelItem.toggle() }
  function refresh() { if (panelItem) panelItem.refreshAll() }
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelItem) panelItem.closeForPopoutSwitch() }

  property var panelItem: null
  readonly property int attention: panelItem ? panelItem.attentionCount : 0

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    panelItem = target
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "omagit"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function expand(label: string): void { if (root.panelItem) root.panelItem.expandLabel(label) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb81\ude2c"
    active: root.attention > 0
    useActiveColor: false
    tooltipText: root.attention > 0
      ? root.attention + " repo" + (root.attention === 1 ? "" : "s") + " need attention"
      : "omagit"
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
      else if (b === Qt.RightButton) root.refresh()
    }

    Rectangle {
      visible: root.attention > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: root.vertical ? Style.space(3) : Style.space(1)
      anchors.topMargin: Style.space(3)
      width: Math.max(Style.space(11), badgeText.implicitWidth + Style.space(4))
      height: Style.space(11)
      radius: height / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      Text {
        id: badgeText
        anchors.centerIn: parent
        text: root.attention > 99 ? "99+" : String(root.attention)
        color: Color.background
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.space(8)
        font.bold: true
      }
    }
  }
}
