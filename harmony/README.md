# openGym on HarmonyOS

The openGym phone app, ported to HarmonyOS NEXT (API 12). Everything the Android/iOS builds do
through Capacitor is done here by a small ArkTS shell that speaks Capacitor's own custom-platform
protocol to the *same, unmodified* web bundle.

The web app is the app. Nothing in `frontend/src` was rewritten for this platform — the handful of
files that changed did so to stop assuming Android, and each one says so in place:

| File | Change |
| --- | --- |
| `frontend/src/lib/harmony.js` | **new** — `isHarmonyOS()` / `isNativeShell()` off `Capacitor.getPlatform()`. Kept out of `mobile.js` because dozens of upstream tests mock that module with a narrow export list. |
| `frontend/src/lib/mobile.js` | upstream's `nativePlatform()` stays `'android' \| 'ios' \| null` (it also drives iOS-only branches); HarmonyOS is detected separately |
| `frontend/src/lib/rest-alert.js` | `nativePlatform()` → `isNativeShell()` (the rest alert *is* bridged here) |
| `frontend/src/lib/system-bars.js` | a `platform === 'harmony'` branch alongside Android/iOS |
| `frontend/src/lib/scan.js` | `webScanner()` returns true on HarmonyOS; live camera scan reports `unsupported` |
| `frontend/src/lib/capacitor-fetch.js` | no `CapacitorHttp` bridge — falls back to `fetch` |
| `frontend/src/lib/back.js` | back press arrives as a DOM event from the shell; upstream's `pathname`/tour logic is kept |

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
automatic), and run on a device or emulator. `hdc install` works too, but a signature is required.

