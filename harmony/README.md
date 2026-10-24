# openGym on HarmonyOS

The openGym phone app, ported to HarmonyOS NEXT (API 12). Everything the Android/iOS builds do
through Capacitor is done here by a small ArkTS shell that speaks Capacitor's own custom-platform
protocol to the *same, unmodified* web bundle.

The web app is the app. Nothing in `frontend/src` was rewritten for this platform — the handful of
files that changed did so to stop assuming Android, and each one says so in place:

| File | Change |
| --- | --- |
| `frontend/src/lib/mobile.js` | `isHarmonyOS()`, `isNativeShell()` beside the existing `isAndroid()` |
| `frontend/src/lib/rest-alert.js` | `isAndroid()` → `isNativeShell()` (the rest alert *is* bridged here) |
| `frontend/src/lib/system-bars.js` | same |
| `frontend/src/lib/scan.js` | live camera scan reports `unsupported`; photo import uses the in-page decoder |
| `frontend/src/lib/capacitor-fetch.js` | no `CapacitorHttp` bridge — falls back to `fetch` |
| `frontend/src/lib/back.js` | back press arrives as a DOM event from the shell |

## Why a shell rather than a port

openGym's mobile build (`VITE_MOBILE=1`) already isolates the platform behind Capacitor plugins,
and HarmonyOS NEXT cannot run an APK at all — it was forked from AOSP but the ART runtime is gone,
so a package has to be a `.hap` with an ArkTS/ArkUI entry. That leaves two honest choices: rewrite
the app in ArkTS, or keep the web app and give it an ArkWeb host that answers the same plugin
calls it already makes. This is the second one.

Nothing in the API surface is faked. `@capacitor/core` is pointed at a custom platform named
`harmony` before it evaluates, and every plugin call the app makes is answered by a real ArkTS
implementation over a JSON bridge (`ets/bridge/`).

## Build

Prerequisites: DevEco Studio 5.0 (API 12) with the HarmonyOS SDK, plus Node for the web bundle.

```
# 1. the mobile web build, exactly as the Android shell gets it
cd frontend
VITE_MOBILE=1 npx vite build

# 2. exercise stills and animations into dist (same script the mobile build runs;
#    needs catalogue/media, which is not in every checkout)
cd ..
node scripts/catalogue/stage-media.mjs frontend/dist

# 3. into the HAP
node harmony/scripts/sync-web.mjs
```

Step 3 replaces `harmony/entry/src/main/resources/rawfile/www/` wholesale and then verifies it with
the project's own `checkCopy` — the same guard that stops a stray web build (a service worker, the
passkey login screen) from being packaged into an app.

Then open `harmony/` in DevEco Studio, sign the HAP (Project Structure → Signing Configs →
automatic), and run on a device or emulator. `hdc install` works too, but a signature is required;
the debug signature DevEco generates is enough.

There is no `hvigorw` wrapper committed: DevEco generates it on first open. `oh-package.json5` has
no dependencies to fetch.

## How the shell is wired

```
entry/src/main/ets/
  entryability/EntryAbility.ets      UIAbility: foreground/background, back press, full-screen window
  pages/Index.ets                    the ArkWeb view, the injected shim, local media, permissions
  bridge/
    Shim.ets                         the JS injected on document start (see below)
    CapacitorBridge.ets              postMessage → plugin, and the answers back via runJavaScript
    PluginCall.ets                   one call: typed option access, resolve/reject once
    CapacitorPlugin.ets              plugin base class (id, methods, handle, context)
    PluginRegistry.ets               the plugin table published to the page as PluginHeaders
  plugins/                           eight plugins: Filesystem, App, LocalNotifications,
                                     RestAlert, SecureStorage, Share, SystemBars, Print
  common/
    JsonUtil.ets                     JSON/base64 without `any`
    RuntimeState.ets                 foreground state, bundle facts, page-ready flag
    MediaOrigin.ets                  the origin local files are published under
```

Three details in there are load-bearing, and each cost real debugging:

**The shim is injected on document start, not on page end.** `@capacitor/core` reads
`window.CapacitorCustomPlatform` into a module-level constant the moment the module is evaluated,
and the app imports it at the top of the bundle. Injected any later, the constant is `undefined`,
every plugin proxy takes the "unsupported platform" path, and the app reports its native
capabilities as missing.

**`PluginHeaders` entries are objects, not strings.** `@capacitor/core` matches methods with
`methods.find(m => prop === m.name)` and branches on `rtype`. A list of bare strings matches
nothing, and every call falls through to the plugin's web implementation.

**Listeners do not go through the shim at all.** With a plugin header present, core routes
`addListener` down the native path and *drops the JS callback* — the native side is expected to
hold it and push events back. No shim can capture it. So `AppPlugin` deliberately leaves
`addListener` out of its method list, and core falls back to the plugin's own JS implementation
(`AppWeb`), which listens on `document.visibilitychange`. The shell owns that value: the ability
tells the page when it is backgrounded, the shim replaces `document.hidden`/`visibilityState`, and
a real change re-dispatches the event. Four behaviours depend on it — the reminder window
re-scheduling, the rest timer's catch-up rule, the screen wake lock, and flushing media writes.

