import { MEDIA_ORIGIN } from '../common/MediaOrigin';
import { PluginHeader } from './PluginRegistry';

/**
 * The script injected into the WebView on document start.
 *
 * Why document start, and not onPageEnd: `@capacitor/core` resolves the custom platform into a
 * module-level constant the moment it is first evaluated —
 *
 *     const capCustomPlatform = win.CapacitorCustomPlatform;   // @capacitor/core, dist/index.js
 *
 * — and the app's bundle imports it at the top of the file. Inject any later and the constant
 * captures `undefined`, every plugin proxy falls through to the "unsupported platform" path, and
 * the app reports its native capabilities as missing.
 *
 * What `@capacitor/core` actually requires of this script, checked against the source of
 * core 7.6.8 rather than assumed:
 *
 *   · `CapacitorCustomPlatform.name` — the only field it reads; `plugins` is a leftover from an
 *     older contract and is never consulted (`getPlatform()` returns this name, and
 *     `capCustomPlatform !== null` is what enables the web-implementation fallback below).
 *   · `Capacitor.PluginHeaders` — `[{ name, methods: [{ name, rtype }] }]`. The shape matters:
 *     core does `methods.find(m => prop === m.name)` and then branches on `rtype`, so a bare
 *     string list matches nothing at all.
 *   · `Capacitor.nativePromise(plugin, method, options)` — one call per plugin method.
 *   · `Capacitor.nativeCallback` — only reachable for an `rtype` of 'callback', which nothing
 *     here declares; it is implemented as the same promise so that it cannot return the bare
 *     callback id into a `.then()` if that ever changes.
 *   · `Capacitor.convertFileSrc` — the media store reads it to build a URL for a local file.
 *
 * Listeners are deliberately NOT routed through here. `@capacitor/core` sends `addListener`
 * down the native path whenever a plugin header exists, and on that path the JS callback is
 * dropped — the native side is expected to hold it and push the event back. There is no way for
 * a shim to receive it. So the plugins that need listeners (`App`, for `appStateChange` and
 * `backButton`) keep `addListener` out of their header, and core falls back to the plugin's own
 * JS implementation instead; the two globals below are what that path needs from the shell.
 *
 * The bridge underneath is one method wide (`OpenGymNative.postMessage`); an answer never comes
 * back through it, it arrives later as a `__ogResolve`/`__ogReject` call, because the ArkWeb
 * proxy is synchronous and a plugin may legitimately take seconds to settle.
 */

