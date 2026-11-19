// Generates lib/ui/palette_generated.dart from the OpenTodo web design tokens
// (web/src/index.css, docs/design-system.md), so the Flutter client draws the
// same colours as the web app. Resolves every `--ot-*` colour token of the light
// block (`:root, [data-theme="light"]`) and the dark block
// (`:root[data-theme="dark"], [data-theme="dark"]`) with the default (emerald)
// accent: var() with fallbacks, oklch() literals and color-mix() in oklab/oklch,
// then converts OKLCH to sRGB (Björn Ottosson's OKLab matrices, as browsers do).
// Run from the project root:
//   node tool/sync_tokens.mjs [path-to-OpenTodo-checkout]
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const repo = resolve(process.argv[2] ?? '../OpenTodo')
const css = readFileSync(resolve(repo, 'web/src/index.css'), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '')

/** Declarations of every block whose selector line is exactly `selector`. */
function declsOf(selector) {
  const out = {}
  let from = 0
  let found = false
  for (;;) {
    const at = css.indexOf(`\n${selector} {`, from)
    if (at < 0) break
    found = true
    const open = css.indexOf('{', at)
    const close = css.indexOf('}', open)
    for (const decl of css.slice(open + 1, close).split(';')) {
      const m = decl.match(/^\s*(--[\w-]+)\s*:\s*([\s\S]+?)\s*$/)
      if (m) out[m[1]] = m[2]
    }
    from = close
  }
  if (!found) throw new Error(`block ${selector} not found in index.css`)
  return out
}

const rootVars = declsOf(':root')
const light = { ...rootVars, ...declsOf(':root, [data-theme="light"]') }
const dark = { ...light, ...declsOf(':root[data-theme="dark"], [data-theme="dark"]') }

/** Index of the paren closing the one at `open`. */
function closeOf(s, open) {
  let depth = 0
  for (let i = open; i < s.length; i++) {
    if (s[i] === '(') depth++
    else if (s[i] === ')' && --depth === 0) return i
  }
  throw new Error(`unbalanced: ${s}`)
}

/** Splits on commas outside parentheses. */
function topArgs(s) {
  const parts = []
  let depth = 0
  let start = 0
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '(') depth++
    else if (s[i] === ')') depth--
    else if (s[i] === ',' && depth === 0) { parts.push(s.slice(start, i).trim()); start = i + 1 }
  }
  parts.push(s.slice(start).trim())
  return parts
}

/** Substitutes var() references (with fallbacks) until none remain. */
function subst(value, vars, seen = []) {
  let i
  while ((i = value.indexOf('var(')) >= 0) {
    const end = closeOf(value, i + 3)
    const [name, ...rest] = topArgs(value.slice(i + 4, end))
    let rep
    if (vars[name] !== undefined) {
      if (seen.includes(name)) throw new Error(`cycle at ${name}`)
      rep = subst(vars[name], vars, [...seen, name])
    } else if (rest.length) {
      rep = subst(rest.join(','), vars, seen)
    } else {
      throw new Error(`undefined ${name}`)
    }
    value = value.slice(0, i) + rep + value.slice(end + 1)
  }
  return value
}

// Colours are { L, C, H (null = missing/powerless), A }.
function parseColor(s) {
  s = s.trim()
  if (s.startsWith('oklch(')) {
    const body = s.slice(6, closeOf(s, 5))
    const [lch, alpha] = body.split('/')
    const [L, C, H] = lch.trim().split(/\s+/).map(Number)
    return { L, C, H: C === 0 ? null : H, A: alpha === undefined ? 1 : Number(alpha) }
  }
  if (s.startsWith('color-mix(')) {
    const [space, a, b] = topArgs(s.slice(10, closeOf(s, 9)))
    const pa = /\s(\d+(?:\.\d+)?)%\s*$/.exec(a)
    const pb = /\s(\d+(?:\.\d+)?)%\s*$/.exec(b)
    const ca = parseColor(pa ? a.slice(0, pa.index) : a)
    const cb = parseColor(pb ? b.slice(0, pb.index) : b)
    let wa = pa ? Number(pa[1]) / 100 : pb ? 1 - Number(pb[1]) / 100 : 0.5
    if (ca.A !== 1 || cb.A !== 1) throw new Error(`alpha mix unsupported: ${s}`)
    if (space === 'in oklab') return mixOklab(ca, cb, wa)
    if (space === 'in oklch') return mixOklch(ca, cb, wa)
    throw new Error(`mix space ${space}`)
  }
  return null // not a colour (sizes, ratios)
}

function toLab({ L, C, H, A }) {
  const h = ((H ?? 0) * Math.PI) / 180
  return { L, a: C * Math.cos(h), b: C * Math.sin(h), A }
}

function fromLab({ L, a, b, A }) {
  const C = Math.hypot(a, b)
  let H = (Math.atan2(b, a) * 180) / Math.PI
  if (H < 0) H += 360
  return { L, C, H: C < 1e-9 ? null : H, A }
}

