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

// "fetched 3 min ago" style stamp from a millisecond timestamp.
function ago(ms, nowMs) {
  if (!ms) return "never fetched"
  var s = Math.max(0, Math.round((nowMs - ms) / 1000))
  if (s < 60) return "fetched just now"
  var m = Math.round(s / 60)
  if (m < 60) return "fetched " + m + " min ago"
  var h = Math.round(m / 60)
  if (h < 48) return "fetched " + h + " h ago"
  return "fetched " + Math.round(h / 24) + " d ago"
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