const SHIM_HEAD = `
(function () {
  if (window.__openGymHarmony) { return; }
  window.__openGymHarmony = true;

  var PENDING = new Map();
  var SEQ = 0;

  function invoke(pluginId, methodName, options) {
    return new Promise(function (resolve, reject) {
      var id = 'og' + (++SEQ);
      PENDING.set(id, { resolve: resolve, reject: reject });
      var envelope = JSON.stringify({
        callbackId: id,
        pluginId: pluginId,
        methodName: methodName,
        options: (options === undefined || options === null) ? {} : options
      });
      try {
        var native = window.OpenGymNative;
        if (!native || typeof native.postMessage !== 'function') {
          throw new Error('the native bridge is not attached to this page');
        }
        native.postMessage(envelope);
      } catch (e) {
        PENDING.delete(id);
        reject(new Error('bridge unavailable: ' + (e && e.message ? e.message : String(e))));
      }
    });
  }

  window.__ogResolve = function (id, payloadJson) {
    var entry = PENDING.get(id);
    if (!entry) { return; }
    PENDING.delete(id);
    var data;
    try { data = JSON.parse(payloadJson); }
    catch (e) { data = {}; }
    if (data === null || typeof data !== 'object') { data = {}; }
    entry.resolve(data);
  };

  window.__ogReject = function (id, payloadJson) {
    var entry = PENDING.get(id);
    if (!entry) { return; }
    PENDING.delete(id);
    var message = 'native call failed';
    var code;
    try {
      var body = JSON.parse(payloadJson);
      if (body && typeof body.message === 'string') { message = body.message; }
      if (body && typeof body.code === 'string') { code = body.code; }
    } catch (e) { }
    var err = new Error(message);
    if (code) { err.code = code; }
    entry.reject(err);
  };

  /* ------------------------------------------------------------- page visibility --
     The app asks the page, not the shell, whether it is on screen:

         store/useUI.js       document.hidden drives the rest timer's catch-up rule
         views/Workout.jsx    'hidden' is what arms the native rest alert
         lib/wakelock.js      the screen wake lock is released on 'hidden'
         lib/mobile.js        the reminder window is re-scheduled on 'visible'

     ArkWeb is Chromium, so it usually reports this itself when the ability is backgrounded —
     but "usually" is not a contract to build four behaviours on, and the shell already knows
     exactly when it happens (EntryAbility.onForeground/onBackground). So the shell owns the
     value: the accessors are replaced once, and the page is told to re-read them.

     Only a real change dispatches. useUI.js treats a hide it did not cause as a rest that ran
     on while the phone was in a pocket, and a spurious event there would move the timer. */
  var APP_ACTIVE = true;
  var VISIBILITY_PATCHED = false;

  function patchVisibility() {
    if (VISIBILITY_PATCHED) { return; }
    VISIBILITY_PATCHED = true;
    var hidden = { configurable: true, get: function () { return APP_ACTIVE !== true; } };
    var state = { configurable: true, get: function () { return APP_ACTIVE === true ? 'visible' : 'hidden'; } };
    try {
      Object.defineProperty(Document.prototype, 'hidden', hidden);
      Object.defineProperty(Document.prototype, 'visibilityState', state);
    } catch (e) {
      // An engine that owns these on the instance instead: shadow them there.
      try {
        Object.defineProperty(document, 'hidden', hidden);
        Object.defineProperty(document, 'visibilityState', state);
      } catch (e2) {
        // Unforgeable. The native value stays, which is the behaviour this is a safety net for.
      }
    }
  }

  window.__ogAppActive = function (isActive) {
    var next = isActive === true;
    patchVisibility();
    if (next === APP_ACTIVE) { return; }
    APP_ACTIVE = next;
    try { document.dispatchEvent(new Event('visibilitychange')); } catch (e) { }
    try { window.dispatchEvent(new Event(next ? 'focus' : 'blur')); } catch (e) { }
  };

  /* ------------------------------------------------------------------- system back --
     The same problem as appStateChange: a 'backButton' listener registered through Capacitor
     cannot be reached from the shell (see the note at the top), and AppWeb has no DOM event for
     it. So the shell dispatches its own, and lib/back.js subscribes to it on this platform
     instead of asking for a native listener. The decision table behind it — close a sheet, walk
     history, press-again-to-exit — is untouched and still the only place that decides. */
  window.__ogBack = function (canGoBack) {
    try {
      document.dispatchEvent(new CustomEvent('opengym:back', { detail: { canGoBack: canGoBack === true } }));
    } catch (e) { }
  };

  /* --------------------------------------------------------------- local media files --
     A file on this device is published under a pretend https origin that
     pages/Index.ets intercepts and answers from the sandbox. It has to be an http(s) origin:
     the media store fetches the bytes before it displays anything, and fetch() refuses
     file://. See common/MediaOrigin.ets. */
  var MEDIA_ORIGIN = ${JSON.stringify(MEDIA_ORIGIN)};

  function mediaUrl(filePath) {
    var s = String(filePath);
    if (s.indexOf('file://') === 0) { s = s.slice(7); }
    else if (s.charAt(0) !== '/') { return s; }
    return MEDIA_ORIGIN + encodeURIComponent(s);
  }
`;

const SHIM_TAIL = `
  patchVisibility();

  window.CapacitorCustomPlatform = {
    // Read by @capacitor/core; the platform name also decides whether the web implementation of
    // a plugin is used as the fallback for anything the native side does not answer.
    name: 'harmony',
    plugins: {}
  };

  window.Capacitor = {
    platform: 'harmony',
    getPlatform: function () { return 'harmony'; },
    isNativePlatform: function () { return true; },
    isPluginAvailable: function (name) { return methodNames(name).length > 0; },
    getPluginHeader: function (name) {
      for (var i = 0; i < HEADERS.length; i++) {
        if (HEADERS[i].name === name) { return HEADERS[i]; }
      }
      return undefined;
    },
    PluginHeaders: HEADERS,
    nativePromise: function (pluginId, methodName, options) {
      return invoke(pluginId, methodName, options);
    },
    nativeCallback: function (pluginId, methodName, options) {
      // Nothing declares rtype 'callback', so this exists only so that a stray call settles
      // instead of handing a callback id to a caller that wants a promise.
      return invoke(pluginId, methodName, options);
    },
    convertFileSrc: mediaUrl,
    isSimulator: false,
    getServerUrl: function () { return 'http://localhost/'; }
  };
})();
`;

/**
 * Build the shim for the plugins registered so far.
 *
 * The header list is baked in as a literal rather than fetched over the bridge: it is read
 * synchronously by `@capacitor/core` at import time, before any promise could resolve.
 */
export function buildShim(headers: PluginHeader[]): string {
  const headerLiteral: string = JSON.stringify(headers);
  const middle: string = `\n  var HEADERS = ${headerLiteral};\n` +
    `  function methodNames(name) {\n` +
    `    for (var i = 0; i < HEADERS.length; i++) {\n` +
    `      if (HEADERS[i].name === name) { return HEADERS[i].methods; }\n` +
    `    }\n` +
    `    return [];\n` +
    `  }\n`;
  return SHIM_HEAD + middle + SHIM_TAIL;
}
