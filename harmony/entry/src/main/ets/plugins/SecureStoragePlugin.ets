import { asset } from '@kit.AssetStoreKit';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject, str } from '../common/JsonUtil';

/**
 * `@aparajita/capacitor-secure-storage`, over the Asset Store Kit.
 *
 * What the app keeps here is small but genuinely secret: the Cloudflare Access service token
 * (client id + secret) that lets a paired phone through a Zero Trust proxy, and the AI Coach
 * provider credentials. On Android and iOS these live in the Keystore / Keychain; the HarmonyOS
 * equivalent is the asset store, which is why this plugin exists at all rather than the values
 * going into Preferences — a shared-preferences file is readable by anything holding the app's
 * sandbox, and these are not training data.
 *
 * The asset store keys records by alias, so the JS key is used verbatim as the alias, prefixed so
 * the app's own secrets cannot collide with anything else the shell may store later.
 *
 * Failure here is contained: the app treats an unavailable secret as "not configured" and asks
 * for it again, so a device without the asset service degrades to re-prompting rather than
 * breaking sign-in.
 */
const PREFIX: string = 'opengym.';

function toBytes(value: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    out[i] = value.charCodeAt(i) & 0xff;
  }
  return out;
}

function fromBytes(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

export class SecureStoragePlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'SecureStorage';
  }

  getMethods(): string[] {
    return ['set', 'get', 'remove', 'clear', 'keys', 'getKeyPrefix', 'setKeyPrefix',
      'setSynchronize', 'setAccessibility', 'setLogging'];
  }

  handle(call: PluginCall): void {
    // The asset store is asynchronous and can be slow on first unlock; the call is settled from
    // the promise rather than inline.
    this.dispatch(call).catch((e: Object) => call.rejectError(e));
  }

  private async dispatch(call: PluginCall): Promise<void> {
    switch (call.methodName) {
      case 'set': return this.set(call);
      case 'get': return this.get(call);
      case 'remove': return this.remove(call);
      case 'clear': return this.clear(call);
      case 'keys': return this.keys(call);
      case 'getKeyPrefix':
        call.resolve({ 'value': PREFIX } as JsonObject);
        return;
      case 'setKeyPrefix':
      case 'setSynchronize':
      case 'setAccessibility':
      case 'setLogging':
        // Accepted and ignored: the asset store fixes its own accessibility per record, and
        // there is no HarmonyOS equivalent of iCloud-synchronised keychain items here.
        call.resolve({} as JsonObject);
        return;
      default:
        return this.rejectUnknownMethod(call);
    }
  }

  private aliasOf(key: string): string {
    return `${PREFIX}${key}`;
  }

  private async set(call: PluginCall): Promise<void> {
    const key: string = call.getString('key');
    const value: string = call.getString('value');
    if (key.length === 0) {
      call.reject('key is required');
      return;
    }
    // Upsert by hand: the asset store has no "replace" verb and `add` on an existing alias fails.
    await this.removeQuietly(key);

    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ALIAS, toBytes(this.aliasOf(key)));
    attr.set(asset.Tag.SECRET, toBytes(value));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attr);
      call.resolve({} as JsonObject);
    } catch (e) {
      call.rejectError(e as Object, 'SECURE_SET_FAILED');
    }
  }

  private async get(call: PluginCall): Promise<void> {
    const key: string = call.getString('key');
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(this.aliasOf(key)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        // Capacitor's secure-storage answers null for a key that was never set.
        call.resolve({ 'value': null } as JsonObject);
        return;
      }
      // Typed by inference (`Value | undefined`): an explicit `Object` annotation would not
      // accept the undefined half, and `asset.Value` is a union alias rather than a class.
      const secret = results[0].get(asset.Tag.SECRET);
      const text: string = secret instanceof Uint8Array ? fromBytes(secret) : '';
      call.resolve({ 'value': text } as JsonObject);
    } catch (e) {
      // NOT_FOUND arrives as a rejection on some builds rather than an empty result.
      call.resolve({ 'value': null } as JsonObject);
    }
  }

  private async remove(call: PluginCall): Promise<void> {
    const key: string = call.getString('key');
    const removed: boolean = await this.removeQuietly(key);
    call.resolve({ 'value': removed } as JsonObject);
  }

  /** True when a record was actually there. Used by both `remove` and the upsert in `set`. */
  private async removeQuietly(key: string): Promise<boolean> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, toBytes(this.aliasOf(key)));
    try {
      await asset.remove(query);
      return true;
    } catch (e) {
      return false;
    }
  }

  private async keys(call: PluginCall): Promise<void> {
    // The asset store cannot enumerate aliases, and this shell only ever stores whole
    // configurations under known keys, so there is nothing truthful to list.
    call.resolve({ 'value': [] } as JsonObject);
  }

  private async clear(call: PluginCall): Promise<void> {
    // Same limitation: without enumeration, a blanket clear would have to guess the keys.
    // The app removes the specific keys it set; see lib/coach-secrets.js and lib/cf-access.js.
    call.resolve({} as JsonObject);
  }
}
