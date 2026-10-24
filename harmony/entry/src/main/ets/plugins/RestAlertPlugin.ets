import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { vibrator } from '@kit.SensorServiceKit';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject } from '../common/JsonUtil';

/**
 * `RestAlert` — the rest-timer alert.
 *
 * This is the one piece of the Android app that could not be dropped, and the reason is in the
 * web code it replaces: the in-page countdown is a `setInterval`, and a sleeping WebView freezes
 * it (frontend/src/lib/rest-alert.js). Android answers with an AlarmManager alarm plus a
 * foreground service and a notification channel — 1124 lines of Java across four files. The
 * HarmonyOS equivalent is the agent-reminder framework in its *timer* form: a countdown the
 * system owns, which fires with the screen off and the app not running, and which posts the
 * notification itself.
 *
 * What is deliberately not carried over, and why:
 *
 *   · The notification's own buttons (pause, ±15s, skip). Android builds a custom RemoteViews
 *     card and a broadcast receiver behind each button; the reminder framework posts a system
 *     notification whose actions are not programmable to that degree. The plugin still *accepts*
 *     `pause`/`resume`/`minus`/`plus`/`skip`, so the app's payload is unchanged, but no buttons
 *     are offered — the alert is the end of the rest, and the in-app controls remain the way to
 *     change it. `linkRestEvents` below is where a future version would wire real buttons.
 *
 *   · The custom accent colours. The system notification on HarmonyOS is not themed per app.
 *
 * The alarm buzz survives, through the Vibrator service: `buzz()` is what the app calls when
 * silent mode would otherwise swallow the end of a rest.
 */
const BUNDLE: string = 'ch.duartesantos.opengym';
const ABILITY: string = 'EntryAbility';
const REST_ALERT_ID: number = 42;

