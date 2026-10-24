import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject, num, str } from '../common/JsonUtil';

/**
 * `@capacitor/local-notifications`, over `@kit.BackgroundTasksKit`.
 *
 * Why the agent-reminder framework and not `notificationManager.publish` directly: the app's
 * reminders are *calendar* events — "this date, at this time, if no workout is logged" — scheduled
 * up to 60 days ahead (frontend/src/lib/mobile.js REMINDER_WINDOW_DAYS). `publish` shows a
 * notification now; a JavaScript timer that fires it later dies with the WebView when the phone
 * sleeps. `reminderAgentManager` is the OS service that fires while the app is not running, which
 * is the only thing that makes the reminder real.
 *
 * Two consequences worth knowing before changing this file:
 *
 *   · The JS id is carried in `notificationId`. `cancelReminder` takes the agent's own reminderId,
 *     which is not the id the app knows, and the mapping does not survive a process restart — so
 *     cancelling looks the reminder up by the id the app supplied, through `getValidReminders()`.
 *     That is also why an id must be unique across the whole app: the rest-timer uses 42, the
 *     reminders 1000+, the nudges 2000+ (frontend/src/lib/mobile.js).
 *
 *   · The system caps how many reminders one app may hold (30 on current builds). The reminder
 *     window asks for up to 60, so the tail is dropped and reported rather than silently failing,
 *     and the app re-schedules the whole window after every workout anyway, which keeps the near
 *     days populated.
 */
const BUNDLE: string = 'ch.duartesantos.opengym';
const ABILITY: string = 'EntryAbility';

/** The most reminders the system will hold for one app. Extra ones are dropped, nearest first. */
const MAX_REMINDERS: number = 30;

/** Read a Capacitor `schedule.at`, which reaches us as an ISO string after JSON serialisation. */
function parseWhen(schedule: Object | undefined): Date | null {
  if (schedule === undefined || schedule === null || typeof schedule !== 'object') {
    return null;
  }
  const at: Object = (schedule as JsonObject)['at'];
  if (at === undefined || at === null) {
    return null;
  }
  let when: Date | null = null;
  if (typeof at === 'string') {
    when = new Date(at as string);
  } else if (typeof at === 'number') {
    when = new Date(at as number);
  }
  if (when === null || Number.isNaN(when.getTime())) {
    return null;
  }
  return when;
}