## What works, and what does not

**Works:** boot and persistence (localStorage plus the JSON mirror in the app sandbox), the whole
workout flow, workout-day reminders and nudges (agent reminders), the rest timer and its
end-of-rest alert via `reminderAgentManager`, vibration, secure storage for a paired server token,
export/share, print (through the share sheet), system bar styling, local media (photos and film
clips of custom exercises), camera and microphone capture in the WebView, free-text and photo
check-in codes, server pairing and sync, and the system back gesture.

**Degraded, deliberately:**

| Feature | What happens here |
| --- | --- |
| Rest alert notification buttons (pause, ±15 s, skip) | Not ported. The reminder framework has no equivalent of a notification's custom action buttons, so the alert fires but offers no controls. The plugin still accepts the arguments so the payload shape is unchanged. |
| Rest alert colours | Not ported — system notifications are not themed per app. |
| In-app update (`.apk` download + installer) | No equivalent: HarmonyOS installs a HAP from the store or `hdc`, never from inside the app. The Settings row never appears — it is already gated behind `isAndroid()`. |
| Health Connect | Not ported, and not portable. `isAndroid()` is false here, so the feature reports itself unsupported exactly as it does on iOS. |
| Backup folder picker (SAF) | Not ported. The sandbox has no user-visible folder to pick, so dated auto-backups land in the app's own `Documents` and the way out is `Share` — which is already what the Export row does. |
| Live camera barcode scan | ML Kit has no equivalent bridged. `scanCode()` throws `unsupported` and the view shows its "not available" message. Photo import still works (decoded in the page). |
| `CapacitorHttp` | Not bridged; `nativeFetch()` uses the page's own `fetch`. Same requests, no native cookie jar. |
| Print | Writes the HTML to the cache dir and opens the share sheet rather than the system print pipeline. |

**Not verified yet.** No part of this has been compiled or run on a device: the machine that wrote
it has no HarmonyOS SDK, and the project's own test suite runs on `happy-dom`/`linkedom` and never
touched a real WebView. The ArkTS was, however, read once more against the API 12 SDK surface after
the first draft, and four real defects were fixed in that pass: `JsonUtil.arr()` was being handed a
`PluginCall` where it wants a `JsonObject` (SharePlugin, RestAlertPlugin — both now use
`PluginCall.getArray`), a `Map.get()` result typed `Value | undefined` was annotated `Object`
(SecureStoragePlugin — now narrowed with `instanceof`), the photo/document pickers used the
constructors deprecated in API 12 (now context-bound), and `KEEP_BACKGROUND_RUNNING` was declared
for a background task nothing holds. `rawfile/www/` ships pre-built with this tree (243 MB, the
`VITE_MOBILE=1` bundle plus staged exercise media, verified by `checkCopy`), so step 1–3 of the
build section are only needed when the web bundle changes. The verify checklist below is the order
worth doing it in.

## Verify on a device

1. **It boots at all** — the app opens on the dashboard, not a blank screen. If blank, check the
   ArkWeb console through `hdc hilog | grep openGym`: a shim that did not load logs
   `the native bridge is not attached to this page`.
2. **State survives a restart** — log a workout, force-stop, reopen: the entry is there (that is
   `Filesystem` + `localStorage`).
3. **Background it and come back** — the reminder window is re-scheduled on the way back. Watch for
   the `appStateChange` path, which is the `document.hidden` override.
4. **A rest timer with the screen off** — start a rest, lock the phone, wait it out: the alert
   fires with sound and vibration.
5. **A photo on a custom exercise** — one that already has media, plus importing a new one. This is
   the `https://opengym.media/` interceptor; if images are blank, the request is being refused
   (check for the "refused a media request outside the sandbox" warning).
6. **Filming one in the WebView** — the camera and microphone prompts appear and are honoured.
7. **Back** — from a sub-screen it goes back, from the dashboard the first press arms
   "press back again to exit" and the second leaves.
8. **Pairing with a server** — the server needs no changes: its CSRF check already exempts a
   `Bearer` token (`api/server.js`), which is what the mobile shell sends.

## Notes for whoever picks this up

- `entry/src/main/resources/rawfile/www/` is build output. It is not in version control and
  `sync-web.mjs` replaces it entirely; do not edit it in place.
- The bundle name is `ch.duartesantos.opengym` and the version tracks `frontend/package.json`
  (`1.4.0`) — see `AppScope/app.json5`. Keep them in step when the app version moves.
- Signing is not committed. DevEco's automatic signing writes `build-profile.json5`, so expect a
  local diff there after the first build.
- `fileAccess(true)` is still on in `pages/Index.ets`. Media no longer needs it (that goes through
  `onInterceptRequest`), so it can be turned off once nothing else turns out to depend on it —
  worth doing, since it is the wider of the two doors.