export class RestAlertPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'RestAlert';
  }

  getMethods(): string[] {
    return ['schedule', 'cancel', 'hold', 'buzz', 'setAccent',
      'addListener', 'removeListener', 'removeAllListeners'];
  }

  handle(call: PluginCall): void {
    this.dispatch(call).catch((e: Object) => call.rejectError(e));
  }

  private async dispatch(call: PluginCall): Promise<void> {
    switch (call.methodName) {
      case 'schedule': return this.schedule(call);
      case 'cancel': return this.cancel(call);
      case 'hold': return this.hold(call);
      case 'buzz': return this.buzz(call);
      case 'setAccent':
        // The system notification is not per-app themed; accepted so the app's call succeeds.
        call.resolve({} as JsonObject);
        return;
      case 'addListener':
      case 'removeListener':
      case 'removeAllListeners':
        // Accepted so the app's registration succeeds, but nothing arrives: the `rest` event
        // reports what the notification's own buttons did (pause, ±15s, skip), and the reminder
        // framework has no equivalent of those buttons, so there is nothing to report. On Android
        // those buttons mirror the in-app rest bar; here the app's own bar is the only control.
        // Declared rather than left unimplemented so that `addListener` cannot take the promise
        // down with it at startup (frontend/src/lib/rest-alert.js).
        call.resolve({} as JsonObject);
        return;
      default:
        return this.rejectUnknownMethod(call);
    }
  }

  private async schedule(call: PluginCall): Promise<void> {
    const at: number = call.getNumber('at', 0);
    const id: number = call.getNumber('id', REST_ALERT_ID);
    const now: number = Date.now();
    if (!(at > now)) {
      // The app guards this too ("at must be in the future"); belt and braces, since a reminder
      // in the past is rejected by the system and would otherwise surface as a mystery failure.
      call.reject('at must be in the future', 'EXPIRED');
      return;
    }

    // A rest is short. The framework takes whole seconds, and a sub-second remainder rounds up so
    // the alert is never early — ringing it before the set is over is worse than ringing late.
    const seconds: number = Math.max(1, Math.ceil((at - now) / 1000));
    const title: string = call.getString('title', 'openGym');
    const countdownTitle: string = call.getString('countdownTitle', '');
    const content: string = countdownTitle.length > 0 ? countdownTitle : 'Rest over';

    await this.cancelById(id);

    const request: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: seconds,
      title: title,
      content: content,
      notificationId: id,
      ringDuration: 5,
      snoozeTimes: 0,
      wantAgent: { pkgName: BUNDLE, abilityName: ABILITY }
    };
    try {
      await reminderAgentManager.publishReminder(request);
    } catch (e) {
      call.rejectError(e as Object, 'SCHEDULE_FAILED');
      return;
    }
    call.resolve({ 'scheduled': true } as JsonObject);
  }

  private async cancel(call: PluginCall): Promise<void> {
    const id: number = call.getNumber('id', REST_ALERT_ID);
    const removed: boolean = await this.cancelById(id);
    call.resolve({ 'cancelled': removed } as JsonObject);
  }

  /** The reminder framework has no cancel-by-notification-id, so the live list is scanned. */
  private async cancelById(id: number): Promise<boolean> {
    try {
      // `ReminderInfo` is what pairs a framework reminder id with the request it came from: a
      // `ReminderRequest` itself carries only the `notificationId` we chose, and a published
      // reminder hands back no id at all.
      const live: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      let removed: boolean = false;
      for (const info of live) {
        if (info.reminderReq.notificationId !== id) {
          continue;
        }
        try {
          await reminderAgentManager.cancelReminder(info.reminderId);
          removed = true;
        } catch (e) {
          // Already fired between the listing and the cancel.
        }
      }
      return removed;
    } catch (e) {
      return false;
    }
  }

  /**
   * The rest was paused in the app (#193). Android repaints the notification's countdown; here the
   * timer is simply called off — leaving it armed would ring at a moment the user has explicitly
   * held, which is the one outcome that behaviour must not produce. Resuming re-arms it.
   */
  private async hold(call: PluginCall): Promise<void> {
    const id: number = call.getNumber('id', REST_ALERT_ID);
    await this.cancelById(id);
    call.resolve({ 'held': true } as JsonObject);
  }

  /**
   * A buzz silent mode lets through (#375). Resolves true once it actually vibrated.
   *
   * `pattern` is `navigator.vibrate`'s shape — on, off, on, off… — which is also what the Android
   * plugin takes (RestAlertPlugin.java adds the leading zero Android's waveform wants). HarmonyOS
   * has no waveform call: a `VibrateEffect` is a single `{ type: 'time', duration }`, a preset or
   * a file. So the steps are played one after another, each awaited before the pause that follows
   * it, which reproduces the pattern rather than approximating it with one long buzz.
   *
   * `usage: 'alarm'` is the point of the whole thing: the system plays it in silent and
   * vibrate-only modes, the way the clock app's alarm does.
   */
  private async buzz(call: PluginCall): Promise<void> {
    const pattern: number[] = parsePattern(call.getArray('pattern'));
    if (pattern.length === 0) {
      call.resolve({ 'vibrated': false } as JsonObject);
      return;
    }
    try {
      const attribute: vibrator.VibrateAttribute = { usage: 'alarm' };
      let vibrated: boolean = false;
      for (let i = 0; i < pattern.length; i += 2) {
        const on: number = pattern[i];
        if (on <= 0) {
          continue;
        }
        const effect: vibrator.VibrateTime = { type: 'time', duration: on };
        // Resolves when the vibration has run its course, so the pattern's pauses land between
        // the steps rather than on top of them.
        await vibrator.startVibration(effect, attribute);
        vibrated = true;
        const off: number = i + 1 < pattern.length ? pattern[i + 1] : 0;
        if (off > 0) {
          await sleep(off);
        }
      }
      call.resolve({ 'vibrated': vibrated } as JsonObject);
    } catch (e) {
      // No vibrator, or the service refused: the caller falls back to the ordinary buzz.
      call.resolve({ 'vibrated': false } as JsonObject);
    }
  }
}

/**
 * `navigator.vibrate`'s pattern, cleaned up.
 *
 * The app filters and rounds it before it sends (lib/rest-alert.js — `buzzAsAlarm`), and Android's
 * own default when nothing usable arrives is a double buzz, which is what the app expects to hear.
 */
function parsePattern(raw: Object[]): number[] {
  const out: number[] = [];
  for (const step of raw) {
    const value: number = typeof step === 'number' ? step as number : Number.NaN;
    out.push(Number.isFinite(value) && value > 0 ? Math.round(value) : 0);
  }
  // Nothing usable: the same double buzz the Android plugin falls back to.
  return out.length === 0 ? [200, 100, 200] : out;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}
