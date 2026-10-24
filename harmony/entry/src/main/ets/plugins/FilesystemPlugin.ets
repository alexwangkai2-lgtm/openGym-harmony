import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CapacitorPlugin } from '../bridge/CapacitorPlugin';
import { PluginCall } from '../bridge/PluginCall';
import { JsonObject, decodeBase64, encodeBase64 } from '../common/JsonUtil';

/**
 * `@capacitor/filesystem`, re-implemented over `@kit.CoreFileKit`.
 *
 * This is the plugin the app cannot start without: the mobile build mirrors its whole state into
 * `opengym-state.json` on every change, because iOS evicts WebView storage under pressure and
 * HarmonyOS's ArkWeb is under no obligation to keep `localStorage` across an update either
 * (see frontend/src/lib/mobile.js — nativeSave/nativeLoad). Lose this plugin and the app still
 * boots, but every change lives only until the WebView is torn down.
 *
 * Directory mapping. Capacitor's enum is iOS-shaped and HarmonyOS has no equivalent of
 * `Documents` or `Library`, so each one lands inside the app sandbox:
 *
 *   DATA             → filesDir              the durable private directory, never evicted
 *   CACHE            → cacheDir              evictable; the app only uses it for share temp files
 *   DOCUMENTS        → filesDir/Documents    sandbox, NOT user-visible (see the note below)
 *   LIBRARY          → filesDir/Library      the app's own media store lives here
 *   EXTERNAL*        → filesDir/External     approximated; HarmonyOS has no shared external dir
 *
 * A note that matters for auto-backup: on Android `Directory.Documents` is the *shared* folder a
 * file manager can see, and the app's dated backups are meant to be reachable by a sync app
 * (docs/MOBILE.md). Inside the HarmonyOS sandbox they are not. `Share.share` is the way out on
 * this platform, and the Settings screen's export already goes through it.
 *
 * Every path is resolved inside the sandbox directory for its `directory` value, and `..` is
 * rejected outright — a WebView is a lower trust boundary than the native side, and this is the
 * one place it hands over a path.
 */
export class FilesystemPlugin extends CapacitorPlugin {
  getPluginId(): string {
    return 'Filesystem';
  }

  getMethods(): string[] {
    return ['readFile', 'writeFile', 'appendFile', 'deleteFile', 'mkdir', 'rmdir',
      'readdir', 'stat', 'getUri', 'copy', 'rename', 'checkPermissions', 'requestPermissions'];
  }

  handle(call: PluginCall): void {
    this.dispatch(call).catch((e: Object) => call.rejectError(e));
  }

  private async dispatch(call: PluginCall): Promise<void> {
    switch (call.methodName) {
      case 'readFile': return this.readFile(call);
      case 'writeFile': return this.writeFile(call, false);
      case 'appendFile': return this.writeFile(call, true);
      case 'deleteFile': return this.deleteFile(call);
      case 'mkdir': return this.mkdir(call);
      case 'rmdir': return this.rmdir(call);
      case 'readdir': return this.readdir(call);
      case 'stat': return this.stat(call);
      case 'getUri': return this.getUri(call);
      case 'copy': return this.copy(call);
      case 'rename': return this.rename(call);
      case 'checkPermissions': return call.resolve({ 'publicStorage': 'granted' } as JsonObject);
      case 'requestPermissions': return call.resolve({ 'publicStorage': 'granted' } as JsonObject);
      default: return this.rejectUnknownMethod(call);
    }
  }

  /** The sandbox directory a Capacitor `Directory` value maps onto. */
  private baseDir(name: string): string {
    const ctx: common.UIAbilityContext | null = this.getContext();
    if (ctx === null) {
      throw new Error('no UIAbility context — the plugin was not attached');
    }
    switch (name) {
      case 'DOCUMENTS':
        return `${ctx.filesDir}/Documents`;
      case 'CACHE':
        return ctx.cacheDir;
      case 'LIBRARY':
        return `${ctx.filesDir}/Library`;
      case 'EXTERNAL':
      case 'EXTERNAL_STORAGE':
        return `${ctx.filesDir}/External`;
      case 'DATA':
      default:
        return ctx.filesDir;
    }
  }

  /**
   * Resolve `path` under the directory for `directory`.
   *
   * Leading slashes are stripped rather than honoured: the app passes relative paths, and a
   * rooted one would otherwise escape the sandbox. `..` is refused instead of normalised, so a
   * caller cannot talk its way out with an unusual spelling.
   */
  private resolvePath(call: PluginCall, defaultDirectory: string = 'DATA'): string {
    const rel: string = call.getString('path');
    if (rel.length === 0) {
      throw new Error('path is required');
    }
    if (rel.includes('..')) {
      throw new Error('path may not contain ".."');
    }
    const base: string = this.baseDir(call.getString('directory', defaultDirectory));
    let clean: string = rel;
    while (clean.startsWith('/')) {
      clean = clean.slice(1);
    }
    return clean.length === 0 ? base : `${base}/${clean}`;
  }

  private ensureParent(fullPath: string, recursive: boolean): void {
    const idx: number = fullPath.lastIndexOf('/');
    if (idx <= 0) {
      return;
    }
    const parent: string = fullPath.slice(0, idx);
    if (!fs.accessSync(parent)) {
      fs.mkdirSync(parent, recursive);
    }
  }

