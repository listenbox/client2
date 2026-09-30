// The only handwritten JavaScript in the client is this FFI adapter. It keeps
// YouTube.js objects live inside QuickJS; application policy stays in Dart.
const youtubeJsHost = r'''
import * as YT from 'youtubejs';

// Meriyah (used by YouTube.js to inspect the player script) calls the Web
// structuredClone API when it duplicates AST nodes. FJS's QuickJS context does
// not provide that global. Keep identities and cycles intact when cloning its
// object graphs; a JSON round trip would discard both.
if (typeof globalThis.structuredClone !== 'function') {
  globalThis.structuredClone = function structuredClone(source, options) {
    function cloneError(message) {
      const error = new TypeError(message);
      error.name = 'DataCloneError';
      return error;
    }
    if (options?.transfer?.length) {
      throw cloneError('Transferable objects are not supported');
    }
    const seen = new Map();
    function clone(value) {
      if (typeof value === 'symbol' || typeof value === 'function') {
        throw cloneError('This value cannot be cloned');
      }
      if (value === null || typeof value !== 'object') return value;
      if (seen.has(value)) return seen.get(value);

      if (value instanceof Date) {
        const output = new Date(value.getTime());
        seen.set(value, output);
        return output;
      }
      if (value instanceof RegExp) {
        const output = new RegExp(value.source, value.flags);
        seen.set(value, output);
        return output;
      }
      if (value instanceof ArrayBuffer) {
        const output = value.slice(0);
        seen.set(value, output);
        return output;
      }
      if (ArrayBuffer.isView(value)) {
        const buffer = clone(value.buffer);
        const output = value instanceof DataView
          ? new DataView(buffer, value.byteOffset, value.byteLength)
          : new value.constructor(buffer, value.byteOffset, value.length);
        seen.set(value, output);
        return output;
      }
      if (value instanceof Map) {
        const output = new Map();
        seen.set(value, output);
        for (const [key, item] of value) output.set(clone(key), clone(item));
        return output;
      }
      if (value instanceof Set) {
        const output = new Set();
        seen.set(value, output);
        for (const item of value) output.add(clone(item));
        return output;
      }
      if (value instanceof WeakMap || value instanceof WeakSet ||
          value instanceof Promise) {
        throw cloneError('This value cannot be cloned');
      }
      if (value instanceof Error) {
        const output = new Error(value.message);
        output.name = value.name;
        seen.set(value, output);
        if ('cause' in value) output.cause = clone(value.cause);
        return output;
      }

      const output = Array.isArray(value) ? new Array(value.length) : {};
      seen.set(value, output);
      for (const key of Object.keys(value)) {
        Object.defineProperty(output, key, {
          value: clone(value[key]), enumerable: true,
          writable: true, configurable: true,
        });
      }
      return output;
    }
    return clone(source);
  };
}

let client;
let parserFailed = false;
let nextHandle = 1;
const infos = new Map();
const cacheData = new Map();
const continuations = new Set();

class MemoryCache {
  get cache_dir() { return ''; }
  async get(key) { return cacheData.get(key); }
  async set(key, bytes) { cacheData.set(key, bytes); }
  async remove(key) { cacheData.delete(key); }
}

async function bridgeFetch(input, init) {
  // LLRT's Request(Request, init) clone retains native body state across
  // QuickJS teardown. Read the supplied Request and override fields directly.
  const request = input instanceof Request ? input : new Request(input, init);
  const method = init?.method || request.method;
  const headers = new Headers(init?.headers || request.headers);
  let body = null;
  if (method !== 'GET' && method !== 'HEAD') {
    const source = init && Object.hasOwn(init, 'body') ? init.body : request;
    if (typeof source === 'string') body = new TextEncoder().encode(source).buffer;
    else if (source instanceof ArrayBuffer) body = source;
    else if (ArrayBuffer.isView(source)) {
      body = source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength);
    } else if (source?.arrayBuffer) body = await source.arrayBuffer();
    else if (source != null) throw new TypeError('Unsupported YouTube request body');
  }
  if (request.url.includes('/youtubei/v1/browse') && body) {
    try {
      const token = JSON.parse(new TextDecoder().decode(body)).continuation;
      if (token) {
        if (continuations.has(token)) throw new Error('Repeated YouTube continuation');
        continuations.add(token);
      }
    } catch (error) {
      if (error.message === 'Repeated YouTube continuation') throw error;
    }
  }
  const result = await fjs.bridge_call({
    op: 'fetch', url: request.url, method,
    headers: Array.from(headers.entries()), body,
  });
  const data = result.body == null ? null : new Uint8Array(result.body);
  return new Response([204, 205, 304].includes(result.status) ? null : data, {
    status: result.status, headers: result.headers,
  });
}

export async function initialize(cookie) {
  YT.Platform.load({
    ...YT.Platform.shim,
    runtime: 'unknown', server: true,
    fetch: bridgeFetch, Cache: MemoryCache,
    eval(data, env) {
      const names = Object.keys(env);
      return Function(...names, data.output)(...names.map(name => env[name]));
    },
  });
  YT.Parser.setParserErrorHandler(() => { parserFailed = true; });
  client = await YT.Innertube.create({
    lang: 'en', location: 'US',
    cache: new YT.UniversalCache(false),
    fetch: bridgeFetch,
    ...(cookie ? { cookie } : {}),
    generate_session_locally: false,
    fail_fast: true,
    retrieve_player: true,
    retrieve_innertube_config: false,
  });
  return client.session.user_agent;
}

function durationBadges(image) {
  if (!image || image.type !== 'ThumbnailView') return [];
  return (image.overlays || []).flatMap(overlay =>
    (overlay.badges || []).map(badge => badge.text).filter(Boolean));
}

export async function scanPlaylist(id) {
  parserFailed = false;
  continuations.clear();
  const actions = client.actions;
  const response = await actions.execute('/browse', {
    browseId: `VL${id}`, params: 'wgYCCAA=',
  });
  let page = new YT.YT.Playlist(actions, response, false);
  let title = null;
  const entries = [];
  const alerts = [];
  let pages = 0;
  for (;;) {
    if (parserFailed) throw new Error('YouTube playlist could not be parsed completely');
    title ??= page.info?.title ?? null;
    for (const alert of page.page?.alerts || []) {
      alerts.push({ kind: alert.type, alertType: alert.alert_type });
    }
    for (const item of page.items || []) {
      if (item.type === 'PlaylistVideo') {
        entries.push({ kind: item.type, id: item.id,
          title: item.title?.toString() ?? '',
          durationSeconds: item.duration?.seconds ?? null,
          contentType: null, durationBadges: [], });
      } else if (item.type === 'LockupView') {
        entries.push({ kind: item.type, id: item.content_id,
          title: item.metadata?.title?.toString() ?? null,
          durationSeconds: null, contentType: item.content_type,
          durationBadges: durationBadges(item.content_image), });
      } else {
        entries.push({ kind: item.type ?? 'Unknown', id: null, title: null,
          durationSeconds: null, contentType: null, durationBadges: [], });
      }
    }
    if (++pages > 10000) throw new Error('YouTube playlist exceeds the scan limit');
    if (!page.has_continuation) break;
    page = await page.getContinuation();
  }
  return { title, entries, alerts, parserFailed, pages };
}

function describeFormat(format, index) {
  return {
    index, itag: format.itag, mimeType: format.mime_type,
    bitrate: format.bitrate, height: format.height ?? null,
    hasAudio: format.has_audio, hasVideo: format.has_video,
    isTypeOtf: format.is_type_otf, drmFamilies: format.drm_families ?? [],
    contentLength: format.content_length ?? null,
    hasUrl: !!format.url, hasCipher: !!(format.cipher || format.signature_cipher),
  };
}

export async function videoInfo(id) {
  let info;
  try {
    info = await client.getBasicInfo(id, { client: 'WEB' });
  } catch (error) {
    return { error: { status: error.info?.status ?? null,
      reason: error.info?.reason ?? null, message: String(error.message || error) } };
  }
  const basic = info.basic_info;
  const status = info.playability_status;
  const microformat = info.page?.[0]?.microformat;
  const formats = [ ...(info.streaming_data?.formats || []),
    ...(info.streaming_data?.adaptive_formats || []) ];
  const handle = nextHandle++;
  infos.set(handle, { info, formats });
  return { handle, id: basic?.id ?? null, title: basic?.title ?? null,
    description: basic?.short_description ?? null,
    durationSeconds: basic?.duration ?? null,
    isLive: basic?.is_live ?? false, isUpcoming: basic?.is_upcoming ?? false,
    status: status?.status ?? null, reason: status?.reason ?? null,
    publishDate: microformat?.type === 'PlayerMicroformat'
      ? microformat.publish_date ?? null : null,
    uploadDate: microformat?.type === 'PlayerMicroformat'
      ? microformat.upload_date ?? null : null,
    cpn: info.cpn,
    formats: formats.map(describeFormat) };
}

export async function decipherFormat(handle, index) {
  const entry = infos.get(handle);
  if (!entry) throw new Error('Video info handle is closed');
  const format = entry.formats[index];
  if (!format) throw new Error('Unknown YouTube format');
  const session = client.session;
  const needsPlayer = !!(format.cipher || format.signature_cipher ||
    (format.url && new URL(format.url).searchParams.has('n')));
  if (needsPlayer && !session.player) {
    session.player = await YT.Player.create(
      session.cache, session.http.fetch_function, undefined, undefined);
  }
  const url = new URL(await format.decipher(session.player));
  url.searchParams.append('cpn', entry.info.cpn);
  return url.toString();
}

export function releaseVideoInfo(handle) { infos.delete(handle); }

export function shutdown() {
  infos.clear();
  cacheData.clear();
  continuations.clear();
  client = undefined;
  YT.Parser.setParserErrorHandler(() => {});
}
''';
