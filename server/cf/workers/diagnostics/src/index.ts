export interface Env {
  DIAGNOSTICS: R2Bucket;
  UPLOAD_LIMITER: RateLimit;
}
const MAX_BYTES = 50 * 1024 * 1024;
const formats: Record<string, string> = {
  'text/plain': 'log',
  'application/zip': 'zip',
  'application/json': 'json',
};
const reply = (status: number, body: unknown) => Response.json(body, {
  status, headers: { 'Cache-Control': 'no-store' },
});

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === '/health' && request.method === 'GET') {
      return reply(200, { status: 'ok' });
    }
    if (path !== '/v1/diagnostics') {
      return reply(404, { error: 'not_found' });
    }
    if (request.method !== 'POST') {
      return reply(405, { error: 'method_not_allowed' });
    }
    const type = request.headers.get('Content-Type') ?? '';
    if (!Object.hasOwn(formats, type)) {
      return reply(415, { error: 'unsupported_content_type' });
    }
    const lengthHeader = request.headers.get('Content-Length');
    if (!lengthHeader || !/^\d+$/.test(lengthHeader)) {
      return reply(411, { error: 'content_length_required' });
    }
    const length = Number(lengthHeader);
    if (length < 1 || length > MAX_BYTES || !request.body) {
      return reply(413, { error: 'invalid_file_size', max_bytes: MAX_BYTES });
    }
    const version = request.headers.get('X-App-Version') ?? '';
    const platform = request.headers.get('X-Platform') ?? '';
    if (!/^[\w.+-]{1,64}$/.test(version) || !['windows', 'macos', 'android'].includes(platform)) {
      return reply(400, { error: 'invalid_metadata' });
    }
    try {
      const { success } = await env.UPLOAD_LIMITER.limit({
        key: request.headers.get('CF-Connecting-IP') ?? 'unknown',
      });
      if (!success) {
        return reply(429, { error: 'rate_limited' });
      }
      const id = crypto.randomUUID();
      const date = new Date().toISOString().slice(0, 10);
      const key = `diagnostics/${date}/${id}.${formats[type]}`;
      // FixedLengthStream rejects both truncated and oversized bodies and gives R2 a known length.
      const stream = new FixedLengthStream(length);
      const transfer = request.body.pipeTo(stream.writable);
      const write = env.DIAGNOSTICS.put(key, stream.readable, {
        httpMetadata: { contentType: type },
        customMetadata: { app_version: version, platform },
      });
      await Promise.all([transfer, write]);
      return reply(201, { upload_id: id });
    } catch (error) {
      console.error('Diagnostic upload failed', error);
      return reply(500, { error: 'upload_failed' });
    }
  },
} satisfies ExportedHandler<Env>;
