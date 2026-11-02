# Diagnostics

Independent Cloudflare Worker for user-initiated log and chat-session uploads.

- Host: `https://diagnostics.reveric.app`
- Private R2 binding: `DIAGNOSTICS` → `reveric-diagnosis`
- `GET /health`: health check.
- `POST /v1/diagnostics`: raw file body. Required headers: `Content-Type`, `Content-Length`, `X-App-Version`, `X-Platform` (`windows`, `macos`, `android`).
- Types: `text/plain`, `application/json`, `application/zip`. Size: 1 byte through 50 MiB.
- Success: HTTP 201, `{"upload_id":"<uuid>"}`. The object key is `diagnostics/YYYY-MM-DD/<uuid>.<extension>`.
- Errors: JSON `error` code, HTTP 400/404/405/411/413/415/429/500. Clients must require 201 and a nonempty upload ID.
- Each accepted POST creates a new report; there is no automatic retry or deduplication.

Requests are anonymous. Cloudflare's rate-limit binding permits five uploads per IP per 60 seconds, per Cloudflare location. This is approximate abuse protection, not a globally consistent quota or a billing cap. Invalid metadata and oversized declared bodies are rejected before storage; FixedLengthStream enforces the actual byte count. No read/list/delete endpoint is exposed. Download through authenticated Cloudflare R2 tooling. No expiration/deletion policy is installed.

Raw diagnostics are preserved. The client uploads only after the user chooses the corresponding action. No S3 keys are embedded in the client or required by the Worker.

## Development and deployment

```sh
npm ci
npm run check
npm test
npm run dev
npm run deploy
```

Wrangler login needs Workers, R2, and custom-domain permissions. The `reveric.app` zone must be in the account, and the bucket must already exist. Deployment binds the custom domain and provisions its certificate. workers.dev and preview URLs are disabled.

Tests run the bundled Worker with local R2 and rate-limit bindings in Miniflare; they do not write production data. Production smoke tests should use clearly marked synthetic content only.
