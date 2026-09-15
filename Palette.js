.pragma library

// Contribution-level colors, shared by the bar strip, the heatmap and the
// settings preview. "theme" mixes the theme accent (or the configured color)
// into the theme background; "github" uses GitHub's own greens, the dark or
// light set depending on how dark the theme background is.

var GITHUB_DARK = ["#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"]
var GITHUB_LIGHT = ["#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39"]

// Share of the ink (level 0) or base color (levels 1-4) mixed into the theme
// background. Mixing keeps cells opaque, so they read the same on a solid bar
// and on a transparent one over any wallpaper.
var THEME_MIX = [0.16, 0.34, 0.56, 0.78, 1.0]

function clampLevel(level) {
  var n = Math.round(Number(level) || 0)
  return Math.max(0, Math.min(4, n))
}

function isDark(color) {
  return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5
}

function mix(base, over, amount) {
  return Qt.rgba(base.r + (over.r - base.r) * amount,
                 base.g + (over.g - base.g) * amount,
                 base.b + (over.b - base.b) * amount, 1)
}

function levelColor(level, appearance, surface, ink, base) {
  var l = clampLevel(level)
  if (appearance === "github") return (isDark(surface) ? GITHUB_DARK : GITHUB_LIGHT)[l]
  return mix(surface, l === 0 ? ink : base, THEME_MIX[l])
}

// Same rule as the collector: a level is the number of lower bounds reached.
function levelFor(value, thresholds) {
  if (!(value > 0)) return 0
  var level = 0
  for (var i = 0; i < thresholds.length; i++) if (value >= thresholds[i]) level++
  return Math.min(4, level)
}
