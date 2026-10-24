import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { isPageReady } from '../common/RuntimeState';

const DOMAIN = 0x0000;
const TAG = 'openGym';

/** Shared with pages/Index.ets — the foreground/background signal the app listens for. */
const APP_STATE_EVENT: string = 'og.appState';
/** Shared with pages/Index.ets — the system back press, forwarded for the page to interpret. */
const BACK_EVENT: string = 'og.backPress';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    // The bridge answers the WebView before the page runs; see plugins/ for the handlers.
    webview.WebviewController.initializeWebEngine();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate');

    // Full-screen layout: the app draws its own safe areas in CSS, and the phone build is
    // edge-to-edge on Android too (see frontend/src/lib/system-bars.js).
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      mainWindow.setWindowLayoutFullScreen(true).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', e.message);
      });
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'getMainWindow failed: %{public}s', e.message);
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
    // The page listens on the same eventHub. Pushed rather than polled because the app hangs two
    // behaviours off it: re-scheduling the reminder window, and pulling a paired account's state
    // (frontend/src/lib/mobile.js — onAppActive / initReminderSync).
    this.context.eventHub.emit(APP_STATE_EVENT, true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
    this.context.eventHub.emit(APP_STATE_EVENT, false);
  }

  /**
   * The system back gesture and the navigation bar's back button.
   *
   * Without this, back closes the app from wherever the user happens to be — the same problem the
   * Android build had before frontend/src/lib/back.js existed (`BridgeActivity` does not handle
   * back at all, so a swipe quit from anywhere and the app's own history was dead weight). The
   * page already knows what back should mean: close the top sheet, walk its own history, and on a
   * second press leave through `App.exitApp()`. So the press is forwarded and consumed, and the
   * page decides.
   *
   * Before the first page load there is no page to ask and nothing to walk back through, so the
   * press is left to the system — which is the behaviour the user expects from a still-blank app.
   */
  onBackPressed(): boolean {
    if (!isPageReady()) {
      return false;
    }
    hilog.info(DOMAIN, TAG, 'back press forwarded to the page');
    this.context.eventHub.emit(BACK_EVENT);
    return true;
  }
}
