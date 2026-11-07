/**
 * The origin the WebView actually runs the bundle under.
 *
 * Loading `index.html` straight from `$rawfile` looks like the obvious choice, and it is wrong:
 * Vite emits `<script type="module" crossorigin>` for every entry chunk plus
 * `<link rel="stylesheet" crossorigin>`. Those are always fetched in CORS mode. A
 * `resource://rawfile/...` document has an opaque ("null") origin, and Chromium refuses CORS
 * requests for that scheme outright ("Cross origin requests are only supported for protocol
 * schemes: ... data, http, https"). The result is an app whose HTML loads, whose icon loads, and
 * whose JS and CSS never run — a permanently blank screen.
 *
 * So the shell publishes the whole `www/` tree under a pretend HTTPS origin and answers every
 * request for it from `onInterceptRequest` in pages/Index.ets. Nothing is listening on this host
 * and nothing leaves the device. HTTPS matters: it is one of the schemes Chromium allows CORS on,
 * and it gives the document a real origin so `localStorage` (the app's whole state store) works
 * and module scripts are same-origin.
 *
 * This is the same trick `MEDIA_ORIGIN` in MediaOrigin.ets already uses for sandbox files; the
 * two hosts are kept separate because one maps to rawfile resources and the other to absolute
 * paths inside the app sandbox.
 */

export const APP_ORIGIN: string = 'https://opengym.app/';

/** The URL handed to the Web component. */
export const APP_ENTRY_URL: string = APP_ORIGIN + 'index.html';

/**
 * `https://opengym.app/assets/index-abc123.js`
 *   → `www/assets/index-abc123.js`  (a resourceManager rawfile path)
 *
 * Returns null for anything off the app origin, for malformed escapes, and for anything that
 * could climb out of `www/`. The page is a lower trust boundary than the native side: a URL that
 * fails these checks is answered with 404, never with a file outside the bundle.
 */
export function appRawFilePathFrom(url: string): string | null {
  if (!url.startsWith(APP_ORIGIN)) {
    return null;
  }
  let path: string = url.slice(APP_ORIGIN.length);
  // A query or fragment (cache busters on assets, the HashRouter's fragment) is not a path.
  const cut: number = path.search(/[?#]/);
  if (cut !== -1) {
    path = path.slice(0, cut);
  }
  if (path.length === 0) {
    path = 'index.html';
  }
  try {
    path = decodeURIComponent(path);
  } catch (e) {
    return null;
  }
  if (path.startsWith('/') || path.includes('..') || path.includes('\\') || path.includes(':')) {
    return null;
  }
  return 'www/' + path;
}
