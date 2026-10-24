// Android system back (the gesture and the hardware/nav button are the same event).
//
// Capacitor's BridgeActivity does not handle back at all — without a JS listener the
// activity simply finishes, so a back swipe quit the app from anywhere, whatever the
// WebView history said. That made the sheet history entries from #63 dead weight in the
// packaged app: they only ever worked in a browser tab, where the browser walks history
// itself.
//
// Once a `backButton` listener exists, the plugin stops falling through to finish() —
// back can then ONLY leave the app through App.exitApp(), which is why the last step is
// an explicit press-again-to-exit rather than a silent no-op.
//
// HarmonyOS has the same problem and the same answer, but not the same wiring: the shell consumes
// the system back press and dispatches a DOM event instead of a plugin event, because a
// Capacitor `addListener` cannot be reached from a native shell that has no way to hold the JS
// callback (see harmony/entry/src/main/ets/bridge/Shim.ets). Everything below the subscription —
// the decision table, the press-again-to-exit toast, App.exitApp() as the only way out — is
// shared by both platforms.
import { MOBILE, isHarmonyOS } from './mobile.js'
import { useUI } from '../store/useUI.js'
import { t } from './i18n.js'

/** What the HarmonyOS shell dispatches for a system back press. Mirrored in bridge/Shim.ets. */
export const HARMONY_BACK_EVENT = 'opengym:back'

// How long a first back press stays armed as "press again to exit" (the toast shows 2.2s).
export const EXIT_WINDOW = 2000

// What a back press means, given what is on screen. Pure, so the table below is testable.
export function decideBack({ top, canGoBack, exitArmed }) {
  if (top) return top.locked ? 'ignore' : 'sheet'   // a locked sheet swallows back on purpose
  if (canGoBack) return 'history'                   // a page/tab we pushed ourselves
  return exitArmed ? 'exit' : 'arm-exit'
}

export function makeBackHandler({ getSheets, closeSheet, toast, goBack, exit, now = Date.now }) {
  let armedAt = -Infinity
  return (ev = {}) => {
    const sheets = getSheets()
    const action = decideBack({
      top: sheets[sheets.length - 1],
      canGoBack: !!ev.canGoBack,
      exitArmed: now() - armedAt < EXIT_WINDOW,
    })
    if (action !== 'arm-exit') armedAt = -Infinity
    if (action === 'sheet') closeSheet(sheets[sheets.length - 1].id)
    else if (action === 'history') goBack()
    else if (action === 'arm-exit') { armedAt = now(); toast(t('Press back again to exit')) }
    else if (action === 'exit') exit()
    return action
  }
}

// Registers the listener for the native shell. No-op in web builds, where the browser
// (or the PWA shell) walks history on its own and there is no plugin to talk to.
export async function initBackButton() {
  if (!MOBILE) return () => {}
  let App
  try {
    ({ App } = await import('@capacitor/app'))
  } catch (e) {
    return () => {}   // no plugin (older install): leave back to the default behaviour
  }
  const handler = makeBackHandler({
    getSheets: () => useUI.getState().sheets,
    closeSheet: id => useUI.getState().closeSheet(id),
    toast: msg => useUI.getState().toast(msg),
    goBack: () => window.history.back(),
    exit: () => App.exitApp(),
  })
  if (await isHarmonyOS()) return listenForShellBack(handler)
  try {
    const sub = await App.addListener('backButton', handler)
    return () => sub.remove()
  } catch (e) {
    return () => {}   // the shell has no back listener: leave back to the default behaviour
  }
}

// The shell's own back press. `canGoBack` is the WebView's history, the same figure the Android
// plugin reports, so `decideBack` sees what it sees there.
function listenForShellBack(handler) {
  const onBack = ev => handler({ canGoBack: !!(ev && ev.detail && ev.detail.canGoBack) })
  window.addEventListener(HARMONY_BACK_EVENT, onBack)
  return () => window.removeEventListener(HARMONY_BACK_EVENT, onBack)
}
