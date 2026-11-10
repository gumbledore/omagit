.pragma library

// Presentation helpers shared by Panel.qml and RepoRow.qml. Pure functions.

function splitRecords(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    out.push(lines[i].split("\t"))
  }
  return out
}

// One-line banner for a gh status {state, reset (epoch s, 0 unknown)}; "" when healthy.
function ghBanner(status) {
  var st = status ? status.state : "ok"
  if (st === "missing") return "gh not found \u2014 install GitHub CLI to see PRs"
  if (st === "logged-out") return "gh is logged out \u2014 run `gh auth login`"
  if (st === "rate-limited") {
    var t = ""
    if (status.reset > 0) {
      var d = new Date(status.reset * 1000)
      t = " \u2014 retry after " + ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    }
    return "GitHub rate limit reached" + t
  }
  return ""
}

function hhmm(epoch) {
  var d = new Date(epoch * 1000)
  return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
}

// Header line for a failed background fetch {ok, finish, mode, next, message}; "" otherwise.
function autoFetchLine(a) {
  if (!a || a.ok || a.mode !== "auto" || !a.finish) return ""
  var s = "auto-fetch failed " + hhmm(a.finish)
  if (a.next > 0) s += " \u00b7 retry " + hhmm(a.next)
  return s
}

// "3 min ago" from a millisecond timestamp.
function since(ms, nowMs) {
  var s = Math.max(0, Math.round((nowMs - ms) / 1000))
  if (s < 60) return "just now"
  var m = Math.round(s / 60)
  if (m < 60) return m + " min ago"
  var h = Math.round(m / 60)
  if (h < 48) return h + " h ago"
  return Math.round(h / 24) + " d ago"
}

// "fetched 3 min ago" style stamp from a millisecond timestamp.
function ago(ms, nowMs) {
  return ms ? "fetched " + since(ms, nowMs) : "never fetched"
}

// ---- inbox ---------------------------------------------------------------
// inbox = { login, fetchedAt (ms), fromCache, sections: { name: {status, message, items} } }

function emptyInbox() { return { login: "", fetchedAt: 0, fromCache: false, sections: {} } }

function _inboxSection(inbox, name) {
  if (!inbox.sections[name]) inbox.sections[name] = { status: "OK", message: "", items: [] }
  return inbox.sections[name]
}

// Parse omagit-inbox records (cache file or live stream): an array of lines
// or field arrays. Sections only appear when a record mentions them.
function parseInbox(recs) {
  var inbox = emptyInbox()
  for (var i = 0; i < recs.length; i++) {
    var r = typeof recs[i] === "string" ? recs[i].split("\t") : recs[i]
    if (r[0] === "CACHE") {
      inbox.login = r[1] || ""; inbox.fetchedAt = (parseInt(r[2]) || 0) * 1000; inbox.fromCache = true
    } else if (r[0] === "LOGIN") {
      inbox.login = r[1] || ""
    } else if (r[0] === "INBOXDONE") {
      inbox.fetchedAt = (parseInt(r[1]) || 0) * 1000
    } else if (r[0] === "REVIEW" && r.length >= 8) {
      _inboxSection(inbox, "reviews").items.push({
        kind: "review", repo: r[1], number: parseInt(r[2]) || 0, title: r[3], url: r[4],
        author: r[5], ci: "none", updatedAt: r[6], localPath: r[7], draft: false })
    } else if (r[0] === "MYPR" && r.length >= 9) {
      _inboxSection(inbox, "prs").items.push({
        kind: "pr", repo: r[1], number: parseInt(r[2]) || 0, title: r[3], url: r[4],
        author: "", ci: r[5], updatedAt: r[6], localPath: r[7], draft: r[8] === "1" })
    } else if (r[0] === "SECTION" && r.length >= 3) {
      var sec = _inboxSection(inbox, r[1])
      sec.status = r[2]; sec.message = r[3] || ""
    }
  }
  return inbox
}

// Fold a completed live fetch into the inbox on screen. A section that did not
// come back OK keeps its previous items (same account only); `quiet` (auto-fetch)
// also keeps its previous status so failures stay out of sight.
function mergeInbox(prev, next, quiet) {
  var same = !prev.login || !next.login || prev.login.toLowerCase() === next.login.toLowerCase()
  var out = { login: next.login || prev.login, fetchedAt: prev.fetchedAt, fromCache: prev.fromCache, sections: {} }
  var names = Object.keys(prev.sections).concat(Object.keys(next.sections))
  var anyOk = false
  for (var i = 0; i < names.length; i++) {
    var n = names[i]
    if (out.sections[n]) continue
    var p = same ? prev.sections[n] : undefined, x = next.sections[n]
    if (!x) { if (p) out.sections[n] = p; continue }
    if (x.status === "OK") { out.sections[n] = x; anyOk = true; continue }
    var keep = p ? p.items : []
    out.sections[n] = quiet && p ? p : { status: x.status, message: x.message, items: keep }
  }
  if (anyOk) { out.fetchedAt = next.fetchedAt; out.fromCache = false }
  return out
}

function inboxCaption(inbox, nowMs) {
  if (!inbox || !inbox.fetchedAt) return ""
  return (inbox.login ? inbox.login + " \u00b7 " : "") + (inbox.fromCache ? "cached " : "updated ") + since(inbox.fetchedAt, nowMs)
}

// git's "%cr" is verbose ("3 minutes ago"); shorten for a dense row.
function shortAge(rel) {
  var r = String(rel || "")
  if (r === "") return ""
  var m = r.match(/^(\d+)\s+(\w+)/)
  if (!m) return r
  var n = m[1], unit = m[2]
  var map = { second: "s", seconds: "s", minute: "m", minutes: "m", hour: "h", hours: "h",
              day: "d", days: "d", week: "w", weeks: "w", month: "mo", months: "mo", year: "y", years: "y" }
  return n + (map[unit] || unit)
}

function needsAttention(st) {
  if (!st || st.error) return false
  return st.dirty > 0 || st.ahead > 0 || st.behind > 0
}

function ciColor(ci, accent, urgent, muted) {
  if (ci === "failing") return urgent
  if (ci === "pending") return "#d9a24a"
  if (ci === "passing") return accent
  return muted
}

function isoDate() {
  var d = new Date()
  var m = d.getMonth() + 1, day = d.getDate()
  return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day
}

function isMain(branch) { return branch === "main" || branch === "master" }
