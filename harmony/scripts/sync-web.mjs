#!/usr/bin/env node
/* Put the mobile web build into the HAP's rawfile folder.
 *
 * The HarmonyOS shell serves the bundle straight out of the package:
 *
 *     Web({ src: $rawfile('www/index.html') })        entry/src/main/ets/pages/Index.ets
 *
 * so `entry/src/main/resources/rawfile/www/` has to hold exactly what `frontend/dist` holds. Two
 * things make that work without a server, and both are the app's own choices rather than anything
 * this script does: `base: './'` in frontend/vite.config.js keeps every asset URL relative, and
 * the router is a HashRouter, so no deep link needs a rewrite.
 *
 * This is the third copy of the mobile bundle after android/ and ios/ (a Capacitor shell is the
 * same shape), and it is checked the same way — `checkCopy` is the project's own guard against a
 * web build having run into dist/ last, which would otherwise ship a service worker and the
 * passkey login screen inside the app.
 *
 * Usage:  node harmony/scripts/sync-web.mjs [dist dir]
 *         (default: frontend/dist, resolved from this file's location)
 */
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkCopy } from '../../frontend/scripts/check-mobile-bundle.mjs'

const HARMONY = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const REPO = resolve(HARMONY, '..')
const SRC = resolve(process.argv[2] || join(REPO, 'frontend', 'dist'))
const DEST = join(HARMONY, 'entry', 'src', 'main', 'resources', 'rawfile', 'www')

const BUILD_STEPS = [
  'cd frontend && VITE_MOBILE=1 npx vite build',
  'node scripts/catalogue/stage-media.mjs frontend/dist',
  'node harmony/scripts/sync-web.mjs',
]

const die = (message, steps = []) => {
  console.error(`✗ ${message}`)
  for (const step of steps) console.error(`    ${step}`)
  process.exit(1)
}

if (!existsSync(SRC)) {
  die(`${relative(REPO, SRC)} does not exist — build the mobile bundle first:`, BUILD_STEPS)
}

// The media is staged into dist by the mobile build, from a catalogue that is not part of every
// checkout (scripts/catalogue/stage-media.mjs). Without it the app still runs; the exercise
// animations just come up empty.
if (!existsSync(join(SRC, 'exercise-media')) && existsSync(join(REPO, 'catalogue', 'media'))) {
  console.warn('! dist has no exercise-media — run the staging step too:')
  console.warn(`    ${BUILD_STEPS[1]}`)
}

// A clean replace, not a merge: a chunk left behind by an earlier build is a chunk the WebView
// can still ask for, and a stale file served out of a HAP is invisible until it is wrong.
rmSync(DEST, { recursive: true, force: true })
mkdirSync(DEST, { recursive: true })
cpSync(SRC, DEST, { recursive: true })

const problems = checkCopy(DEST)
if (problems.length) {
  for (const problem of problems) console.error(`✗ ${problem.replace(DEST, relative(REPO, DEST))}`)
  console.error('  the bundle in rawfile/www is not the mobile build; rebuild before syncing.')
  process.exit(1)
}

const walk = dir => readdirSync(dir, { withFileTypes: true })
  .reduce((total, entry) => total + (entry.isDirectory()
    ? walk(join(dir, entry.name))
    : statSync(join(dir, entry.name)).size), 0)
const mb = walk(DEST) / 1048576

console.log(`✓ ${relative(REPO, SRC)} → ${relative(REPO, DEST)}  (${mb.toFixed(1)} MB)`)
console.log('  next: open harmony/ in DevEco Studio, sign the HAP, run on a device.')
