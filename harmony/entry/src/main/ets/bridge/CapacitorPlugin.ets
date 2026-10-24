import { common } from '@kit.AbilityKit';
import { PluginCall } from './PluginCall';

/**
 * Base class for a bridged plugin.
 *
 * The shape deliberately mirrors a Capacitor plugin on the native side: an id, a list of method
 * names, and one dispatcher. `getMethods()` is what the bridge publishes to the WebView in
 * `Capacitor.PluginHeaders`, and `@capacitor/core` reads that list to decide whether a property
 * is a method or a plain value — so a method missing from it is invisible to the app even
 * though the native code is there.
 */
export abstract class CapacitorPlugin {
  private context: common.UIAbilityContext | null = null;

  /** The Capacitor plugin name, e.g. `Filesystem`. Must match the web-side import. */
  abstract getPluginId(): string;

  /** Every callable method name. Kept in sync with the web side by hand. */
  abstract getMethods(): string[];

  /**
   * Handle one call. Implementations resolve or reject exactly once; the bridge does not
   * second-guess them.
   */
  abstract handle(call: PluginCall): void;

  /** Called once before the first call. Plugins needing a context or listeners override it. */
  attach(context: common.UIAbilityContext): void {
    this.context = context;
  }

  /** The UIAbility context, or null when the plugin asked for none. */
  protected getContext(): common.UIAbilityContext | null {
    return this.context;
  }

  handles(method: string): boolean {
    return this.getMethods().includes(method);
  }

  /**
   * Reject an unknown method with the same wording Capacitor uses, so a version skew between
   * the bundle and the shell is readable in the log rather than a silent hanging promise.
   */
  rejectUnknownMethod(call: PluginCall): void {
    call.reject(`"${call.methodName}" is not implemented on platform "harmony"`, 'UNIMPLEMENTED');
  }
}
