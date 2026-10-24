/**
 * JSON helpers for the bridge.
 *
 * ArkTS has no `any`, and `JSON.parse` hands back an opaque `Object`. Everything that crossed
 * the bridge is therefore funnelled through here once, so no plugin has to repeat the guards.
 * The rule this file exists to enforce: a malformed payload from the WebView must degrade to a
 * readable value, never to a thrown TypeError deep inside a plugin handler.
 */

import { util } from '@kit.ArkTS';

/** The parsed shape of an options object. */
export type JsonObject = Record<string, Object>;

/** Parse a JSON string into an object, or null when it is not one. Never throws. */
export function parseObject(text: string): JsonObject | null {
  if (text === undefined || text === null || text.length === 0) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(text);
    if (parsed === null || parsed === undefined) {
      return null;
    }
    if (Array.isArray(parsed)) {
      return null;
    }
    if (typeof parsed !== 'object') {
      return null;
    }
    return parsed as JsonObject;
  } catch (e) {
    return null;
  }
}

/** Serialise anything for the return trip. A cyclic or otherwise unserialisable value becomes `{}`. */
export function toJson(value: Object): string {
  try {
    const out: string = JSON.stringify(value);
    return out === undefined ? '{}' : out;
  } catch (e) {
    return '{}';
  }
}

/** A string field, or `fallback` when absent or of another type. */
export function str(obj: JsonObject | null, key: string, fallback: string): string {
  if (obj === null) {
    return fallback;
  }
  const v: Object = obj[key];
  return typeof v === 'string' ? v as string : fallback;
}

/** A string field, or undefined. Distinguishes "absent" from "empty", which some callers need. */
export function optStr(obj: JsonObject | null, key: string): string | undefined {
  if (obj === null) {
    return undefined;
  }
  const v: Object = obj[key];
  return typeof v === 'string' ? v as string : undefined;
}

/** A number field. Accepts numeric strings, because the WebView sends both. */
export function num(obj: JsonObject | null, key: string, fallback: number): number {
  if (obj === null) {
    return fallback;
  }
  const v: Object = obj[key];
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const parsed: number = Number.parseFloat(v as string);
    return Number.isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

/** A boolean field. Strict: anything that is not a real boolean falls back. */
export function bool(obj: JsonObject | null, key: string, fallback: boolean): boolean {
  if (obj === null) {
    return fallback;
  }
  const v: Object = obj[key];
  return typeof v === 'boolean' ? v as boolean : fallback;
}

/** A nested object field, or null. */
export function obj(obj: JsonObject | null, key: string): JsonObject | null {
  if (obj === null) {
    return null;
  }
  const v: Object = obj[key];
  if (v === undefined || v === null || typeof v !== 'object' || Array.isArray(v)) {
    return null;
  }
  return v as JsonObject;
}

/** An array field, or an empty array. */
export function arr(obj: JsonObject | null, key: string): Object[] {
  if (obj === null) {
    return [];
  }
  const v: Object = obj[key];
  return Array.isArray(v) ? v as Object[] : [];
}

/** Whether the key is present at all. */
export function has(obj: JsonObject | null, key: string): boolean {
  if (obj === null) {
    return false;
  }
  return obj[key] !== undefined;
}

/** A base64 payload decoded to bytes. Returns null on anything malformed. */
export function decodeBase64(text: string): Uint8Array | null {
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.decodeSync(text);
  } catch (e) {
    return null;
  }
}

/** Bytes encoded to base64. */
export function encodeBase64(bytes: Uint8Array): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}