export class LocalNotificationsPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'LocalNotifications';
  }

  getMethods(): string[] {
    return ['schedule', 'cancel', 'getPending', 'getDeliveredNotifications',
      'removeDeliveredNotifications', 'removeAllDeliveredNotifications',
      'checkPermissions', 'requestPermissions', 'addListener', 'removeListener', 'removeAllListeners',
      'createChannel', 'deleteChannel', 'listChannels', 'areEnabled'];
  }

  handle(call: PluginCall): void {
    this.dispatch(call).catch((e: Object) => call.rejectError(e));
  }

  private async dispatch(call: PluginCall): Promise<void> {
    switch (call.methodName) {
      case 'schedule': return this.schedule(call);
      case 'cancel': return this.cancel(call);
      case 'getPending': return this.getPending(call);
      case 'checkPermissions': return this.checkPermissions(call);
      case 'requestPermissions': return this.requestPermissions(call);
      case 'areEnabled': return this.areEnabled(call);
      case 'addListener':
      case 'removeListener':
      case 'removeAllListeners':
      case 'createChannel':
      case 'deleteChannel':
      case 'listChannels':
        // Channels are an Android concept; reminder slots are chosen by the system here. The
        // listeners are accepted for the same reason as in RestAlertPlugin — this app does not
        // subscribe to a notification event, but a registration that throws at startup would be a
        // poor way to find that out.
        call.resolve(call.methodName === 'listChannels' ? { 'channels': [] } as JsonObject : {} as JsonObject);
        return;
      case 'getDeliveredNotifications':
        call.resolve({ 'notifications': [] } as JsonObject);
        return;
      case 'removeDeliveredNotifications':
      case 'removeAllDeliveredNotifications':
        call.resolve({} as JsonObject);
        return;
      default:
        return this.rejectUnknownMethod(call);
    }
  }

  private async schedule(call: PluginCall): Promise<void> {
    const items: Object[] = call.getArray('notifications');
    if (items.length === 0) {
      call.resolve({} as JsonObject);
      return;
    }

    // Nearest first, so a capped list keeps the days that are actually about to happen.
    const dated: DatedRequest[] = [];
    const now: number = Date.now();
    for (const raw of items) {
      if (raw === undefined || raw === null || typeof raw !== 'object') {
        continue;
      }
      const item: JsonObject = raw as JsonObject;
      const when: Date | null = parseWhen(item['schedule']);
      if (when === null || when.getTime() <= now) {
        continue;
      }
      dated.push({ at: when, id: num(item, 'id', 0), title: str(item, 'title', 'openGym'), body: str(item, 'body', '') });
    }
    dated.sort((a: DatedRequest, b: DatedRequest): number => a.at.getTime() - b.at.getTime());

    const accepted: DatedRequest[] = dated.slice(0, MAX_REMINDERS);
    const dropped: number = dated.length - accepted.length;

    let added: number = 0;
    for (const item of accepted) {
      const request: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: item.at.getFullYear(),
          month: item.at.getMonth() + 1,
          day: item.at.getDate(),
          hour: item.at.getHours(),
          minute: item.at.getMinutes(),
          second: 0
        },
        title: item.title,
        content: item.body,
        notificationId: item.id,
        ringDuration: 5,
        snoozeTimes: 0,
        wantAgent: { pkgName: BUNDLE, abilityName: ABILITY }
      };
      try {
        await reminderAgentManager.publishReminder(request);
        added++;
      } catch (e) {
        // Quota or a rejected date. The rest still go in; the app re-schedules on every change.
      }
    }

    const payload: JsonObject = { 'scheduled': added } as JsonObject;
    if (dropped > 0) {
      payload['dropped'] = dropped;
    }
    call.resolve(payload);
  }

  private async cancel(call: PluginCall): Promise<void> {
    const items: Object[] = call.getArray('notifications');
    const wanted: number[] = [];
    for (const raw of items) {
      if (raw === undefined || raw === null || typeof raw !== 'object') {
        continue;
      }
      wanted.push(num(raw as JsonObject, 'id', -1));
    }
    if (wanted.length === 0) {
      call.resolve({} as JsonObject);
      return;
    }

    let removed: number = 0;
    try {
      // Two facts about the reminder framework shape this loop. A published reminder does not
      // carry `notificationId` back to you, and a `ReminderRequest` has no `reminderId` at all —
      // only `ReminderInfo` pairs a framework id with the request that produced it. So the live
      // list is the only way to find ours again.
      const live: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      for (const info of live) {
        const notifId: number = info.reminderReq.notificationId === undefined ? -1 : info.reminderReq.notificationId;
        if (!wanted.includes(notifId)) {
          continue;
        }
        try {
          await reminderAgentManager.cancelReminder(info.reminderId);
          removed++;
        } catch (e) {
          // Already fired or already cancelled.
        }
      }
    } catch (e) {
      call.rejectError(e as Object);
      return;
    }
    call.resolve({ 'cancelled': removed } as JsonObject);
  }

  private async getPending(call: PluginCall): Promise<void> {
    const out: JsonObject[] = [];
    try {
      const live: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      for (const info of live) {
        const notifId: number = info.reminderReq.notificationId === undefined ? 0 : info.reminderReq.notificationId;
        out.push({ 'id': notifId } as JsonObject);
      }
    } catch (e) {
      // Reported as empty rather than failing the call: nothing depends on the count.
    }
    call.resolve({ 'notifications': out } as JsonObject);
  }

  private async checkPermissions(call: PluginCall): Promise<void> {
    let granted: boolean = false;
    try {
      granted = await notificationManager.isNotificationEnabled();
    } catch (e) {
      granted = false;
    }
    // The app only ever asks for `display`; anything else reported would be noise.
    call.resolve({ 'display': granted ? 'granted' : 'denied' } as JsonObject);
  }

  private async requestPermissions(call: PluginCall): Promise<void> {
    const ctx = this.getContext();
    if (ctx === null) {
      call.reject('no UIAbility context — the plugin was not attached');
      return;
    }
    let granted: boolean = false;
    try {
      granted = await notificationManager.requestEnableNotification(ctx);
    } catch (e) {
      granted = false;
    }
    call.resolve({ 'display': granted ? 'granted' : 'denied' } as JsonObject);
  }

  private async areEnabled(call: PluginCall): Promise<void> {
    let granted: boolean = false;
    try {
      granted = await notificationManager.isNotificationEnabled();
    } catch (e) {
      granted = false;
    }
    call.resolve({ 'value': granted } as JsonObject);
  }
}

/** One parsed `schedule()` entry, kept together so the sort cannot drift from its payload. */
interface DatedRequest {
  at: Date;
  id: number;
  title: string;
  body: string;
}
