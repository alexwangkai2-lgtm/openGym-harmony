import { window } from '@kit.ArkUI';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject, bool } from '../common/JsonUtil';

/**
 * `SystemBars` — the status-bar icon colour.
 *
 * The Android story this replaces: from Android 15 the bars draw over the page (edge to edge),
 * and on the light theme the clock and battery vanish against the app's #f2f2f7 background
 * (frontend/src/lib/system-bars.js). App.jsx calls this with every theme it resolves to.
 *
 * HarmonyOS draws the same way once `setWindowLayoutFullScreen(true)` is on — which EntryAbility
 * sets, so the app owns the whole surface — and the equivalent control is
 * `setWindowSystemBarProperties`: the *content* colour is what has to flip. The naming is
 * inverted from the Android plugin's `light` flag, so the mapping lives in one place here rather
 * than at every call site: `light: true` means "the page is light", which needs dark icons.
 *
 * Every failure is swallowed: an unavailable window API must leave the bars as they were, not
 * surface as an exception in App.jsx's render path.
 */
export class SystemBarsPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'SystemBars';
  }

  getMethods(): string[] {
    return ['setStyle', 'show', 'hide'];
  }

  handle(call: PluginCall): void {
    switch (call.methodName) {
      case 'setStyle':
        this.setStyle(call);
        return;
      case 'show':
      case 'hide':
        // The app never hides the bars; accepted so the proxy does not reject.
        call.resolve({} as JsonObject);
        return;
      default:
        this.rejectUnknownMethod(call);
    }
  }

  private setStyle(call: PluginCall): void {
    const ctx = this.getContext();
    if (ctx === null) {
      call.reject('no UIAbility context — the plugin was not attached');
      return;
    }
    const light: boolean = bool(call.getRawOptions(), 'light', false);

    window.getLastWindow(ctx).then((win: window.Window) => {
      const props: window.SystemBarProperties = {
        // A light page wants dark glyphs, and the reverse.
        statusBarContentColor: light ? '#000000' : '#ffffff',
        navigationBarContentColor: light ? '#000000' : '#ffffff'
      };
      return win.setWindowSystemBarProperties(props);
    }).then(() => {
      call.resolve({} as JsonObject);
    }).catch(() => {
      // An older build without the property, or no window yet: leave the bars alone.
      call.resolve({ 'applied': false } as JsonObject);
    });
  }
}