**Signing differs between an emulator and a retail phone.** A retail HarmonyOS device only trusts
Huawei's CA, so it needs a HarmonyOS debug signature from automatic signing
(`devecocli auth login` → `devecocli signature generate`, or the GUI's Signing Configs). The
account must be real-name verified in AppGallery Connect, and the generated `.p7b` is bound to the
bundle name plus the device UDID (`hdc -t <serial> shell "bm get --udid"`). An OpenHarmony image /
the DevEco emulator also accepts the SDK's own `OpenHarmony.p12` chain signed offline with
`hap-sign-tool.jar`; that same HAP is rejected on a retail phone with
`9568257 fail to verify pkcs7 file` — the device log reads
`HapVerify: it do not come from trusted root, issuer: ... OpenHarmony Application Root CA`.
Emulator-only development never needs a Huawei account, and there is no device switch that
disables the certificate-chain check.

There is no `hvigorw` wrapper committed: DevEco generates it on first open. `oh-package.json5` has
no dependencies to fetch. `hvigor/hvigor-config.json5` keeps `execution.daemon` off: a CLI build
started from an automation shell loses its daemon to SIGHUP and then waits forever on the broken
process. Turn it back on for interactive builds, where the daemon speeds up incremental compiles.

## How the shell is wired

```
entry/src/main/ets/
  entryability/EntryAbility.ets      UIAbility: foreground/background, full-screen window
  pages/Index.ets                    ArkWeb view, injected shim, local origins, permissions, back press
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
    MediaOrigin.ets                  the origin sandbox media is published under
    AppOrigin.ets                    the https origin the whole web bundle is published under
```

Four details in there are load-bearing, and each cost real debugging:

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

**The page runs on `https://opengym.app/`, not on `resource://`.** Vite emits
`<script type="module" crossorigin>` and `<link rel="stylesheet" crossorigin>`; those are fetched
in CORS mode, and a `resource://rawfile` document has an opaque `null` origin. ArkWeb refuses CORS
for that scheme ("Cross origin requests are only supported for protocol schemes: ... http, https"),
so the HTML and its icon loaded and every script and stylesheet was silently blocked — a permanent
blank screen. This is the documented ArkWeb local-resource limitation; the fix is Huawei's own
recommended one: a custom HTTPS origin whose requests `onInterceptRequest` answers out of
`rawfile/www/`. It also gives the document a real origin, so `localStorage` works and module
scripts are same-origin. `AppOrigin.ets` maps the URL back to a rawfile path and refuses anything
that could climb out of `www/`.

**Back belongs to `Index.onBackPress()`, not `UIAbility.onBackPressed()`.** The ability-level
callback's return value does not mean "consumed": per the SDK, `true` moves the UIAbility to the
background and `false` destroys it — either way the app disappears. Only the page-level
`@Entry` callback returning `true` keeps the window on screen. That is where the press is now
forwarded to `lib/back.js`.

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

**Verified on an emulator (2026-11-07).** `devecocli build` compiles the whole tree against the
real API 12 SDK (`BUILD SUCCESSFUL`, 33 tasks, only warnings). The unsigned HAP was signed with
the SDK's local OpenHarmony debug certificate and installed on the Mate 90 Pro emulator
(HarmonyOS 7.0.0 / API 26, `127.0.0.1:5555`); `install bundle successfully`, `start ability
successfully`. Boot, the onboarding choice, the dashboard, the starter-plan sheet, Settings and
the reminder toggle all render and respond; force-stopping and relaunching keeps the state
(`localStorage`); opening the reminder switch raised the real system notification permission
dialog, which proves the Capacitor bridge reaches the ArkTS plugins; from a sub-screen back walks
the page history, and on the dashboard a first back arms "press again to exit" and a second one
leaves. No CORS errors, no JS console errors, no crash logs.

**Retail-device install (2026-11-08, pending a Huawei-issued profile).** The v1.4.4 bundle rebuilt
cleanly (`BUILD SUCCESSFUL`, 33 tasks) and the HAP was checked for `opengym-flavor=mobile`, the
chunk carrying `opengym:back`, and `1.4.4 / 1004004` in `module.json`. On a `VOL-AL00` the
OpenHarmony-signed HAP was refused with `9568257`; device time matched the host and the profile
validity covered it, so the untrusted root above is the whole cause. `devecocli signature generate`
then declined the account as not real-name verified. Nothing in the app needs changing: once a
Huawei-issued certificate and profile exist, `hap-sign-tool.jar sign-app` can re-sign the same
unsigned HAP without another full build.

Getting there exposed three defects that static review had missed, all fixed below:

1. **Blank screen** — `resource://` cannot serve CORS-fetched module scripts. Fixed with the
   `https://opengym.app/` origin described above.
2. **Back quit the app on the first press** — the handler was on `UIAbility.onBackPressed()`,
   which cannot keep the window open. Moved to `Index.onBackPress()`.
3. **Back then did nothing at all** — the shim dispatched `opengym:back` on `document` while
   `lib/back.js` listens on `window`; a non-bubbling `CustomEvent` never reached it. Now
   dispatched on `window`.

Earlier, a read-through against the API 12 SDK surface had already fixed four compile-level
defects: `JsonUtil.arr()` being handed a `PluginCall` (SharePlugin, RestAlertPlugin — now
`PluginCall.getArray`), a `Map.get()` result typed `Object` (SecureStoragePlugin — now narrowed
with `instanceof`), the API 12 picker constructors, and an unused
`KEEP_BACKGROUND_RUNNING` declaration. `rawfile/www/` ships pre-built with this tree (243 MB,
the `VITE_MOBILE=1` bundle plus staged exercise media, verified by `checkCopy`), so steps 1–3 of
the build section are only needed when the web bundle changes.

Still not exercised on a device: the screen-off rest alert firing, custom-exercise media through
`https://opengym.media/`, camera/microphone capture inside the WebView, and pairing with a server.
Those need a longer interactive session or real media; the checklist below is the order to do it
in.

## Verify on a device

Items 1, 2 and 7 were exercised on the emulator — see the status above. The rest still needs a
real interactive session or real media.

1. **It boots at all** — the app opens on the dashboard, not a blank screen. If blank, check the
   ArkWeb console through `devecocli log --keyword CONSOLE`: `Access to script ... blocked by CORS
   policy` means the page is back on `resource://` instead of `https://opengym.app/`, and a shim
   that did not load logs `the native bridge is not attached to this page`.
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

## Upstream sync (2026-11-08)

The web app now tracks upstream `DuarteSantos8/openGym` `main` at `8fb98b1` (**v1.4.4**). This
fork started from a standalone 1.4.0 snapshot rather than a git fork, so the update was applied
as a three-way merge against upstream v1.4.0: 2699 upstream-only changes taken verbatim, 29
deleted paths removed, and the 14 files both sides had touched re-based by re-applying the
HarmonyOS adaptations on top of the new upstream text. The 263 MB exercise-media catalogue stays
out of the repository and is staged into the HAP at build time. `AppScope/app.json5` now reports
1.4.4 to match `frontend/package.json`.

**Capacitor 7 to 8.** Upstream 1.4.4 moved `@capacitor/core` to 8.5.3 and the plugins to 8.x. The
bridge contract the shim depends on did not change: `CapacitorCustomPlatform` is still read into a
module-level constant at document start, `getPlatform()` still returns `capCustomPlatform.name`,
`PluginHeaders.methods` is still `{ name, rtype }` with `rtype === 'promise'` routing to
`nativePromise`, and core still picks `addListenerNative` only when a plugin header exists.
`@capacitor/app`'s `AppWeb` still reads `document.hidden` and listens on `visibilitychange`. So
`Shim.ets`, `PluginRegistry.ets` and `AppPlugin.ets` needed no changes.

Upstream also introduced `nativePlatform()` (`'android' | 'ios' | null`). It deliberately keeps
returning `null` on HarmonyOS, because upstream uses it for iOS-only branches (Live Activities,
watch sync, voice). `lib/harmony.js` detects the shell instead, and `back.js`, `rest-alert.js`,
`scan.js` and `system-bars.js` opt into the shared plugin set explicitly. Upstream's iOS-only
features take their web paths here, consistent with the degraded table above. Upstream 1.4.4 also
added an iOS rest alert, so `isNativeShell()` now includes iOS alongside Android and HarmonyOS.

After the sync the mobile bundle rebuilds with `VITE_MOBILE=1` and passes `checkCopy`; 102 unit
tests across the seven affected suites pass; and the ArkTS tree is byte-for-byte the one verified
on 2026-11-07 (only web bundle content, the app version and documentation changed).

## Notes for whoever picks this up

- `entry/src/main/resources/rawfile/www/` is build output. It is not in version control and
  `sync-web.mjs` replaces it entirely; do not edit it in place.
- The bundle name is `ch.duartesantos.opengym` and the version tracks `frontend/package.json`
  (`1.4.4` after the upstream sync) — see `AppScope/app.json5`. Keep them in step when the app
  version moves.
- Signing is not committed. DevEco's automatic signing writes `build-profile.json5`, so expect a
  local diff there after the first build; the `.p12` / `.cer` / `.p7b` material is ignored by
  `.gitignore`. Real-device signing additionally needs a real-name-verified Huawei developer
  account — see the signing note at the top of this file.
- `fileAccess(true)` is still on in `pages/Index.ets`. Media no longer needs it (that goes through
  `onInterceptRequest`), so it can be turned off once nothing else turns out to depend on it —
  worth doing, since it is the wider of the two doors.