  private async readFile(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    const encoding: string | undefined = call.getOptionalString('encoding');
    if (!fs.accessSync(full)) {
      call.reject(`File does not exist: ${full}`, 'NOT_FOUND');
      return;
    }
    if (encoding !== undefined && encoding.toLowerCase() === 'utf8') {
      const text: string = fs.readTextSync(full);
      call.resolve({ 'data': text } as JsonObject);
      return;
    }
    // No encoding: Capacitor hands back base64, which is what the media store expects.
    const stat = fs.statSync(full);
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const file = fs.openSync(full, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
    call.resolve({ 'data': encodeBase64(new Uint8Array(buffer)) } as JsonObject);
  }

  private async writeFile(call: PluginCall, append: boolean): Promise<void> {
    const full: string = this.resolvePath(call);
    const data: string = call.getString('data');
    const encoding: string | undefined = call.getOptionalString('encoding');
    const recursive: boolean = call.getBoolean('recursive', false);
    this.ensureParent(full, recursive);

    const mode: number = append
      ? (fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
      : (fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    const file = fs.openSync(full, mode);
    try {
      if (encoding !== undefined && encoding.toLowerCase() === 'utf8') {
        fs.writeSync(file.fd, data, { encoding: 'utf-8' });
      } else {
        const bytes: Uint8Array | null = decodeBase64(data);
        if (bytes === null) {
          call.reject('data is not valid base64', 'BAD_DATA');
          return;
        }
        fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      }
    } finally {
      fs.closeSync(file);
    }
    call.resolve({ 'uri': `file://${full}` } as JsonObject);
  }

  private async deleteFile(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    if (!fs.accessSync(full)) {
      call.reject(`File does not exist: ${full}`, 'NOT_FOUND');
      return;
    }
    fs.unlinkSync(full);
    call.resolve({} as JsonObject);
  }

  private async mkdir(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    const recursive: boolean = call.getBoolean('recursive', false);
    if (!fs.accessSync(full)) {
      fs.mkdirSync(full, recursive);
    }
    call.resolve({} as JsonObject);
  }

  private async rmdir(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    const recursive: boolean = call.getBoolean('recursive', false);
    if (!fs.accessSync(full)) {
      call.reject(`Directory does not exist: ${full}`, 'NOT_FOUND');
      return;
    }
    if (recursive) {
      fs.rmdirSync(full);
    } else {
      const entries: string[] = fs.listFileSync(full);
      if (entries.length > 0) {
        call.reject(`Directory not empty: ${full}`, 'NOT_EMPTY');
        return;
      }
      fs.rmdirSync(full);
    }
    call.resolve({} as JsonObject);
  }

  private async readdir(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    if (!fs.accessSync(full)) {
      call.reject(`Directory does not exist: ${full}`, 'NOT_FOUND');
      return;
    }
    const names: string[] = fs.listFileSync(full);
    const files: JsonObject[] = [];
    for (const name of names) {
      const child: string = `${full}/${name}`;
      let isDir: boolean = false;
      let size: number = 0;
      let mtime: number = 0;
      try {
        const st = fs.statSync(child);
        isDir = st.isDirectory();
        size = st.size;
        mtime = st.mtime * 1000;
      } catch (e) {
        // A file that vanished between listing and stat: report it as a plain entry.
      }
      files.push({
        'name': name,
        'type': isDir ? 'directory' : 'file',
        'size': size,
        'ctime': mtime,
        'mtime': mtime,
        'uri': `file://${child}`
      } as JsonObject);
    }
    call.resolve({ 'files': files } as JsonObject);
  }

  private async stat(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    if (!fs.accessSync(full)) {
      call.reject(`File does not exist: ${full}`, 'NOT_FOUND');
      return;
    }
    const st = fs.statSync(full);
    const mtime: number = st.mtime * 1000;
    call.resolve({
      'type': st.isDirectory() ? 'directory' : 'file',
      'size': st.size,
      'ctime': mtime,
      'mtime': mtime,
      'uri': `file://${full}`
    } as JsonObject);
  }

  private async getUri(call: PluginCall): Promise<void> {
    const full: string = this.resolvePath(call);
    call.resolve({ 'uri': `file://${full}` } as JsonObject);
  }

  private async copy(call: PluginCall): Promise<void> {
    const from: string = this.resolvePath(call);
    const to: string = this.resolvePathFor(call, 'to', 'directory');
    if (!fs.accessSync(from)) {
      call.reject(`File does not exist: ${from}`, 'NOT_FOUND');
      return;
    }
    this.ensureParent(to, true);
    fs.copyFileSync(from, to);
    call.resolve({ 'uri': `file://${to}` } as JsonObject);
  }

  private async rename(call: PluginCall): Promise<void> {
    const from: string = this.resolvePath(call);
    const to: string = this.resolvePathFor(call, 'to', 'directory');
    if (!fs.accessSync(from)) {
      call.reject(`File does not exist: ${from}`, 'NOT_FOUND');
      return;
    }
    this.ensureParent(to, true);
    fs.renameSync(from, to);
    call.resolve({ 'uri': `file://${to}` } as JsonObject);
  }

  /** Resolve a second path from a differently named option (`to`), sharing the same guards. */
  private resolvePathFor(call: PluginCall, pathKey: string, dirKey: string): string {
    const rel: string = call.getString(pathKey);
    if (rel.length === 0) {
      throw new Error(`${pathKey} is required`);
    }
    if (rel.includes('..')) {
      throw new Error(`${pathKey} may not contain ".."`);
    }
    const base: string = this.baseDir(call.getString(dirKey, 'DATA'));
    let clean: string = rel;
    while (clean.startsWith('/')) {
      clean = clean.slice(1);
    }
    return clean.length === 0 ? base : `${base}/${clean}`;
  }
}
