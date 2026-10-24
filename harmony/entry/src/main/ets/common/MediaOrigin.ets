/**
 * How the page gets at a file that lives on this device.
 *
 * "Just hand it the `file://` path" does not work here. The app does not point `<img src>` or
 * `<video src>` at a filesystem path — the media store fetches the bytes and turns them into a
 * blob URL, because that is the only shape iOS has ever accepted:
 *
 *     lib/media-store-fs.js   fetch(convertFileSrc(uri)).then(r => r.blob())
 *     lib/media-store.js      objectURL.createObjectURL(new Blob([blob], { type }))
 *
 * and Chromium's `fetch` refuses a `file://` URL outright ("URL scheme must be http or https").
 * ArkWeb is Chromium, so the page needs an http(s) origin — one that answers with the file's own
 * bytes. That is what `onInterceptRequest` in pages/Index.ets does: nothing is listening on this
 * host, and nothing leaves the device.
 *
 * The host is checked before the (percent-encoded) absolute path, and the interceptor refuses
 * anything that does not resolve inside the app's own sandbox — the page is a lower trust
 * boundary than the native side, and this is one of the two places it hands over a path.
 */

/** The pretend origin every local file is published under. */
export const MEDIA_ORIGIN: string = 'https://opengym.media/';

/**
 * `file:///data/storage/el2/base/files/Library/ab12.jpg`
 *   → `https://opengym.media/%2Fdata%2Fstorage%2Fel2%2Fbase%2Ffiles%2FLibrary%2Fab12.jpg`
 *
 * The path is encoded as a single component so that neither ArkWeb's URL normalisation nor a
 * `..` inside it can change where the request lands. Anything that is not a `file://` URI is
 * left exactly as it was, so a caller passing an already-web URL does not get it mangled.
 */
export function mediaUrlFor(fileUri: string): string {
  let path: string = fileUri;
  if (path.startsWith('file://')) {
    path = path.slice(7);
  } else if (!path.startsWith('/')) {
    // Not a filesystem URI (a remote URL, a data: URI): nothing to rewrite.
    return fileUri;
  }
  // file:///x → "/x"; a bare "/x" stays "/x".
  return MEDIA_ORIGIN + encodeURIComponent(path);
}

/** The absolute path a request for `MEDIA_ORIGIN + <encoded>` names, or null for anything else. */
export function mediaPathFrom(url: string): string | null {
  if (!url.startsWith(MEDIA_ORIGIN)) {
    return null;
  }
  const encoded: string = url.slice(MEDIA_ORIGIN.length);
  // A query or fragment the media element appended is not part of the path.
  const cut: number = encoded.search(/[?#]/);
  const bare: string = cut === -1 ? encoded : encoded.slice(0, cut);
  if (bare.length === 0) {
    return null;
  }
  try {
    return decodeURIComponent(bare);
  } catch (e) {
    // A malformed escape is a bad request, not a reason to fall back to the raw text.
    return null;
  }
}

/** Enough of a content type for Blink to pick the right decoder. */
export function mimeForPath(path: string): string {
  const dot: number = path.lastIndexOf('.');
  const ext: string = dot === -1 ? '' : path.slice(dot + 1).toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'avif':
      return 'image/avif';
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'json':
      return 'application/json';
    case 'html':
    case 'htm':
      return 'text/html';
    default:
      // The media store keeps a playable extension per mime; anything else is served as bytes.
      return 'application/octet-stream';
  }
}
