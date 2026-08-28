pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "panel/Format.js" as Format
import "panel" as OmagitPanel

// omagit popup: every tracked repo on one dense line, expandable in place.
// All git/gh/herdr work happens in bin/ helpers; this file only holds state,
// starts processes, and parses their tab-separated records.
Panel {
  id: root
  moduleName: "omagit"
  ipcTarget: "omagit"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color muted: Color.muted

  // ------------------------------------------------------------ paths
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string binDir: pluginDir + "/bin"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omagit"
  readonly property string settingsPath: configDir + "/settings.json"

  // ------------------------------------------------------------ settings
  property var cfg: ({})
  function cfgVal(key, fallback) {
    var v = root.cfg ? root.cfg[key] : undefined
    return v === undefined || v === null ? fallback : v
  }
  readonly property string launcher: String(cfgVal("launcher", "native"))
  readonly property int debounceMs: Math.max(100, Number(cfgVal("debounceMs", 500)) || 500)
  readonly property int fallbackSeconds: Math.max(30, Number(cfgVal("fallbackRefreshSeconds", 300)) || 300)

  function applySettings(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (parsed && typeof parsed === "object") root.cfg = parsed
    } catch (e) {
      // Half-written or invalid edits keep the last good settings.
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applySettings(settingsFile.text())
    onFileChanged: settingsBootstrap.running = true   // re-merge so deleted keys heal live
  }

  property Process settingsBootstrap: Process {
    command: [root.binDir + "/omagit-config", "settings"]
    stdout: StdioCollector { id: settingsOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.applySettings(settingsOut.text)
      settingsFile.reload()
      root.discover()
    }
  }

  // ------------------------------------------------------------ repos + state
  property var repos: []          // [{path,label,root,kind}] from discovery; stable identity
  property var states: ({})       // path -> {branch,dirty,ahead,behind,upstream,age,subject,files,error}
  property var prs: ({})          // path -> [{number,title,url,ci,head}]
  property var remoteStatus: ({}) // path -> {fetch, fetchMsg, prs, prsMsg}
  property var herdrStatus: ({})  // path -> agent_status
  property var rowStatus: ({})    // path -> {ok, message, output, verb}
  property var tracking: ({ roots: [], repos: [], excluded: [] })
  property string expandedPath: ""
  property string headerMessage: ""
  property bool discovering: false
  property bool fetching: false
  property double lastFetchMs: 0
  property double nowMs: Date.now()
  property string actionRepo: ""
  property string actionVerb: ""
  property string agentName: ""

  readonly property int attentionCount: {
    var n = 0
    for (var i = 0; i < root.repos.length; i++)
      if (Format.needsAttention(root.states[root.repos[i].path])) n++
    return n
  }

  readonly property string headerSummary: {
    var parts = [root.repos.length + " repo" + (root.repos.length === 1 ? "" : "s")]
    if (root.attentionCount > 0) parts.push(root.attentionCount + " need attention")
    parts.push(Format.ago(root.lastFetchMs, root.nowMs))
    return parts.join(" · ")
  }

  function setMap(name, key, value) {
    var next = {}
    var cur = root[name]
    for (var k in cur) next[k] = cur[k]
    if (value === undefined) delete next[key]; else next[key] = value
    root[name] = next
  }

  // ---- discovery -----------------------------------------------------------
  function discover() {
    if (root.discovering) return
    root.discovering = true
    discoverProcess.running = true
    trackingProcess.running = true
  }

  property Process discoverProcess: Process {
    command: [root.binDir + "/omagit-config", "discover"]
    stdout: StdioCollector { id: discoverOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.discovering = false
      var recs = Format.splitRecords(discoverOut.text)
      var list = []
      for (var i = 0; i < recs.length; i++) {
        if (recs[i].length < 4) continue
        list.push({ path: recs[i][0], label: recs[i][1], root: recs[i][2], kind: recs[i][3] })
      }
      if (JSON.stringify(list) !== JSON.stringify(root.repos)) {
        root.repos = list
        root.restartWatcher()
      }
      var paths = list.map(function(r) { return r.path })
      root.requestRead(paths)
      root.refreshHerdr()
    }
  }

  property Process trackingProcess: Process {
    command: [root.binDir + "/omagit-config", "tracking"]
    stdout: StdioCollector { id: trackingOut; waitForEnd: true }
    onExited: function(exitCode) {
      try { root.tracking = JSON.parse(trackingOut.text) } catch (e) {}
    }
  }

  // ---- state reads (debounced, batched, one process at a time) ------------
  property var pendingReads: ({})

  function requestRead(paths) {
    var next = {}
    for (var k in root.pendingReads) next[k] = true
    for (var i = 0; i < paths.length; i++) if (paths[i]) next[paths[i]] = true
    root.pendingReads = next
    if (!flushTimer.running) flushTimer.start()
  }

  Timer {
    id: flushTimer
    interval: root.debounceMs
    repeat: false
    onTriggered: root.flushReads()
  }

  function flushReads() {
    if (stateProcess.running) return
    var paths = Object.keys(root.pendingReads)
    if (paths.length === 0) return
    root.pendingReads = {}
    stateProcess.command = [root.binDir + "/omagit-state"].concat(paths)
    stateProcess.running = true
  }

  property Process stateProcess: Process {
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyStateRecords(stateOut.text)
      if (Object.keys(root.pendingReads).length > 0) flushTimer.start()
    }
  }

  function applyStateRecords(text) {
    var recs = Format.splitRecords(text)
    var next = {}
    for (var k in root.states) next[k] = root.states[k]
    for (var i = 0; i < recs.length; i++) {
      var r = recs[i]
      if (r[0] === "REPO" && r.length >= 9) {
        next[r[1]] = {
          branch: r[2], dirty: parseInt(r[3]) || 0, ahead: parseInt(r[4]) || 0,
          behind: parseInt(r[5]) || 0, upstream: r[6], age: r[7], subject: r[8], files: []
        }
      } else if (r[0] === "FILE" && r.length >= 4 && next[r[1]]) {
        next[r[1]].files.push({ status: r[2], file: r[3] })
      } else if (r[0] === "ERR" && r.length >= 3) {
        next[r[1]] = { error: r[2], files: [], dirty: 0, ahead: 0, behind: 0, branch: "", upstream: "", age: "", subject: "" }
      }
    }
    root.states = next
  }

  // ---- watcher --------------------------------------------------------------
  property Process watchProcess: Process {
    stdout: SplitParser {
      onRead: function(line) { root.requestRead([String(line).trim()]) }
    }
  }

  function restartWatcher() {
    if (watchProcess.running) watchProcess.signal(15)
    var paths = root.repos.map(function(r) { return r.path })
    if (paths.length === 0) return
    watchProcess.command = [root.binDir + "/omagit-watch"].concat(paths)
    Qt.callLater(function() { watchProcess.running = true })
  }

  function ensureWatcher() {
    if (!watchProcess.running && root.repos.length > 0) root.restartWatcher()
  }

  Timer {
    interval: root.fallbackSeconds * 1000
    repeat: true
    running: true
    onTriggered: {
      root.discover()
      root.ensureWatcher()
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  function refreshAll() { root.discover(); root.ensureWatcher() }

  // IPC: `omarchy-shell omagit expand <label|path>` opens the panel on a row.
  function expandLabel(label) {
    for (var i = 0; i < root.repos.length; i++) {
      var r = root.repos[i]
      if (r.label === label || r.path === label) { root.expandedPath = r.path; root.open(); return }
    }
  }

  onOpenedChanged: {
    root.uninstallArmed = false
    if (root.opened) {
      root.refreshHerdr()
      root.nowMs = Date.now()
      agentNameProcess.running = true
    }
  }

  // ---- herdr status ---------------------------------------------------------
  function refreshHerdr() {
    if (root.launcher !== "herdr") { root.herdrStatus = {}; return }
    if (!herdrProcess.running) herdrProcess.running = true
  }

  property Process herdrProcess: Process {
    command: [root.binDir + "/omagit-herdr", "status"]
    stdout: StdioCollector { id: herdrOut; waitForEnd: true }
    onExited: function(exitCode) {
      var recs = Format.splitRecords(herdrOut.text)
      var next = {}
      for (var i = 0; i < recs.length; i++)
        if (recs[i][0] === "STATUS" && recs[i].length >= 3) next[recs[i][1]] = recs[i][2]
      root.herdrStatus = next
    }
  }

  property Process agentNameProcess: Process {
    command: [root.binDir + "/omagit-action", "agent-name"]
    stdout: StdioCollector { id: agentNameOut; waitForEnd: true }
    onExited: function(exitCode) { root.agentName = String(agentNameOut.text || "").trim() }
  }

  // ---- remote (manual only) ---------------------------------------------------
  property var prBuffer: ({})

  function fetchRepos(paths) {
    if (root.fetching || paths.length === 0) return
    root.fetching = true
    root.prBuffer = {}
    remoteProcess.command = [root.binDir + "/omagit-remote"].concat(paths)
    remoteProcess.running = true
  }

  function fetchAll() { root.fetchRepos(root.repos.map(function(r) { return r.path })) }

  property Process remoteProcess: Process {
    stdout: SplitParser { onRead: function(line) { root.applyRemoteLine(String(line)) } }
    onExited: function(exitCode) {
      root.fetching = false
      root.lastFetchMs = Date.now()
      root.nowMs = root.lastFetchMs
    }
  }

  function applyRemoteLine(line) {
    var r = line.split("\t")
    if (r.length < 2) return
    var path = r[1]
    var rs = root.remoteStatus[path] ? Object.assign({}, root.remoteStatus[path]) : {}
    if (r[0] === "FETCH") {
      rs.fetch = r[2]; rs.fetchMsg = r[3] || ""
      root.setMap("remoteStatus", path, rs)
    } else if (r[0] === "PR" && r.length >= 7) {
      var buf = root.prBuffer[path] || []
      buf.push({ number: parseInt(r[2]) || 0, title: r[3], url: r[4], ci: r[5], head: r[6] })
      root.prBuffer[path] = buf
    } else if (r[0] === "PRS") {
      rs.prs = r[2]; rs.prsMsg = r[3] || ""
      root.setMap("remoteStatus", path, rs)
      if (r[2] === "OK") root.setMap("prs", path, root.prBuffer[path] || [])
      else if (r[2] === "SKIP") root.setMap("prs", path, undefined)
    } else if (r[0] === "DONE") {
      root.requestRead([path])
    }
  }

  // ---- actions ----------------------------------------------------------------
  property var actionLines: []
  readonly property bool actionBusy: actionProcess.running

  function runAction(path, verb, args) {
    if (actionProcess.running) return false
    root.actionRepo = path
    root.actionVerb = verb
    root.actionLines = []
    root.setMap("rowStatus", path, { ok: true, message: verb + "…", output: [], busy: true, verb: verb })
    actionProcess.command = [root.binDir + "/omagit-action", verb, path].concat(args || [])
    actionProcess.running = true
    return true
  }

  property Process actionProcess: Process {
    stdout: SplitParser { onRead: function(line) { root.actionLines.push(String(line)) } }
    onExited: function(exitCode) {
      var output = [], ok = exitCode === 0, message = ok ? "Done" : "Failed"
      for (var i = 0; i < root.actionLines.length; i++) {
        var r = root.actionLines[i].split("\t")
        if (r[0] === "OUT") output.push(r.slice(1).join("\t"))
        else if (r[0] === "RESULT") { ok = r[1] === "OK"; message = r.slice(2).join("\t") }
      }
      var path = root.actionRepo, verb = root.actionVerb
      root.setMap("rowStatus", path, { ok: ok, message: message, output: output, busy: false, verb: verb })
      root.actionRepo = ""; root.actionVerb = ""
      root.requestRead([path])
      if (ok && verb === "merge-pr") root.setMap("prs", path, undefined)
      if (verb === "open-terminal" || verb === "launch-agent") root.refreshHerdr()
    }
  }

  // ---- tracking edits -------------------------------------------------------------
  function trackPath(kind, path) {
    var p = String(path || "").trim()
    if (p === "") return
    if (p.indexOf("~") === 0) p = root.home + p.substring(1)
    root.headerMessage = "Adding " + p + "…"
    configProcess.command = [root.binDir + "/omagit-config", kind === "root" ? "add-root" : "add-repo", p]
    configProcess.running = true
  }

  function untrack(row) {
    root.headerMessage = ""
    if (row.path === root.expandedPath) root.expandedPath = ""
    configProcess.command = [root.binDir + "/omagit-config", "untrack", row.path]
    configProcess.running = true
  }

  function untrackRoot(path) {
    configProcess.command = [root.binDir + "/omagit-config", "untrack-root", path]
    configProcess.running = true
  }

  property Process configProcess: Process {
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.headerMessage = exitCode === 0 ? "" : String(configErr.text || configOut.text || "failed").trim()
      root.discover()
    }
  }

  function openSettings() { Quickshell.execDetached(["omarchy-launch-config-editor", root.settingsPath]) }

  function openUrl(url) {
    var u = String(url || "")
    if (!/^https?:\/\//.test(u)) return
    if (!Qt.openUrlExternally(u)) Quickshell.execDetached(["xdg-open", u])
  }

  // ---- uninstall ---------------------------------------------------------------------
  property bool uninstallArmed: false
  Timer { id: disarmTimer; interval: 6000; onTriggered: root.uninstallArmed = false }
  function uninstallClicked() {
    if (!root.uninstallArmed) { root.uninstallArmed = true; disarmTimer.restart(); return }
    root.uninstallArmed = false
    if (watchProcess.running) watchProcess.signal(15)
    Quickshell.execDetached(["bash", "-c",
      'setsid nohup bash -c \'rm -rf "$HOME/.config/omagit"; omarchy plugin remove omagit --yes\' >/dev/null 2>&1 &'])
  }

  Component.onCompleted: settingsBootstrap.running = true
  Component.onDestruction: { if (watchProcess.running) watchProcess.signal(15) }

  // ================================================================== UI
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    ColumnLayout {
      id: column
      anchors.fill: parent
      spacing: Style.space(6)

      // ---------------------------------------------------------------- header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "\udb81\ude2c"
          color: root.attentionCount > 0 ? root.urgent : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            text: "omagit"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            Layout.fillWidth: true
            text: root.headerSummary
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        Button {
          text: root.fetching ? "Fetching…" : "Fetch all"
          iconText: "\udb80\uddda"
          iconSpinning: root.fetching
          enabled: !root.fetching && root.repos.length > 0
          tooltipText: "git fetch + open PRs for every repo"
          onClicked: root.fetchAll()
        }
        PanelActionButton {
          iconText: "\udb81\udc50"
          tooltipText: "Refresh (re-scan roots, re-read all repos)"
          onClicked: root.refreshAll()
        }
        PanelActionButton {
          iconText: "\udb81\udc15"
          tooltipText: addForm.visible ? "Hide tracking" : "Add root / repo, manage tracking"
          onClicked: addForm.visible = !addForm.visible
        }
        PanelActionButton {
          iconText: "\udb81\udc93"
          tooltipText: "Open settings.json"
          onClicked: root.openSettings()
        }
      }

      // ---------------------------------------------------------- add / tracking
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
            placeholderText: "~/Nucleus or ~/Work/foo"
            font.family: root.fontFamily
            onAccepted: { root.trackPath("root", text); text = "" }
          }
          Button { text: "Add root"; onClicked: { root.trackPath("root", addField.text); addField.text = "" } }
          Button { text: "Add repo"; onClicked: { root.trackPath("repo", addField.text); addField.text = "" } }
        }
        Repeater {
          model: root.tracking.roots || []
          delegate: RowLayout {
            required property string modelData
            Layout.fillWidth: true
            spacing: Style.space(6)
            Text {
              Layout.fillWidth: true
              text: "root  " + modelData
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
            PanelActionButton {
              iconText: "\udb80\udd56"
              size: Style.space(18)
              tooltipText: "Stop tracking this root and everything under it"
              onClicked: root.untrackRoot(modelData)
            }
          }
        }
        Text {
          visible: root.headerMessage !== ""
          Layout.fillWidth: true
          text: root.headerMessage + "  ✕"
          color: root.urgent
          wrapMode: Text.Wrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.headerMessage = "" }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // ------------------------------------------------------------- repo list
      Text {
        visible: root.repos.length === 0
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        Layout.bottomMargin: Style.space(8)
        text: root.discovering ? "Scanning…" : "No repos tracked yet. Use \udb81\udc15 to add a scan root or a single repo."
        color: root.muted
        wrapMode: Text.Wrap
        font.family: root.fontFamily
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
        model: root.repos

        delegate: OmagitPanel.RepoRow {
          required property var modelData
          width: list.width
          panel: root
          repo: modelData
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // ---------------------------------------------------------------- footer
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Text {
          Layout.fillWidth: true
          text: root.launcher === "herdr" ? "launcher: herdr" : "launcher: native"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Button {
          text: root.uninstallArmed ? "Confirm uninstall" : "Uninstall"
          foreground: root.uninstallArmed ? root.urgent : root.muted
          fontSize: Style.font.caption
          tooltipText: "Removes ~/.config/omagit and the plugin"
          onClicked: root.uninstallClicked()
        }
      }
    }
  }
}
