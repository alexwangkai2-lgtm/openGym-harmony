import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
// Only the controller is imported: MixedMode, WebResourceResponse, FileSelectorMode and the
// FileSelector types are declared ambiently by the Web component itself (the ArkWeb d.ts declares
// them at the top level, not inside the `webview` namespace), which is how every ArkWeb sample
// refers to them.
import { webview } from '@kit.ArkWeb';
import { CapacitorBridge } from '../bridge/CapacitorBridge';
import { attachAll, pluginHeaders, registerPlugin } from '../bridge/PluginRegistry';
import { buildShim } from '../bridge/Shim';
import { mediaPathFrom, mimeForPath } from '../common/MediaOrigin';
import { isAppActive, setAppActive, setPageReady } from '../common/RuntimeState';
import { AppPlugin } from '../plugins/AppPlugin';
import { FilesystemPlugin } from '../plugins/FilesystemPlugin';
import { LocalNotificationsPlugin } from '../plugins/LocalNotificationsPlugin';
import { PrintPlugin } from '../plugins/PrintPlugin';
import { RestAlertPlugin } from '../plugins/RestAlertPlugin';
import { SecureStoragePlugin } from '../plugins/SecureStoragePlugin';
import { SharePlugin } from '../plugins/SharePlugin';
import { SystemBarsPlugin } from '../plugins/SystemBarsPlugin';

const DOMAIN = 0x0000;
const TAG = 'openGym';

/** Shared with entryability/EntryAbility.ets — foreground/background transitions. */
const APP_STATE_EVENT: string = 'og.appState';
/** Shared with entryability/EntryAbility.ets — the system back press, and nothing else. */
const BACK_EVENT: string = 'og.backPress';

/** The media permissions the app's own capture flow asks the WebView for. */
const CAPTURE_PERMISSIONS: Permissions[] = ['ohos.permission.CAMERA', 'ohos.permission.MICROPHONE'];

/**
 * How many files one picker may return.
 *
 * A photo picker session is interactive and the app ingests every result into its own store, so
 * this is a courtesy ceiling rather than a limit the app depends on: the largest import it offers
 * (a batch of workout photos) asks for "several".
 */
const MAX_PICK: number = 10;

/**
 * The single object the WebView can reach.
 *
 * Kept deliberately narrow: one method, a JSON string in, a status string out. The ArkWeb proxy
 * is synchronous, so nothing here may block — `bridge.postMessage` dispatches and returns, and
 * the plugin that handles the call answers later through `runJavaScript`.
 */
class NativeProxy {
  private readonly bridge: CapacitorBridge;

  constructor(bridge: CapacitorBridge) {
    this.bridge = bridge;
  }

  postMessage(message: string): string {
    return this.bridge.postMessage(message);
  }
}

/**
 * The app shell: one ArkWeb view showing the openGym bundle, plus the bridge behind it.
 *
 * The bundle is the *mobile* build (`VITE_MOBILE=1`), whose entry is `rawfile/www/index.html`.
 * Three properties are non-negotiable for it to run at all:
 *
 *   · `domStorageAccess(true)` — the store persists its whole state through `localStorage`
 *     (`gym_state_v1`); with it off the app boots into an empty profile every launch.
 *   · `fileAccess(true)` — kept so a `file://` URI handed back by the Filesystem plugin is still
 *     loadable directly. Media does not depend on it: the page fetches the bytes and Blink
 *     refuses `file://` in `fetch`, so those come through `onInterceptRequest` below instead.
 *   · the shim injected on document start — see bridge/Shim.ets for why it cannot wait for
 *     `onPageEnd`.
 *
 * `base: './'` is set in frontend/vite.config.js, so the bundle's asset URLs are relative and
 * resolve under `resource://rawfile/www/`. The router is a HashRouter (frontend/src/App.jsx), so
 * no server-side rewrite is needed either — the two together are what make loading straight from
 * rawfile viable at all.
 */
