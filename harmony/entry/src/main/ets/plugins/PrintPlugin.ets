import { fileIo as fs } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject } from '../common/JsonUtil';

/**
 * `Print.printHtml` — handing a self-contained HTML document to the OS.
 *
 * What it is for: "Print / Save as PDF" on a plan and a routine (frontend/src/views/Plan.jsx,
 * RoutineEdit.jsx). The HTML is built by lib/plan-share.js and is fully self-contained — no
 * external assets — precisely so that whatever renders it needs nothing else.
 *
 * Where this departs from Android and iOS, and why it is a deliberate compromise rather than an
 * omission: those two platforms own a system print pipeline that renders HTML to PDF and offers
 * "Save as PDF" (Android's PrintManager, iOS's print sheet). HarmonyOS has a print service, but
 * it takes a *print task* over a document and file the caller already owns — there is no
 * "give me some HTML and offer PDF" entry point. Two honest options existed:
 *
 *   1. Render nothing here and leave the button inert — the user loses the feature silently.
 *   2. Write the HTML to a file and hand it to the share sheet, where "Save to Files" and every
 *      PDF-capable app on the device are one tap away.
 *
 * This is (2). The user still gets the document off the app and can still turn it into a PDF;
 * what changes is that the conversion is the receiving app's job rather than the system's, and
 * the button's label ("Print / Save as PDF") is more accurate than it would be under (1).
 */
const PRINT_DIR: string = 'print';

export class PrintPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'Print';
  }

  getMethods(): string[] {
    return ['printHtml'];
  }

  handle(call: PluginCall): void {
    switch (call.methodName) {
      case 'printHtml':
        this.printHtml(call);
        return;
      default:
        this.rejectUnknownMethod(call);
    }
  }

  private printHtml(call: PluginCall): void {
    const ctx = this.getContext();
    if (ctx === null) {
      call.reject('no UIAbility context — the plugin was not attached');
      return;
    }
    const html: string = call.getString('html');
    if (html.length === 0) {
      call.reject('html is required');
      return;
    }
    const rawName: string = call.getString('name', 'openGym');
    const fileName: string = `${sanitise(rawName)}.html`;
    const dir: string = `${ctx.cacheDir}/${PRINT_DIR}`;
    const full: string = `${dir}/${fileName}`;

    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const file = fs.openSync(full, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // Written as UTF-8 with the meta charset already inside the document (plan-share.js
        // builds it), so no BOM is needed and a reader opening it sees the right characters.
        fs.writeSync(file.fd, html, { encoding: 'utf-8' });
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      call.rejectError(e as Object, 'PRINT_WRITE_FAILED');
      return;
    }

    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.FILE,
        uri: `file://${full}`,
        title: fileName
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      call.resolve({ 'uri': `file://${full}` } as JsonObject);
    } catch (e) {
      call.rejectError(e as Object, 'PRINT_SHARE_FAILED');
    }
  }
}

/** A routine name becomes a file name: path separators and control characters are not welcome. */
function sanitise(name: string): string {
  let out: string = '';
  for (let i = 0; i < name.length && out.length < 64; i++) {
    const ch: string = name.charAt(i);
    const bad: boolean = ch === '/' || ch === '\\' || ch === ':' || ch === '*' ||
      ch === '?' || ch === '"' || ch === '<' || ch === '>' || ch === '|' || ch === '\n' || ch === '\r';
    out += bad ? '-' : ch;
  }
  const trimmed: string = out.trim();
  return trimmed.length === 0 ? 'openGym' : trimmed;
}
