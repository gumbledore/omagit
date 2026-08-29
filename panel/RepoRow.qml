pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Format.js" as Format

// One tracked repo: a dense summary line, expandable in place. Everything the
// row shows comes from panel.states / panel.prs / panel.rowStatus keyed by
// path, so state updates never recreate the delegate (forms keep their text).
Item {
  id: row

  required property var panel
  required property var repo

  readonly property string path: repo.path
  readonly property string label: repo.label
  readonly property var st: panel.states[path] || null
  readonly property var prList: panel.prs[path] || []
  readonly property var remote: panel.remoteStatus[path] || null
  readonly property string herdr: panel.herdrStatus[path] || ""
  readonly property var status: panel.rowStatus[path] || null
  readonly property bool expanded: panel.expandedPath === path
  readonly property bool attention: Format.needsAttention(st)
  readonly property bool busy: panel.actionBusy && panel.actionRepo === path
  readonly property bool anyBusy: panel.actionBusy
  readonly property string branch: st ? st.branch : ""
  readonly property bool onMain: Format.isMain(branch)

  readonly property color fg: panel.fg
  readonly property color muted: panel.muted
  readonly property color accent: panel.accent
  readonly property color urgent: panel.urgent
  readonly property string fontFamily: panel.fontFamily
  readonly property int capSize: Style.font.caption
  readonly property int bodySize: Style.font.bodySmall

  // "" | commit | branch | switch | diff
  property string mode: ""
  property string diffText: ""
  property var branches: []
  property int armedMerge: -1
  readonly property int maxFiles: 12

  implicitHeight: body.implicitHeight + Style.space(6)

  function ciRollup() {
    var worst = "none"
    for (var i = 0; i < prList.length; i++) {
      var c = prList[i].ci
      if (c === "failing") return "failing"
      if (c === "pending") worst = "pending"
      else if (c === "passing" && worst === "none") worst = "passing"
    }
    return worst
  }

  function toggle() {
    clearStatus()
    if (expanded) { panel.expandedPath = ""; mode = "" }
    else { panel.expandedPath = path; row.armedMerge = -1 }
  }

  function setMode(m) {
    if (mode === m) { mode = ""; return }
    mode = m
    if (m === "commit") suggestProcess.running = true
    else if (m === "branch") branchField.text = String(panel.cfgVal("branchPrefix", "work/")) + Format.isoDate()
    else if (m === "switch") branchesProcess.running = true
    else if (m === "diff") { diffText = "Loading diff…"; diffProcess.running = true }
  }

  function act(verb, args) { panel.runAction(path, verb, args || []) }

  // Any click in the row dismisses a finished status message.
  function clearStatus() { if (status && !status.busy) panel.setMap("rowStatus", path, undefined) }

  function submitCommit() {
    var target = commitMainToggle.checked ? "" : commitBranchField.text.trim()
    if (act("commit", [commitMessageField.text, target])) mode = ""
  }

  function mergePr(pr) {
    if (pr.ci === "failing" && row.armedMerge !== pr.number) { row.armedMerge = pr.number; return }
    row.armedMerge = -1
    act("merge-pr", [String(pr.number)])
  }

  // Helper processes local to the expanded row -----------------------------
  Process {
    id: suggestProcess
    command: [panel.binDir + "/omagit-action", "suggest", row.path]
    stdout: StdioCollector { id: suggestOut; waitForEnd: true }
    onExited: function(exitCode) {
      var recs = Format.splitRecords(suggestOut.text)
      for (var i = 0; i < recs.length; i++) {
        if (recs[i][0] === "MSG") commitMessageField.text = recs[i][1] || ""
        else if (recs[i][0] === "BRANCH") commitBranchField.text = recs[i][1] || ""
      }
      commitMainToggle.checked = false
      commitMessageField.forceActiveFocus()
    }
  }
  Process {
    id: branchesProcess
    command: [panel.binDir + "/omagit-action", "branches", row.path]
    stdout: StdioCollector { id: branchesOut; waitForEnd: true }
    onExited: function(exitCode) {
      var recs = Format.splitRecords(branchesOut.text), list = []
      for (var i = 0; i < recs.length; i++)
        if (recs[i][0] === "BRANCH") list.push({ name: recs[i][1], current: recs[i][2] === "1" })
      row.branches = list
    }
  }
  Process {
    id: diffProcess
    command: ["bash", "-c", '"$0" diff "$1" | head -c 200000', panel.binDir + "/omagit-action", row.path]
    stdout: StdioCollector { id: diffOut; waitForEnd: true }
    onExited: function(exitCode) {
      var t = String(diffOut.text || "").trim()
      row.diffText = t === "" ? "No changes." : t
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: row.expanded ? Util.alpha(row.fg, 0.06)
         : row.attention ? Util.alpha(row.urgent, 0.10) : "transparent"
    border.width: row.expanded ? 1 : 0
    border.color: Util.alpha(row.fg, 0.15)
  }

  MouseArea { anchors.fill: parent; onClicked: row.clearStatus() }  // empty space in the row

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(3)
    spacing: Style.space(4)

    // ------------------------------------------------------------ summary line
    Item {
      Layout.fillWidth: true
      implicitHeight: summary.implicitHeight + Style.space(4)

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggle()
      }

      RowLayout {
        id: summary
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        spacing: Style.space(6)

        Rectangle {  // herdr agent dot; slot always reserved so labels line up
          width: Style.space(7); height: width; radius: width / 2
          color: row.herdr === "working" ? row.accent : row.herdr === "blocked" ? row.urgent : row.muted
          opacity: row.herdr === "" ? 0 : 1
        }
        Text {
          Layout.preferredWidth: Style.space(150)
          text: row.label
          color: row.fg
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
          font.bold: row.attention
          elide: Text.ElideMiddle
        }
        Text {
          Layout.fillWidth: true
          text: row.st ? (row.st.error ? row.st.error : (row.branch === "" ? "(no branch)" : row.branch)) : "…"
          color: row.st && row.st.error ? row.urgent : row.muted
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
          elide: Text.ElideRight
        }
        Text {
          visible: row.st && row.st.dirty > 0
          text: "●" + (row.st ? row.st.dirty : 0)
          color: row.urgent
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
        }
        Text {
          visible: row.st && !row.st.error && row.st.upstream === "yes" && (row.st.ahead > 0 || row.st.behind > 0)
          text: (row.st && row.st.ahead > 0 ? "↑" + row.st.ahead : "") + (row.st && row.st.behind > 0 ? "↓" + row.st.behind : "")
          color: row.accent
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
        }
        Text {
          visible: row.st && !row.st.error && row.st.upstream !== "yes"
          text: row.st && row.st.upstream === "noremote" ? "no remote" : "no upstream"
          color: row.muted
          font.family: row.fontFamily
          font.pixelSize: row.capSize
          font.italic: true
        }
        Rectangle {
          visible: row.prList.length > 0
          implicitWidth: prChip.implicitWidth + Style.space(8)
          implicitHeight: prChip.implicitHeight + Style.space(2)
          radius: height / 2
          color: Util.alpha(Format.ciColor(row.ciRollup(), row.accent, row.urgent, row.muted), 0.25)
          border.width: 1
          border.color: Format.ciColor(row.ciRollup(), row.accent, row.urgent, row.muted)
          Text {
            id: prChip
            anchors.centerIn: parent
            text: "PR " + row.prList.length
            color: row.fg
            font.family: row.fontFamily
            font.pixelSize: row.capSize
          }
        }
        Text {
          text: row.st ? Format.shortAge(row.st.age) : ""
          color: row.muted
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
        PanelActionButton {
          iconText: "\udb80\udd56"
          size: Style.space(18)
          fontSize: row.capSize
          foreground: row.muted
          hoverColor: row.urgent
          tooltipText: "Untrack " + row.label + " (nothing on disk changes)"
          onClicked: row.panel.untrack(row.repo)
        }
      }
    }

    // --------------------------------------------------------------- expanded
    ColumnLayout {
      visible: row.expanded
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(6)
      Layout.rightMargin: Style.space(6)
      Layout.bottomMargin: Style.space(4)
      spacing: Style.space(4)

      Text {
        visible: row.st && row.st.subject !== ""
        Layout.fillWidth: true
        text: row.st ? ("last: " + row.st.subject + "  ·  " + row.st.age) : ""
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        elide: Text.ElideRight
      }

      // dirty files
      Repeater {
        model: row.st ? row.st.files.slice(0, row.maxFiles) : []
        delegate: RowLayout {
          id: fileRow
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.space(6)
          Text {
            text: fileRow.modelData.status
            color: fileRow.modelData.status === "?" ? row.muted : fileRow.modelData.status === "D" ? row.urgent : row.accent
            font.family: row.fontFamily
            font.pixelSize: row.capSize
            font.bold: true
            Layout.preferredWidth: Style.space(10)
          }
          Text {
            Layout.fillWidth: true
            text: fileRow.modelData.file
            color: fileArea.containsMouse ? row.accent : row.fg
            font.family: row.fontFamily
            font.pixelSize: row.capSize
            elide: Text.ElideMiddle
            MouseArea {
              id: fileArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: row.act("open-file", [fileRow.modelData.file])
            }
          }
        }
      }
      Text {
        visible: row.st && row.st.files.length > row.maxFiles
        text: "+" + (row.st ? row.st.files.length - row.maxFiles : 0) + " more (see Diff)"
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        font.italic: true
      }
      Text {
        visible: row.st && row.st.files.length === 0 && !row.st.error
        text: "Working tree clean"
        color: row.muted
        font.family: row.fontFamily
        font.pixelSize: row.capSize
        font.italic: true
      }

      // open PRs
      Repeater {
        model: row.prList
        delegate: RowLayout {
          id: prRow
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.space(6)
          Rectangle {
            width: Style.space(7); height: width; radius: width / 2
            color: Format.ciColor(prRow.modelData.ci, row.accent, row.urgent, row.muted)
          }
          Text {
            Layout.fillWidth: true
            text: "#" + prRow.modelData.number + "  " + prRow.modelData.title + "  (" + prRow.modelData.head + ")"
            color: prArea.containsMouse ? row.accent : row.fg
            font.family: row.fontFamily
            font.pixelSize: row.capSize
            elide: Text.ElideRight
            MouseArea {
              id: prArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: row.panel.openUrl(prRow.modelData.url)
            }
          }
          Text {
            text: prRow.modelData.ci
            color: Format.ciColor(prRow.modelData.ci, row.accent, row.urgent, row.muted)
            font.family: row.fontFamily
            font.pixelSize: row.capSize
          }
          Button {
            readonly property bool armed: row.armedMerge === prRow.modelData.number
            visible: String(row.panel.cfgVal("allowMerge", true)) !== "false"
            text: armed ? "Merge anyway" : "Merge"
            fontSize: row.capSize
            foreground: prRow.modelData.ci === "failing" ? row.urgent : row.fg
            selected: armed
            enabled: !row.anyBusy
            tooltipText: "gh pr merge --" + row.panel.cfgVal("mergeStrategy", "squash")
              + (prRow.modelData.ci === "failing" ? " (CI failing: click twice)" : "")
            onClicked: row.mergePr(prRow.modelData)
          }
        }
      }

      // action strip
      Flow {
        Layout.fillWidth: true
        spacing: Style.space(4)
        Button { text: "Commit"; iconText: "\udb80\udd67"; fontSize: row.capSize; selected: row.mode === "commit"; enabled: !row.anyBusy; tooltipText: "Stage all, commit, push"; onClicked: row.setMode("commit") }
        Button { text: "Branch"; iconText: "\udb81\ude2c"; fontSize: row.capSize; selected: row.mode === "branch"; enabled: !row.anyBusy; tooltipText: "New branch"; onClicked: row.setMode("branch") }
        Button { text: "Switch"; iconText: "\udb81\udce1"; fontSize: row.capSize; selected: row.mode === "switch"; enabled: !row.anyBusy; tooltipText: "Switch branch"; onClicked: row.setMode("switch") }
        Button { text: "PR"; iconText: "\udb80\udea4"; fontSize: row.capSize; enabled: !row.anyBusy; tooltipText: row.onMain ? "Refused on " + row.branch : "Push and open the PR form"; onClicked: row.act("create-pr") }
        Button { text: "FF main"; iconText: "\udb80\ude11"; fontSize: row.capSize; enabled: !row.anyBusy; tooltipText: "Fast-forward the default branch"; onClicked: row.act("ff-main") }
        Button { text: "Fetch"; iconText: "\udb80\uddda"; fontSize: row.capSize; enabled: !row.panel.fetching; tooltipText: "git fetch + open PRs"; onClicked: row.panel.fetchRepos([row.path]) }
        Button { text: "Diff"; iconText: "\udb80\ude19"; fontSize: row.capSize; selected: row.mode === "diff"; tooltipText: "Read-only diff"; onClicked: row.setMode("diff") }
        Button { text: "Term"; iconText: "\udb80\udd8d"; fontSize: row.capSize; enabled: !row.anyBusy; tooltipText: row.panel.launcher === "herdr" ? "herdr workspace" : "Terminal here"; onClicked: row.act("open-terminal", [row.label]) }
        Button {
          text: row.panel.agentName !== "" ? row.panel.agentName : "agent"
          iconText: "\udb81\udea9"
          fontSize: row.capSize
          enabled: !row.anyBusy
          tooltipText: row.panel.agentName !== "" ? "Launch " + row.panel.agentName + " here" : "No default agent set"
          onClicked: row.act("launch-agent", [row.label])
        }
      }

      // inline: commit form
      ColumnLayout {
        visible: row.mode === "commit"
        Layout.fillWidth: true
        spacing: Style.space(4)
        TextField {
          id: commitMessageField
          Layout.fillWidth: true
          placeholderText: "Commit message"
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
          onAccepted: row.submitCommit()
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          TextField {
            id: commitBranchField
            Layout.fillWidth: true
            placeholderText: "Target branch"
            enabled: !commitMainToggle.checked
            opacity: enabled ? 1 : 0.4
            font.family: row.fontFamily
            font.pixelSize: row.bodySize
            onAccepted: row.submitCommit()
          }
          Toggle {
            id: commitMainToggle
            visible: row.onMain
            label: "Commit to " + row.branch
            onClicked: checked = !checked
          }
          Button { text: "Commit & push"; iconText: "\udb80\udd2c"; fontSize: row.capSize; enabled: !row.anyBusy && commitMessageField.text.trim() !== ""; onClicked: row.submitCommit() }
        }
      }

      // inline: new branch
      RowLayout {
        visible: row.mode === "branch"
        Layout.fillWidth: true
        spacing: Style.space(6)
        TextField {
          id: branchField
          Layout.fillWidth: true
          placeholderText: "Branch name"
          font.family: row.fontFamily
          font.pixelSize: row.bodySize
          onAccepted: { if (row.act("new-branch", [text.trim()])) row.mode = "" }
        }
        Button { text: "Create"; fontSize: row.capSize; enabled: !row.anyBusy && branchField.text.trim() !== ""; onClicked: { if (row.act("new-branch", [branchField.text.trim()])) row.mode = "" } }
      }

      // inline: switch list
      Flow {
        visible: row.mode === "switch"
        Layout.fillWidth: true
        spacing: Style.space(4)
        Repeater {
          model: row.branches
          delegate: Button {
            required property var modelData
            text: modelData.name
            fontSize: row.capSize
            selected: modelData.current
            enabled: !modelData.current && !row.anyBusy
            onClicked: { if (row.act("switch", [modelData.name])) row.mode = "" }
          }
        }
        Text {
          visible: row.branches.length === 0
          text: "Loading branches…"
          color: row.muted
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
      }

      // inline: diff
      Flickable {
        visible: row.mode === "diff"
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(diffView.implicitHeight, Style.space(260))
        contentHeight: diffView.implicitHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        TextEdit {
          id: diffView
          width: parent.width
          text: row.diffText
          readOnly: true
          selectByMouse: true
          wrapMode: TextEdit.NoWrap
          color: row.fg
          selectionColor: Util.alpha(row.accent, 0.4)
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
      }

      // status line (+ captured output on failure)
      ColumnLayout {
        visible: row.status !== null
        Layout.fillWidth: true
        spacing: Style.space(2)
        Text {
          Layout.fillWidth: true
          text: row.status ? (row.status.ok ? "✓ " : "✗ ") + row.status.message : ""
          color: row.status && row.status.ok ? row.accent : row.urgent
          wrapMode: Text.Wrap
          font.family: row.fontFamily
          font.pixelSize: row.capSize
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.clearStatus() }
        }
        Text {
          visible: row.status && !row.status.ok && row.status.output.length > 0
          Layout.fillWidth: true
          text: row.status ? row.status.output.join("\n") : ""
          color: row.muted
          wrapMode: Text.Wrap
          font.family: row.fontFamily
          font.pixelSize: row.capSize
        }
      }
      Text {
        visible: row.remote && row.remote.fetch === "ERR"
        Layout.fillWidth: true
        text: row.remote ? "fetch: " + row.remote.fetchMsg : ""
        color: row.urgent
        wrapMode: Text.Wrap
        font.family: row.fontFamily
        font.pixelSize: row.capSize
      }
      Text {
        visible: row.remote && row.remote.prs === "ERR"
        Layout.fillWidth: true
        text: row.remote ? "PRs: " + row.remote.prsMsg : ""
        color: row.urgent
        wrapMode: Text.Wrap
        font.family: row.fontFamily
        font.pixelSize: row.capSize
      }
    }
  }
}