@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: CapacitorBridge = new CapacitorBridge();
  private proxy: NativeProxy = new NativeProxy(this.bridge);
  private shim: string = '';
  private wired: boolean = false;
  private abilityContext: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.abilityContext = ctx;

    // Plugins first: the shim advertises their method lists, so it must be built after they are
    // all in the registry, and it must be ready before the Web component is constructed.
    this.registerAll();
    attachAll(ctx);
    this.shim = buildShim(pluginHeaders());
    this.bridge.setController(this.controller);

    ctx.eventHub.on(APP_STATE_EVENT, (active: boolean) => {
      setAppActive(active);
      // The page owns `document.visibilityState` on this platform, and the app hangs four
      // behaviours off it: re-scheduling the reminder window, pulling a paired account's state,
      // the rest timer's catch-up rule, and flushing media writes to disk. See bridge/Shim.ets.
      this.bridge.notifyAppState(active);
    });

    ctx.eventHub.on(BACK_EVENT, () => {
      // The page decides what a back press means — a sheet closes, its own history walks back,
      // and only a second press leaves the app. `accessBackward()` is the WebView's own history,
      // which is what the app passes to its decision table as `canGoBack`.
      this.bridge.notifyBack(this.controller.accessBackward());
    });

    hilog.info(DOMAIN, TAG, 'shell ready, %{public}d plugin(s) bridged', pluginHeaders().length);
  }

  aboutToDisappear(): void {
    const ctx: common.UIAbilityContext | null = this.abilityContext;
    if (ctx !== null) {
      try {
        ctx.eventHub.off(APP_STATE_EVENT);
        ctx.eventHub.off(BACK_EVENT);
      } catch (e) {
        // Ability already gone.
      }
    }
  }

  /** Idempotent — `aboutToAppear` can run again after a configuration change. */
  private registerAll(): void {
    if (this.wired) {
      return;
    }
    this.wired = true;
    // Order is irrelevant; the registry is keyed by plugin id.
    registerPlugin(new AppPlugin());
    registerPlugin(new FilesystemPlugin());
    registerPlugin(new LocalNotificationsPlugin());
    registerPlugin(new RestAlertPlugin());
    registerPlugin(new SecureStoragePlugin());
    registerPlugin(new SharePlugin());
    registerPlugin(new SystemBarsPlugin());
    registerPlugin(new PrintPlugin());
  }

  /**
   * Answer a request for a local file — `https://opengym.media/<percent-encoded path>`.
   *
   * This is how the app sees its own media: the media store fetches the bytes for a photo or a
   * recorded clip and turns them into a blob URL before anything is displayed, and a `fetch` of a
   * `file://` URL is refused by Blink outright. A pretend host that the shell answers is the
   * smallest thing that satisfies both.
   *
   * Two guards, because the page is a lower trust boundary than the native side: the path must
   * decode cleanly and must land inside this app's own sandbox. Anything else returns null, which
   * hands the request back to ArkWeb and lets it fail as the unknown host it is.
   *
   * The whole file is returned in one piece. The media store reads a file the same way, so there
   * is no Range handling here — nothing in the app streams a local file.
   */
  private localMediaResponse(url: string): WebResourceResponse | null {
    const ctx: common.UIAbilityContext | null = this.abilityContext;
    if (ctx === null) {
      return null;
    }
    const full: string | null = mediaPathFrom(url);
    if (full === null) {
      return null;
    }
    if (full.includes('..')) {
      return null;
    }
    const insideSandbox: boolean = full.startsWith(ctx.filesDir) || full.startsWith(ctx.cacheDir);
    if (!insideSandbox) {
      hilog.warn(DOMAIN, TAG, 'refused a media request outside the sandbox');
      return null;
    }
    if (!fs.accessSync(full)) {
      hilog.warn(DOMAIN, TAG, 'media request for a missing file');
      return null;
    }

    let body: ArrayBuffer;
    try {
      const stat = fs.statSync(full);
      body = new ArrayBuffer(stat.size);
      const file = fs.openSync(full, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, body);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'media read failed');
      return null;
    }

    const mime: string = mimeForPath(full);
    const response = new WebResourceResponse();
    response.setResponseCode(200);
    response.setReasonMessage('OK');
    response.setResponseMimeType(mime);
    // Written inline rather than through a named array: the field names have to match the SDK's
    // own `Header` type exactly, and this way the compiler checks them against it.
    response.setResponseHeader([
      { headerKey: 'Content-Type', headerValue: mime },
      // The page runs on resource://rawfile, so this is a cross-origin fetch. Images and video
      // would load without it; `fetch` would not.
      { headerKey: 'Access-Control-Allow-Origin', headerValue: '*' },
      // One response per file, rebuilt on every launch — a stale cache would show the wrong
      // photo after a re-import.
      { headerKey: 'Cache-Control', headerValue: 'no-store' }
    ]);
    response.setResponseData(body);
    response.setResponseIsReady(true);
    return response;
  }

  /**
   * Answer an `<input type="file">` from the page.
   *
   * An ArkWeb view renders no browser chrome, so nothing opens a picker on its own — without this
   * the app's file inputs would simply do nothing. There are four of them, and they want two
   * different pickers: photos and film clips (a custom exercise's media, a progress photo, a
   * check-in code read out of a picture already on the phone) and documents (a plan file from a
   * friend, a backup archive, a CSV export from another tracker). A photo picker cannot reach a
   * `.json` in Downloads, and the file manager cannot show the album grid the app expects, so the
   * choice is made from what the input declared it accepts.
   *
   * The selection is answered either way. The page's `input` is waiting on it, and a picker the
   * user backed out of is an empty list — not silence.
   */
  private async pickFiles(accept: string[], multiple: boolean, result: FileSelectorResult): Promise<void> {
    try {
      const wantsMedia: boolean = accept.some((type: string): boolean =>
        type.startsWith('image/') || type.startsWith('video/'));
      const uris: string[] = wantsMedia
        ? await this.pickMedia(accept, multiple)
        : await this.pickDocument(multiple);
      result.handleFileList(uris);
    } catch (e) {
      // A cancelled picker rejects on some of these APIs; either way the page has to be told.
      hilog.error(DOMAIN, TAG, 'file selection returned nothing');
      result.handleFileList([]);
    }
  }

  /** The system photo picker, narrowed to what the input asked for. */
  private async pickMedia(accept: string[], multiple: boolean): Promise<string[]> {
    const ctx: common.UIAbilityContext | null = this.abilityContext;
    if (ctx === null) {
      return [];
    }
    const images: boolean = accept.some((type: string): boolean => type.startsWith('image/'));
    const videos: boolean = accept.some((type: string): boolean => type.startsWith('video/'));
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = (images && videos)
      ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE
      : (videos ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE
        : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE);
    options.maxSelectNumber = multiple ? MAX_PICK : 1;
    // The app re-encodes and stores what it is given; the untouched original is not wanted.
    options.isOriginalSupported = false;
    // The picker is handed the ability context: the no-argument constructor is deprecated since
    // API 12, and the context-bound one resolves the caller's window reliably.
    const picked = await new photoAccessHelper.PhotoViewPicker(ctx).select(options);
    return picked.photoUris;
  }

  /**
   * The file manager, for everything that is not a photo or a clip.
   *
   * The suffix filter covers what the app asks for today — `.json` for a plan, `.zip` for a
   * backup with media, `.csv`/`.xml` for an export. It is a convenience the picker applies on top
   * of the input's own `accept`, not a restriction this shell imposes.
   */
  private async pickDocument(multiple: boolean): Promise<string[]> {
    const ctx: common.UIAbilityContext | null = this.abilityContext;
    if (ctx === null) {
      return [];
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = multiple ? MAX_PICK : 1;
    options.fileSuffixFilters = ['.json', '.zip', '.csv', '.xml'];
    return await new picker.DocumentViewPicker(ctx).select(options);
  }

  /**
   * The app-level half of a WebView capture request.
   *
   * `event.request.grant()` only works for a permission the app itself holds, and CAMERA and
   * MICROPHONE are user-grant permissions — so the user is asked once, at the moment the app
   * first reaches for the camera, and the answer is what the WebView request is granted with.
   */
  private async ensureCapturePermissions(): Promise<boolean> {
    const ctx: common.UIAbilityContext | null = this.abilityContext;
    if (ctx === null) {
      return false;
    }
    const manager = abilityAccessCtrl.createAtManager();
    const token: number = ctx.applicationInfo.accessTokenId;
    const missing: Permissions[] = [];
    for (const permission of CAPTURE_PERMISSIONS) {
      if (manager.checkAccessTokenSync(token, permission) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        missing.push(permission);
      }
    }
    if (missing.length === 0) {
      return true;
    }
    try {
      const result = await manager.requestPermissionsFromUser(ctx, missing);
      for (const code of result.authResults) {
        if (code !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'capture permission request failed');
      return false;
    }
  }

  build() {
    Column() {
      Web({ src: $rawfile('www/index.html'), controller: this.controller })
        // localStorage: the app's primary store. Without it every launch is a fresh profile.
        .domStorageAccess(true)
        .fileAccess(true)
        .javaScriptAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .databaseAccess(true)
        .mixedMode(MixedMode.All)
        .zoomAccess(false)
        // The app owns its own safe areas in CSS and the window is already edge to edge.
        .width('100%')
        .height('100%')
        .backgroundColor('#0c0e12')
        .javaScriptProxy({
          object: this.proxy,
          name: 'OpenGymNative',
          methodList: ['postMessage'],
          controller: this.controller
        })
        // Document start, not page end — see bridge/Shim.ets for the failure this prevents.
        .runJavaScriptOnDocumentStart([{ script: this.shim, scriptRules: ['*'] }])
        // Local media, served out of the sandbox. Everything else is left alone.
        .onInterceptRequest((event) => {
          if (!event) {
            return null;
          }
          return this.localMediaResponse(event.request.getRequestUrl());
        })
        // <input type="file"> from the page. Returning true hands the selection to us: see
        // pickFiles below for which picker each input gets.
        .onShowFileSelector((event) => {
          if (!event) {
            return false;
          }
          const accept: string[] = event.fileSelector.getAcceptType();
          const multiple: boolean =
            event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
          this.pickFiles(accept, multiple, event.result);
          return true;
        })
        .onConsole((event) => {
          if (event) {
            hilog.info(DOMAIN, TAG, 'web: %{public}s', event.message.getMessage());
          }
          return false;
        })
        .onErrorReceive((event) => {
          if (event) {
            hilog.error(DOMAIN, TAG, 'load error: %{public}s',
              event.error.getErrorInfo());
          }
        })
        .onPermissionRequest((event) => {
          if (!event) {
            return;
          }
          // The app asks for the camera to photograph or film a custom exercise, and the
          // microphone to record one with sound. Anything else the page might ask for is refused
          // by not granting it.
          const resources: string[] = event.request.getAccessibleResource();
          const wanted: Permissions[] = [];
          for (const resource of resources) {
            for (const permission of CAPTURE_PERMISSIONS) {
              if (resource === permission) {
                wanted.push(permission);
              }
            }
          }
          if (wanted.length === 0) {
            event.request.deny();
            return;
          }
          this.ensureCapturePermissions().then((granted: boolean) => {
            if (granted) {
              event.request.grant(wanted);
            } else {
              event.request.deny();
            }
          }).catch(() => {
            event.request.deny();
          });
        })
        // The WebView's first paint is white and the app's background is near-black, so the
        // window colour above and this pair of logs are the only trace of the load.
        .onPageBegin(() => {
          hilog.info(DOMAIN, TAG, 'page begin');
        })
        .onPageEnd(() => {
          // From here a back press is the page's to interpret; before it, the system's.
          setPageReady(true);
          // A page that loaded while the app was already backgrounded (a restore, a reload)
          // must not be told it is on screen.
          this.bridge.notifyAppState(isAppActive());
          hilog.info(DOMAIN, TAG, 'page end');
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0c0e12')
  }
}
