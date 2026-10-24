// The native app: the status bar and the navigation bar draw on top of the page (edge to edge),
// white unless the native side is told the page is light. On the light theme the clock and
// the battery all but vanished on #f2f2f7. App.jsx calls this with every theme it resolves to; the
// plugin flips the icons dark on light and back — SystemBarsPlugin.java on Android,
// SystemBarsPlugin.ets on HarmonyOS, where the same edge-to-edge layout applies.
import { isNativeShell } from './mobile.js'

// Registered once, and kept inside an object: a Capacitor plugin proxy answers `then` with a native
// call that never settles, so a promise resolved with the bare proxy would hang (the Coach hang, #42).
let pluginP = null
const barsPlugin = () => pluginP || (pluginP = (async () => {
  if (!(await isNativeShell())) return null
  const { registerPlugin } = await import('@capacitor/core')
  return { SystemBars: registerPlugin('SystemBars') }
})().catch(() => null))

let last = null
export async function setSystemBarsLight(light) {
  light = !!light
  if (last === light) return
  last = light
  try {
    const p = await barsPlugin()
    if (p) await p.SystemBars.setStyle({ light })
  } catch {
    // An older APK without the plugin: the bars stay as they were.
  }
}
