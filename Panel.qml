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
  moduleName: "gumbledore.omagit"
  ipcTarget: "omagit"
  manageIpc: false

  property var anchorItem: null
  // Where keys go when no text field is editing (views hand focus back here).
  readonly property Item keyTarget: keyCatcher
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
  readonly property string configDir: home + "/.config/gumbledore.omagit"
  readonly property string settingsPath: configDir + "/settings.json"

  // ------------------------------------------------------------ settings
  property var cfg: ({})
  function cfgVal(key, fallback) {
    var v = root.cfg ? root.cfg[key] : undefined
    return v === undefined || v === null ? fallback : v
  }
  readonly property string launcher: String(cfgVal("launcher", "native"))
  readonly property string linkBehavior: String(cfgVal("linkBehavior", "browser"))
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

  // ---- inbox (account-wide; cached output shown first, live fetch swaps in on INBOXDONE) ----
  property var inbox: Format.emptyInbox()
  property var inboxBuffer: []
  property string tab: "repos"   // "repos" | "inbox"; remembered via omagit-config ui-set
  readonly property var currentView: root.tab === "inbox" ? inboxView : reposView

  function sectionItems(name) {
    var sec = root.inbox.sections[name]
    return sec ? sec.items : []
  }
  readonly property int inboxCount: {
    var n = 0
    for (var k in root.inbox.sections) n += root.inbox.sections[k].items.length
    return n
  }
  readonly property int inboxUnreadCount: root.sectionItems("notifications").length
  readonly property int inboxReviewCount: root.sectionItems("reviews").length
  readonly property int inboxFailingPrCount: root.sectionItems("prs").filter(function(i) { return i.ci === "failing" }).length

  readonly property bool inboxAttention: inboxUnreadCount > 0 || inboxReviewCount > 0 || inboxFailingPrCount > 0

  // Inbox -> local clone: explicit key/button only (checkout refuses a dirty tree).
  function checkoutPr(localPath, number) { return root.runAction(localPath, "checkout-pr", [String(number)]) }
  function jumpToRepo(localPath) {
    root.setTab("repos")
    root.expandedPath = localPath
    reposView.reveal(localPath)
  }

  function setTab(name) {
    if (name === root.tab) return
    root.tab = name
    Quickshell.execDetached([root.binDir + "/omagit-config", "ui-set", "tab", name])
  }

  property Process tabProcess: Process {
    command: [root.binDir + "/omagit-config", "ui-get", "tab"]
    stdout: StdioCollector { id: tabOut; waitForEnd: true }
    onExited: function(exitCode) { if (String(tabOut.text).trim() === "inbox") root.tab = "inbox" }
  }

  // mark-read / mark-all: one omagit-inbox action at a time
  property string inboxMessage: ""
  property var inboxPendingIds: []
  property Process inboxActionProcess: Process {
    stdout: StdioCollector { id: inboxActionOut; waitForEnd: true }
    onExited: function(exitCode) {
      var res = null
      var recs = Format.splitRecords(inboxActionOut.text)
      for (var i = 0; i < recs.length; i++) if (recs[i][0] === "RESULT") res = recs[i]
      if (res && res[1] === "OK") {
        root.inbox = Format.withoutNotifications(root.inbox, root.inboxPendingIds)
        root.inboxMessage = ""
      } else {
        root.inboxMessage = res ? (res[2] || "action failed") : "action failed"
      }
      root.inboxPendingIds = []
    }
  }

  function markNotificationRead(id) {
    if (root.inboxActionProcess.running) return
    root.inboxPendingIds = [id]
    root.inboxActionProcess.command = [root.binDir + "/omagit-inbox", "mark-read", String(id)]
    root.inboxActionProcess.running = true
  }

  function markAllNotificationsRead() {
    if (root.inboxActionProcess.running) return
    var shown = root.sectionItems("notifications")
    if (shown.length === 0) return
    var args = Format.markAllArgs(shown)
    root.inboxPendingIds = shown.filter(function(n) { return n.updatedAt <= args.timestamp }).map(function(n) { return n.id })
    root.inboxActionProcess.command = [root.binDir + "/omagit-inbox", "mark-all", args.timestamp].concat(args.ids)
    root.inboxActionProcess.running = true
  }

  property Process inboxCacheProcess: Process {
    command: [root.binDir + "/omagit-inbox", "cached"]
    stdout: StdioCollector { id: inboxCacheOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.inbox.fetchedAt > 0) return   // a live fetch already landed
      var parsed = Format.parseInbox(Format.splitRecords(inboxCacheOut.text))
      if (parsed.fetchedAt > 0) root.inbox = parsed
    }
  }

  readonly property string headerSummary: {
    var parts = [root.repos.length + " repo" + (root.repos.length === 1 ? "" : "s")]
    if (root.attentionCount > 0) parts.push(root.attentionCount + " need attention")
    parts.push(Format.ago(root.lastFetchMs, root.nowMs))
    var af = Format.autoFetchLine(root.autoStatus)
    if (af !== "") parts.push(af)
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
      if (!root.catchUpDone) { root.catchUpDone = true; root.checkAutoFetch() }
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
      reposView.resetCursor()
      inboxView.resetCursor()
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

  // ---- remote (Fetch buttons + background auto-fetch) ---------------------------
  property var prBuffer: ({})
  property var ghStatus: ({ state: "ok", reset: 0, message: "" })
  property string fetchMode: "manual"   // mode of the run in progress; auto failures stay quiet
  property var autoStatus: ({ ok: true, finish: 0, mode: "", message: "", next: 0 })
  property bool catchUpDone: false
  property bool fetchBusy: false

  // All fetches go through omagit-autofetch so its lock covers manual ones too.
  // `full` adds the account-wide inbox (omagit-autofetch --inbox) and counts as the scheduled run.
  function fetchRepos(paths, mode, full) {
    if (root.fetching || (!full && paths.length === 0)) return
    root.fetching = true
    root.fetchMode = mode || "manual"
    root.prBuffer = {}
    root.inboxBuffer = []
    if (full) root.ghStatus = { state: "ok", reset: 0, message: "" }
    remoteProcess.command = [root.binDir + "/omagit-autofetch", "run", root.fetchMode].concat(full ? ["--inbox"] : [], paths)
    remoteProcess.running = true
  }

  function allPaths() { return root.repos.map(function(r) { return r.path }) }

  // ---- auto-fetch: the helper decides, the timer only polls -------------------
  function checkAutoFetch() {
    if (root.fetching || dueProcess.running || actionProcess.running) return   // don't race a user action's own fetch
    dueProcess.running = true
  }

  property Process dueProcess: Process {
    command: [root.binDir + "/omagit-autofetch", "due"]
    stdout: StdioCollector { id: dueOut; waitForEnd: true }
    onExited: function(exitCode) {
      var recs = Format.splitRecords(dueOut.text)
      var yes = false
      var a = Object.assign({}, root.autoStatus)
      for (var i = 0; i < recs.length; i++) {
        var r = recs[i]
        if (r[0] === "DUE") {
          yes = r[1] === "yes"
          a.next = parseInt(r[3]) || 0
        } else if (r[0] === "LAST") {
          var fin = parseInt(r[1]) || 0
          a.finish = fin; a.ok = r[2] !== "err"; a.mode = r[3] || ""; a.message = r[4] || ""
          if (fin * 1000 > root.lastFetchMs) root.lastFetchMs = fin * 1000
        }
      }
      root.autoStatus = a
      if (yes && !root.fetching) root.fetchRepos(root.allPaths(), "auto", true)
    }
  }

  property Timer autoFetchTimer: Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.checkAutoFetch()
  }

  function fetchAll() { root.fetchRepos(root.allPaths(), "manual", true) }

  property Process remoteProcess: Process {
    stdout: SplitParser { onRead: function(line) { root.applyRemoteLine(String(line)) } }
    onExited: function(exitCode) {
      root.fetching = false
      if (root.fetchBusy) { root.fetchBusy = false; return }   // another fetch held the lock
      root.lastFetchMs = Date.now()
      root.nowMs = root.lastFetchMs
      root.checkAutoFetch()   // refresh the retry time shown in the header
    }
  }

  function applyRemoteLine(line) {
    var r = line.split("\t")
    if (r[0] === "BUSY") { root.fetchBusy = true; return }
    if (r.length < 2) return
    if (r[0] === "GH") {
      if (r[1] !== "ok") root.ghStatus = { state: r[1], reset: parseInt(r[2]) || 0, message: r[3] || "" }
      else if (root.ghStatus.state !== "missing-scope") root.ghStatus = { state: "ok", reset: 0, message: "" }
      return
    }
    if (r[0] === "AUTOFETCH") {
      root.autoStatus = { ok: r[1] === "ok", finish: Math.round(Date.now() / 1000), mode: root.fetchMode,
                          message: r[2] || "", next: parseInt(r[3]) || 0 }
      return
    }
    if (r[0] === "LOGIN" || r[0] === "NOTIF" || r[0] === "REVIEW" || r[0] === "MYPR" || r[0] === "ISSUE" || r[0] === "RUN" || r[0] === "SECTION") {
      root.inboxBuffer.push(r)
      return
    }
    if (r[0] === "INBOXDONE") {   // omagit-remote's own DONE carries a repo path instead
      root.inbox = Format.mergeInbox(root.inbox, Format.parseInbox(root.inboxBuffer.concat([r])), root.fetchMode === "auto")
      root.inboxBuffer = []
      root.inboxMessage = ""
      return
    }
    var path = r[1]
    var rs = root.remoteStatus[path] ? Object.assign({}, root.remoteStatus[path]) : {}
    var quiet = root.fetchMode === "auto"
    if (r[0] === "FETCH") {
      if (quiet && r[2] === "ERR") return
      rs.fetch = r[2]; rs.fetchMsg = r[3] || ""
      root.setMap("remoteStatus", path, rs)
    } else if (r[0] === "PR" && r.length >= 7) {
      var buf = root.prBuffer[path] || []
      buf.push({ number: parseInt(r[2]) || 0, title: r[3], url: r[4], ci: r[5], head: r[6] })
      root.prBuffer[path] = buf
    } else if (r[0] === "PRS") {
      if (quiet && r[2] === "ERR") return
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
    if (!/^https:\/\//.test(u)) return
    if (root.linkBehavior === "webapp") Quickshell.execDetached(["omarchy-launch-webapp", u])
    else if (!Qt.openUrlExternally(u)) Quickshell.execDetached(["xdg-open", u])
  }

  // ---- uninstall ---------------------------------------------------------------------
  property bool uninstallArmed: false
  Timer { id: disarmTimer; interval: 6000; onTriggered: root.uninstallArmed = false }
  function uninstallClicked() {
    if (!root.uninstallArmed) { root.uninstallArmed = true; disarmTimer.restart(); return }
    root.uninstallArmed = false
    if (watchProcess.running) watchProcess.signal(15)
    Quickshell.execDetached(["bash", "-c",
      'setsid nohup bash -c \'rm -rf "$HOME/.config/gumbledore.omagit"; omarchy plugin remove gumbledore.omagit --yes\' >/dev/null 2>&1 &'])
  }

  Component.onCompleted: {
    settingsBootstrap.running = true
    tabProcess.running = true
    inboxCacheProcess.running = true
  }
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
      blocked: root.currentView.textFocused
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.currentView.moveCursor(dy) }
      onActivateRequested: root.currentView.activate()
      onCloseRequested: { if (!root.currentView.handleEscape()) root.close() }
      onTabRequested: function(direction) { root.setTab(root.tab === "repos" ? "inbox" : "repos") }
      onTextKey: function(t, modifiers) {
        if (modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        if (t === "1") root.setTab("repos")
        else if (t === "2") root.setTab("inbox")
        else if (t === "r") root.refreshAll()
        else if (t === "f") root.fetchAll()
        else root.currentView.handleKey(t)
      }
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
          enabled: !root.fetching
          tooltipText: "git fetch + open PRs for every repo, and your GitHub inbox (f)"
          onClicked: root.fetchAll()
        }
        PanelActionButton {
          iconText: "\udb81\udc50"
          tooltipText: "Refresh (re-scan roots, re-read all repos) (r)"
          onClicked: root.refreshAll()
        }
        PanelActionButton {
          visible: root.tab === "repos"
          iconText: "\udb81\udc15"
          tooltipText: reposView.addFormVisible ? "Hide tracking" : "Add root / repo, manage tracking"
          onClicked: reposView.addFormVisible = !reposView.addFormVisible
        }
        PanelActionButton {
          iconText: "\udb81\udc93"
          tooltipText: "Open settings.json"
          onClicked: root.openSettings()
        }
      }

      Text {
        visible: Format.ghBanner(root.ghStatus) !== ""
        Layout.fillWidth: true
        text: Format.ghBanner(root.ghStatus)
        color: root.urgent
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // ---------------------------------------------------------------- tabs (Tab / 1 / 2)
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Button {
          text: "Repos" + (root.attentionCount > 0 ? " \u00b7 " + root.attentionCount : "")
          fontSize: Style.font.caption
          bordered: true
          selected: root.tab === "repos"
          tooltipText: "Repos (1)"
          onClicked: root.setTab("repos")
        }
        Button {
          text: "Inbox" + (root.inboxCount > 0 ? " \u00b7 " + root.inboxCount : "")
          fontSize: Style.font.caption
          bordered: true
          selected: root.tab === "inbox"
          tooltipText: "Notifications, review requests, your PRs and issues, Actions (2)"
          onClicked: root.setTab("inbox")
        }
        Item { Layout.fillWidth: true }
      }

      // ---------------------------------------------------------------- views (both stay instantiated)
      OmagitPanel.ReposView {
        id: reposView
        visible: root.tab === "repos"
        panel: root
        Layout.fillWidth: true
        Layout.fillHeight: true
      }

      OmagitPanel.InboxView {
        id: inboxView
        visible: root.tab === "inbox"
        panel: root
        Layout.fillWidth: true
        Layout.fillHeight: true
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
          tooltipText: "Removes ~/.config/gumbledore.omagit and the plugin"
          onClicked: root.uninstallClicked()
        }
      }
    }
  }
}
