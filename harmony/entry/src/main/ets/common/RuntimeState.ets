/**
 * Facts about the running shell that a plugin needs but does not own.
 *
 * The foreground state lives here rather than inside AppPlugin because two callers care about
 * it: AppPlugin answers `getState()`, and the rest-timer plugin needs to know whether the app
 * is on screen (an alert that fires while the app is open should not also post a notification).
 */

let appActive: boolean = true;

/** Called by the page as the shell reports foreground/background. */
export function setAppActive(active: boolean): void {
  appActive = active;
}

export function isAppActive(): boolean {
  return appActive;
}

/** The bundle facts App.getInfo() reports. Resolved once, lazily. */
export interface ShellInfo {
  id: string;
  name: string;
  version: string;
  build: string;
}
let cachedInfo: ShellInfo | null = null;

export function cacheShellInfo(info: ShellInfo): void {
  cachedInfo = info;
}

export function shellInfo(): ShellInfo | null {
  return cachedInfo;
}

/**
 * Whether the page has finished loading at least once.
 *
 * The system back press is consumed by the ability so that the page can decide what it means,
 * but before the first page load there is no page to ask and nothing to walk back through —
 * consuming the press then would leave the user with a back button that does nothing at all.
 * Until this is true, back falls through to the system and closes the app, which is exactly what
 * it did before the app was on screen.
 */
let ready: boolean = false;

export function setPageReady(value: boolean): void {
  ready = value;
}

export function isPageReady(): boolean {
  return ready;
}
