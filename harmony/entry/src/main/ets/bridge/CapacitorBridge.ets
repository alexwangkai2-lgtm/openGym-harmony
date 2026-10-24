import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { PluginCall, ReplyFn } from './PluginCall';
import { pluginFor } from './PluginRegistry';
import { JsonObject, obj, parseObject, str } from '../common/JsonUtil';

const DOMAIN = 0x0000;
const TAG = 'openGymBridge';

/**
 * The native half of the bridge.
 *
 * The WebView reaches it through one injected object, `window.OpenGymNative`, with a single
 * method: `postMessage(envelope)`. That call is synchronous by contract (ArkWeb's proxy is), so
 * the dispatcher returns as soon as the plugin has been *started*; the answer travels back
 * separately, through `runJavaScript`, which is why nothing here may assume the page is still
 * alive by the time a plugin settles.
 *
 * The envelope is JSON rather than positional arguments because the methods differ in arity and
 * a single string keeps the proxy surface one method wide.
 */

interface Envelope {
  callbackId: string;
  pluginId: string;
  methodName: string;
}

export class CapacitorBridge {
  private controller: webview.WebviewController | null = null;
  private readonly replyFn: ReplyFn;

  constructor() {
    this.replyFn = (callbackId: string, ok: boolean, payloadJson: string): void => {
      this.reply(callbackId, ok, payloadJson);
    };
  }

  /** Wired once the Web component has produced its controller. */
  setController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  /**
   * Called from JavaScript as `window.OpenGymNative.postMessage(json)`.
   *
   * Returns a short status string purely so a debugging developer can see, in the WebView
   * console, whether the envelope even parsed. The app never reads it — the promise it is
   * waiting on is settled by `reply` instead.
   */
  postMessage(message: string): string {
    const envelope: JsonObject | null = parseObject(message);
    if (envelope === null) {
      hilog.error(DOMAIN, TAG, 'envelope is not a JSON object');
      return 'bad-envelope';
    }
    const callbackId: string = str(envelope, 'callbackId', '');
    const pluginId: string = str(envelope, 'pluginId', '');
    const methodName: string = str(envelope, 'methodName', '');
    if (callbackId.length === 0 || pluginId.length === 0 || methodName.length === 0) {
      hilog.error(DOMAIN, TAG, 'envelope is missing callbackId/pluginId/methodName');
      return 'bad-envelope';
    }

    const plugin = pluginFor(pluginId);
    if (plugin === undefined) {
      this.replyFn(callbackId, false,
        JSON.stringify({ 'message': `"${pluginId}" is not available on platform "harmony"`, 'code': 'UNIMPLEMENTED' }
          as JsonObject));
      return 'no-plugin';
    }

    const call: PluginCall =
      new PluginCall(pluginId, methodName, callbackId, obj(envelope, 'options'), this.replyFn);
    try {
      plugin.handle(call);
    } catch (e) {
      // A plugin that threw synchronously would otherwise leave the JS promise pending forever,
      // which on the app side looks like a hung sign-in rather than an error.
      hilog.error(DOMAIN, TAG, 'plugin %{public}s threw in %{public}s', pluginId, methodName);
      call.rejectError(e as Object);
    }
    return 'ok';
  }

  /**
   * Tell the page it is on screen, or not.
   *
   * This is `document.visibilityState` as far as the app is concerned: the shim owns that value
   * and re-dispatches the event, which is what the app's reminder sync, its rest-timer catch-up
   * rule, its wake lock and its media flush all read (bridge/Shim.ets).
   */
  notifyAppState(active: boolean): void {
    this.run(`window.__ogAppActive(${active ? 'true' : 'false'});`);
  }

  /**
   * Hand a system back press to the page, along with whether the WebView has history of its own.
   *
   * The page decides what it means — close a sheet, walk back, or the explicit press-again-to-
   * exit — because only the page knows what is on screen (frontend/src/lib/back.js). The ability
   * consumes the press either way and lets the page call `App.exitApp()` when it is done.
   */
  notifyBack(canGoBack: boolean): void {
    this.run(`window.__ogBack(${canGoBack ? 'true' : 'false'});`);
  }

  private reply(callbackId: string, ok: boolean, payloadJson: string): void {
    const fn: string = ok ? '__ogResolve' : '__ogReject';
    this.run(`window.${fn}(${JSON.stringify(callbackId)}, ${JSON.stringify(payloadJson)});`);
  }

  private run(script: string): void {
    const controller: webview.WebviewController | null = this.controller;
    if (controller === null) {
      hilog.warn(DOMAIN, TAG, 'no controller yet, dropping a bridge message');
      return;
    }
    controller.runJavaScript(script).catch((e: Error) => {
      // Expected when the page navigated away mid-call; not worth a stack trace.
      hilog.debug(DOMAIN, TAG, 'runJavaScript failed: %{public}s', e.message);
    });
  }
}
