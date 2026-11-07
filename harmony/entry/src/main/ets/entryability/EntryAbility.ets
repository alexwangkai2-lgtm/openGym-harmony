import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';

const DOMAIN = 0x0000;
const TAG = 'openGym';

/** Shared with pages/Index.ets — the foreground/background signal the app listens for. */
const APP_STATE_EVENT: string = 'og.appState';

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
   * Back press fallback — the real handler is `onBackPress()` on the `@Entry` component in
   * pages/Index.ets.
   *
   * This matters: `UIAbility.onBackPressed()`'s return value does NOT mean "I consumed the
   * press". Per the SDK, `true` means the ability is *moved to the background* (and kept alive),
   * `false` means it is *destroyed* — either way the user leaves the app. Only ArkUI's page-level
   * `onBackPress(): true` actually keeps the window on screen. This callback is reached only
   * before the page is ready, or if the page declines the press; in that case background the
   * ability rather than destroy it, so a relaunch restores the WebView and its state.
   */
  onBackPressed(): boolean {
    return true;
  }
}
