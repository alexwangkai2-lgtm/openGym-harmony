import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject } from '../common/JsonUtil';

/**
 * `@capacitor/share`, over `@kit.ShareKit`.
 *
 * The app reaches for this on the mobile build instead of a browser download, because a WebView
 * cannot save a blob URL: `shareExport` writes the backup JSON to the cache directory and hands
 * the file to the OS share sheet (frontend/src/lib/mobile.js), and the photo-and-video export
 * arrives the same way. So this plugin is the app's *only* way to get a backup off the device —
 * losing it does not break training, but it does mean the user cannot export.
 *
 * `title`, when present, becomes the subject line; the URI decides whether it is a file or a
 * plain-text share.
 */
export class SharePlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'Share';
  }

  getMethods(): string[] {
    return ['share', 'canShare'];
  }

  handle(call: PluginCall): void {
    switch (call.methodName) {
      case 'share':
        this.share(call);
        return;
      case 'canShare':
        call.resolve({ 'value': true } as JsonObject);
        return;
      default:
        this.rejectUnknownMethod(call);
    }
  }

  private share(call: PluginCall): void {
    const ctx = this.getContext();
    if (ctx === null) {
      call.reject('no UIAbility context — the plugin was not attached');
      return;
    }

    const title: string = call.getString('title', 'openGym');
    const uri: string = call.getString('url');
    const text: string = call.getString('text');
    const files: Object[] = call.getArray('files');

    const uris: string[] = [];
    if (uri.length > 0) {
      uris.push(uri);
    }
    for (const entry of files) {
      if (typeof entry === 'string') {
        uris.push(entry as string);
      }
    }

    try {
      const data: systemShare.SharedData = this.buildData(uris, text);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      // The sheet is asynchronous by nature — the user may dismiss it — so the call resolves as
      // soon as the sheet is up, which is the moment Capacitor's own Share resolves too.
      call.resolve({} as JsonObject);
    } catch (e) {
      call.rejectError(e as Object, 'SHARE_FAILED');
    }
  }

  /** Prefer the file: a share sheet showing "openGym-backup-2026-10-11.json" beats raw JSON. */
  private buildData(uris: string[], text: string): systemShare.SharedData {
    if (uris.length > 0) {
      const records: systemShare.SharedRecord[] = [];
      for (const one of uris) {
        records.push({
          utd: utd.UniformDataType.FILE,
          uri: one,
          title: one.slice(one.lastIndexOf('/') + 1)
        });
      }
      return new systemShare.SharedData(...records);
    }
    return new systemShare.SharedData({
      utd: utd.UniformDataType.PLAIN_TEXT,
      content: text
    });
  }
}
