import { JsonObject, arr, bool, has, num, obj, optStr, str } from '../common/JsonUtil';

/**
 * How the bridge hands a result back to the WebView. Supplied by CapacitorBridge, so a plugin
 * never touches the controller itself and cannot accidentally reply twice.
 */
export type ReplyFn = (callbackId: string, ok: boolean, payloadJson: string) => void;

/**
 * One call from the WebView, and the single place its answer goes back through.
 *
 * Mirrors the Capacitor `PluginCall` contract the web side already expects:
 * `resolve(data)` settles the JS promise, `reject(message, code)` rejects it. Every getter is
 * total — a missing or mistyped field yields the fallback — because the caller is JavaScript and
 * an options object that arrived malformed must not turn into a native crash.
 */
export class PluginCall {
  readonly pluginId: string;
  readonly methodName: string;
  readonly callbackId: string;
  private readonly options: JsonObject | null;
  private readonly reply: ReplyFn;
  private settled: boolean = false;

  constructor(pluginId: string, methodName: string, callbackId: string,
              options: JsonObject | null, reply: ReplyFn) {
    this.pluginId = pluginId;
    this.methodName = methodName;
    this.callbackId = callbackId;
    this.options = options;
    this.reply = reply;
  }

  getString(key: string, fallback: string = ''): string {
    return str(this.options, key, fallback);
  }

  /** Absent means absent — an empty string and a missing key are different to several callers. */
  getOptionalString(key: string): string | undefined {
    return optStr(this.options, key);
  }

  getNumber(key: string, fallback: number = 0): number {
    return num(this.options, key, fallback);
  }

  getBoolean(key: string, fallback: boolean = false): boolean {
    return bool(this.options, key, fallback);
  }

  getObject(key: string): JsonObject | null {
    return obj(this.options, key);
  }

  getArray(key: string): Object[] {
    return arr(this.options, key);
  }

  hasOption(key: string): boolean {
    return has(this.options, key);
  }

  /** The whole options object, for plugins that forward it untouched. */
  getRawOptions(): JsonObject | null {
    return this.options;
  }

  /** Settle the JS promise. Calling it twice is ignored rather than an error. */
  resolve(data?: JsonObject): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.reply(this.callbackId, true, data === undefined ? '{}' : JSON.stringify(data));
  }

  /** Reject the JS promise with a message the app can show. */
  reject(message: string, code?: string): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    const payload: JsonObject = { 'message': message };
    if (code !== undefined && code.length > 0) {
      payload['code'] = code;
    }
    this.reply(this.callbackId, false, JSON.stringify(payload));
  }

  /** Reject from a caught native error, keeping its message. */
  rejectError(e: Object, code?: string): void {
    let message: string = 'native error';
    if (e instanceof Error) {
      message = (e as Error).message;
    } else if (e !== undefined && e !== null) {
      message = JSON.stringify(e);
    }
    this.reject(message, code);
  }
}
