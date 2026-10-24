import { bundleManager } from '@kit.AbilityKit';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject } from '../common/JsonUtil';
import { ShellInfo, cacheShellInfo, isAppActive, shellInfo } from '../common/RuntimeState';

/**
 * `@capacitor/app`.
 *
 * The event this exists for is `appStateChange`. The app hangs four behaviours off it
 * (frontend/src/lib/mobile.js, lib/health-sync.js, lib/media-store-fs.js): the reminder window is
 * re-scheduled whenever the shell comes back to the foreground, a paired server's state is pulled
 * at the same moment, and any media write still in flight is flushed to disk when it goes away.
 * Without the event the app still works, but it only notices a stale view when the user
 * navigates, and a media write can be lost if the process is killed while backgrounded.
 *
 * `addListener` is deliberately NOT one of the methods below, and that is the whole trick.
 * `@capacitor/core` routes every listener through the plugin *header*:
 *
 *     case 'addListener': return pluginHeader ? addListenerNative : addListener
 *
 * and on that path the JS callback the app passes is dropped on the floor — the native side is
 * expected to remember it and push the event back, which on Android/iOS is a real eval into the
 * page. Leave it out of the header and core instead falls through to the plugin's own JS
 * implementation, which for this plugin is `AppWeb` — and `AppWeb` adds a plain
 * `document.addEventListener('visibilitychange', ...)` that reports `appStateChange` from
 * `document.hidden`. ArkWeb is Chromium, so that is the honest mechanism on this platform; the
 * shell only has to keep `document.hidden` truthful (pages/Index.ets, bridge/Shim.ets).
 *
 * The rest of the methods are ordinary calls and stay bridged natively.
 */
export class AppPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'App';
  }

  getMethods(): string[] {
    // No addListener/removeListener/removeAllListeners — see the class comment.
    return ['getInfo', 'getState', 'getLaunchUrl', 'exitApp', 'minimizeApp'];
  }

  handle(call: PluginCall): void {
    switch (call.methodName) {
      case 'getInfo':
        call.resolve(this.info() as JsonObject);
        return;
      case 'getState':
        call.resolve({ 'isActive': isAppActive() } as JsonObject);
        return;
      case 'getLaunchUrl':
        call.resolve({} as JsonObject);
        return;
      case 'minimizeApp':
        call.resolve({} as JsonObject);
        return;
      case 'exitApp':
        try {
          this.getContext()?.terminateSelf();
        } catch (e) {
          // Already finishing; nothing to report.
        }
        call.resolve({} as JsonObject);
        return;
      default:
        return this.rejectUnknownMethod(call);
    }
  }

  /** Bundle facts, read once and kept — the values cannot change while the process lives. */
  private info(): ShellInfo {
    const cached: ShellInfo | null = shellInfo();
    if (cached !== null) {
      return cached;
    }
    let id: string = 'ch.duartesantos.opengym';
    let version: string = '1.4.0';
    let build: string = '1004000';
    try {
      const flag: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
      const info = bundleManager.getBundleInfoForSelfSync(flag);
      id = info.name;
      version = info.versionName;
      build = `${info.versionCode}`;
    } catch (e) {
      // Fall back to the values the manifest was generated with.
    }
    const out: ShellInfo = { id: id, name: 'openGym', version: version, build: build };
    cacheShellInfo(out);
    return out;
  }
}
