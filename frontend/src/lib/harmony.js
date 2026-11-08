// HarmonyOS shell detection lives in its own module on purpose. Many upstream tests mock
// ./mobile.js with a narrow export list, and a vi.mock throws when an undeclared export is
// read. Keeping these helpers here leaves those mocks untouched, while the shell still
// advertises itself through Capacitor's custom-platform hook
// (harmony/entry/src/main/ets/bridge/Shim.ets -> window.CapacitorCustomPlatform).
import { MOBILE } from './mobile.js'

/** 'android' | 'ios' | 'harmony' | 'web'. Never throws when Capacitor is unavailable. */
export async function shellPlatform() {
  if (!MOBILE) return 'web'
  try {
    const { Capacitor } = await import('@capacitor/core')
    return Capacitor.getPlatform()
  } catch (e) {
    return 'web'
  }
}

export async function isHarmonyOS() {
  return (await shellPlatform()) === 'harmony'
}

/** All three native shells bridge the rest alert (upstream 1.4.4 added iOS); the web does not. */
export async function isNativeShell() {
  const p = await shellPlatform()
  return p === 'android' || p === 'ios' || p === 'harmony'
}