function mixOklab(x, y, w) {
  const a = toLab(x), b = toLab(y)
  return fromLab({ L: a.L * w + b.L * (1 - w), a: a.a * w + b.a * (1 - w), b: a.b * w + b.b * (1 - w), A: 1 })
}

function mixOklch(x, y, w) {
  let H
  if (x.H === null && y.H === null) H = null
  else if (x.H === null) H = y.H
  else if (y.H === null) H = x.H
  else {
    let d = y.H - x.H // shorter hue
    if (d > 180) d -= 360
    else if (d < -180) d += 360
    H = (x.H + d * (1 - w) + 360) % 360
  }
  return { L: x.L * w + y.L * (1 - w), C: x.C * w + y.C * (1 - w), H, A: 1 }
}

/** OKLCH → 0xAARRGGBB (sRGB, gamma-encoded, clamped). */
function toArgb(c) {
  const { L, a, b } = toLab(c)
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3
  const lin = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ]
  const enc = (v) => {
    v = Math.min(1, Math.max(0, v))
    const g = v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055
    return Math.round(g * 255)
  }
  const [r, g, bl] = lin.map(enc)
  const al = Math.round(c.A * 255)
  return '0x' + [al, r, g, bl].map((v) => v.toString(16).padStart(2, '0').toUpperCase()).join('')
}

const camel = (s) => s.replace(/-(\w)/g, (_, ch) => ch.toUpperCase())

function resolveTheme(vars) {
  const colors = {}
  const hues = {}
  for (const name of Object.keys(vars)) {
    if (!name.startsWith('--ot-') || name.startsWith('--ot-mix-')) continue
    const c = parseColor(subst(vars[name], vars))
    if (!c) continue
    const hm = /^--ot-hue-(\w+)-(solid|soft|text)$/.exec(name)
    const src = vars[name].replace(/\s+/g, ' ')
    if (hm) (hues[hm[1]] ??= {})[hm[2]] = { argb: toArgb(c), src }
    else colors[camel(name.slice(5))] = { argb: toArgb(c), src }
  }
  return { colors, hues }
}

const L = resolveTheme(light)
const D = resolveTheme(dark)
const names = Object.keys(L.colors).filter((n) => n in D.colors)
const hueNames = Object.keys(L.hues)

const instance = (t) => {
  const lines = names.map((n) => `    ${n}: Color(${t.colors[n].argb}), // ${t.colors[n].src}`)
  const hues = hueNames.map((h) => {
    const s = t.hues[h]
    return `      OtHue.${h}: OtHueSteps(\n        solid: Color(${s.solid.argb}),\n        soft: Color(${s.soft.argb}),\n        text: Color(${s.text.argb}),\n      ),`
  })
  return `${lines.join('\n')}\n    hues: {\n${hues.join('\n')}\n    },`
}

const dart = `// GENERATED by tool/sync_tokens.mjs from web/src/index.css — do not edit by hand.
// Colour tokens of the OpenTodo design system (docs/design-system.md), resolved
// from OKLCH to sRGB for the default (emerald) accent. Trailing comments carry
// the CSS source value of each token.
// ignore_for_file: lines_longer_than_80_chars

import 'dart:ui' show Color;

/// The 12 palette hues for projects and labels (\`data-hue\` on the web).
enum OtHue { ${hueNames.join(', ')} }

/// One palette hue: the solid mark, the soft tint and the text on the tint.
class OtHueSteps {
  const OtHueSteps({required this.solid, required this.soft, required this.text});

  final Color solid;
  final Color soft;
  final Color text;

  static OtHueSteps lerp(OtHueSteps a, OtHueSteps b, double t) => OtHueSteps(
        solid: Color.lerp(a.solid, b.solid, t)!,
        soft: Color.lerp(a.soft, b.soft, t)!,
        text: Color.lerp(a.text, b.text, t)!,
      );
}

/// Every semantic colour token of one theme (the \`--ot-*\` custom properties).
class OtPalette {
  const OtPalette({
${names.map((n) => `    required this.${n},`).join('\n')}
    required this.hues,
  });

${names.map((n) => `  final Color ${n};`).join('\n')}

  /// Palette hue steps, one entry per [OtHue].
  final Map<OtHue, OtHueSteps> hues;

  static const OtPalette light = OtPalette(
${instance(L)}
  );

  static const OtPalette dark = OtPalette(
${instance(D)}
  );

  static OtPalette lerp(OtPalette a, OtPalette b, double t) => OtPalette(
${names.map((n) => `        ${n}: Color.lerp(a.${n}, b.${n}, t)!,`).join('\n')}
        hues: {
          for (final h in OtHue.values) h: OtHueSteps.lerp(a.hues[h]!, b.hues[h]!, t),
        },
      );
}
`

mkdirSync('lib/ui', { recursive: true })
writeFileSync('lib/ui/palette_generated.dart', dart)
console.log(`lib/ui/palette_generated.dart: ${names.length} colours, ${hueNames.length} hues`)
