import { common } from '@kit.AbilityKit';
import { CapacitorPlugin } from './CapacitorPlugin';

/**
 * The plugin table.
 *
 * Registration happens once, at page start, before the WebView is handed its shim — the shim
 * advertises each plugin's method list to `@capacitor/core`, and a plugin registered after that
 * point would be invisible to the app for the life of the page.
 */

/**
 * One method, as `@capacitor/core` reads it.
 *
 * The shape is not a free choice — `createPluginMethod` in @capacitor/core does
 *
 *     pluginHeader.methods.find((m) => prop === m.name)
 *
 * and then branches on `methodHeader.rtype === 'promise'` to pick `nativePromise` or
 * `nativeCallback`. A bare string would leave `m.name` undefined, no method would ever match,
 * and every call would fall through to the plugin's *web* implementation — or, for our own
 * plugins, which have none, to a thrown "not implemented on harmony".
 */
export interface PluginMethodHeader {
  name: string;
  rtype: string;
}

/** What `@capacitor/core` reads out of `window.Capacitor.PluginHeaders`. */
export interface PluginHeader {
  name: string;
  methods: PluginMethodHeader[];
}

const plugins: Map<string, CapacitorPlugin> = new Map();

/** Idempotent: calling it twice for one id keeps the first, like Capacitor's own registerPlugin. */
export function registerPlugin(plugin: CapacitorPlugin): void {
  const id: string = plugin.getPluginId();
  if (!plugins.has(id)) {
    plugins.set(id, plugin);
  }
}

export function pluginFor(id: string): CapacitorPlugin | undefined {
  return plugins.get(id);
}

export function pluginIds(): string[] {
  const out: string[] = [];
  plugins.forEach((_value: CapacitorPlugin, key: string) => {
    out.push(key);
  });
  return out;
}

/** The header list, serialised into the shim as a plain JS array literal. */
export function pluginHeaders(): PluginHeader[] {
  const out: PluginHeader[] = [];
  plugins.forEach((plugin: CapacitorPlugin) => {
    // Every method these plugins publish settles later, through the bridge's answer callback —
    // there is no synchronous or callback-argument shape anywhere in this shell, so `promise` is
    // the only return type that can ever be right here.
    const methods: PluginMethodHeader[] = plugin.getMethods()
      .map((name: string): PluginMethodHeader => {
        const header: PluginMethodHeader = { name: name, rtype: 'promise' };
        return header;
      });
    out.push({ name: plugin.getPluginId(), methods: methods });
  });
  return out;
}

/** Hand every plugin the UIAbility context before the first call can arrive. */
export function attachAll(context: common.UIAbilityContext): void {
  plugins.forEach((plugin: CapacitorPlugin) => {
    try {
      plugin.attach(context);
    } catch (e) {
      // One plugin failing to attach must not take the shell down; its calls will reject instead.
    }
  });
}
