.pragma library

// Pure helpers over the collector's `history` block, used by the panel.

function isList(value) {
  return value !== null && typeof value === "object" && typeof value.length === "number"
}

function repoEntry(day, repo) {
  var repos = day && isList(day.repos) ? day.repos : []
  for (var i = 0; i < repos.length; i++) if (repos[i] && repos[i].name === repo) return repos[i]
  return null
}

// Commits on a day, across every repository or for just `repo`.
function dayCommits(day, repo) {
  if (!day) return 0
  if (!repo) return Number(day.commits) || 0
  var entry = repoEntry(day, repo)
  return entry ? Number(entry.commits) || 0 : 0
}

// What a day is shaded by: commits, or lines added plus deleted.
function dayValue(day, metric, repo) {
  if (metric !== "lines") return dayCommits(day, repo)
  var source = repo ? repoEntry(day, repo) : day
  return source ? (Number(source.added) || 0) + (Number(source.deleted) || 0) : 0
}

// Runs of days with at least one commit, over days ordered oldest to newest
// and ending today. A run that ended yesterday is still current: today is not
// over yet.
function streaks(counts) {
  var longest = 0
  var run = 0
  for (var i = 0; i < counts.length; i++) {
    run = counts[i] > 0 ? run + 1 : 0
    if (run > longest) longest = run
  }
  var end = counts.length - 1
  if (end >= 0 && !(counts[end] > 0)) end--
  var current = 0
  for (var j = end; j >= 0 && counts[j] > 0; j--) current++
  return { current: current, longest: longest }
}

function periodLabel(weeks) {
  if (weeks >= 52) return "year"
  if (weeks >= 26) return "6 months"
  if (weeks >= 13) return "3 months"
  return weeks + " weeks"
}

// Flat rows for the commit list: a heading row per day, newest first, then
// that day's commits. Optionally narrowed to one repository and/or one day.
function groupedRows(commits, repo, date) {
  var rows = []
  var lastDate = null
  for (var i = 0; i < commits.length; i++) {
    var c = commits[i]
    if (!c || (repo && c.repo !== repo) || (date && c.date !== date)) continue
    if (c.date !== lastDate) {
      rows.push({ kind: "day", date: c.date })
      lastDate = c.date
    }
    rows.push({ kind: "commit", commit: c })
  }
  return rows
}
