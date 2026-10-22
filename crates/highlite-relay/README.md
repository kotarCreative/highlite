# highlite-relay (Rust)

Authenticated relay that accepts a Highlite session ZIP, compiles it with the canonical
compiler, and stores a downloadable agent bundle. The SDK can post the archive
automatically after `stop()`.

## Run

Copy the example configuration and replace the secrets:

```sh
cp crates/highlite-relay/relay.env.example relay.env
chmod 600 relay.env
# edit relay.env
highlite-relay --env-file ./relay.env
```

With the workspace scripts:

```sh
pnpm relay -- --env-file ./relay.env
```

`--env-file` is repeatable; later files override earlier ones. Process environment
variables override the file, and the `--bind` / `--data-dir` command-line overrides take
precedence over both. `HIGHLITE_RELAY_ENV_FILE` can provide a default path.

The config file is ordinary dotenv syntax. See
[`relay.env.example`](relay.env.example) for every supported setting, including limits,
webhooks, and optional relay-side transcription.

```sh
# A production deployment can layer a base file with a secret file.
highlite-relay --env-file ./relay.env --env-file /run/secrets/highlite-relay.env
```

## Compiler settings

The relay passes env-backed options into `compile_capture` and `write_bundle`. Unset
values keep the compiler's normal behavior.

| Env var                              | Default                    | Effect                         |
| ------------------------------------ | -------------------------- | ------------------------------ |
| `HIGHLITE_RELAY_MAX_KEYFRAMES`       | duration-based 6–12 budget | Override the keyframe cap      |
| `HIGHLITE_RELAY_MIN_GAP_MS`          | `500`                      | Minimum gap between keyframes  |
| `HIGHLITE_RELAY_CLAUSE_GAP_MS`       | `1500`                     | Narration clause gap           |
| `HIGHLITE_RELAY_CROP_PADDING_PX`     | `24`                       | Padding around planned crops   |
| `HIGHLITE_RELAY_CROP`                | `true`                     | Crop frames to targets         |
| `HIGHLITE_RELAY_COVERAGE`            | `true`                     | Coverage-based frame selection |
| `HIGHLITE_RELAY_SPEECH_CUES`         | `true`                     | Spoken-cue frame selection     |
| `HIGHLITE_RELAY_CUE_WINDOW_MS`       | `1200`                     | Spoken-cue search window       |
| `HIGHLITE_RELAY_BURN_ANNOTATIONS`    | `true`                     | Burn annotations into frames   |
| `HIGHLITE_RELAY_CONTACT_SHEET`       | `true`                     | Write `contact-sheet.png`      |
| `HIGHLITE_RELAY_CONTACT_SHEET_WIDTH` | `1600`                     | Contact sheet width in pixels  |

`HIGHLITE_RELAY_COMPILED_AT` is intentionally not exposed; the compiler uses the
manifest's creation time.

## Endpoints

| Method | Path                           | Auth   | Purpose                           |
| ------ | ------------------------------ | ------ | --------------------------------- |
| POST   | `/v1/sessions`                 | ingest | Upload `application/zip` capture  |
| GET    | `/v1/sessions/{id}`            | read   | Status, summary, and bundle links |
| GET    | `/v1/sessions/{id}/bundle.zip` | read   | Download the compiled bundle      |
| GET    | `/healthz`                     | none   | Liveness check                    |

```sh
curl -X POST http://127.0.0.1:8787/v1/sessions \
  -H "Authorization: Bearer $HIGHLITE_INGEST_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @highlite-session.zip

curl -H "Authorization: Bearer $HIGHLITE_READ_TOKEN" \
  http://127.0.0.1:8787/v1/sessions/<session-id>

curl -H "Authorization: Bearer $HIGHLITE_READ_TOKEN" \
  -o bundle.zip \
  http://127.0.0.1:8787/v1/sessions/<session-id>/bundle.zip
```

A successful POST returns the session metadata immediately, or `200` when the same
session was already compiled. Uploads are compiled synchronously; duplicate concurrent
uploads for one session return `409`.

## Consuming compiled sessions

The browser only needs the ingest token. Keep the read token on a trusted backend:

1. The browser receives `relay-uploaded` with `sessionId`, `statusUrl`, `bundleUrl`, and
   the compiled `summary`. Forward the `sessionId` to your backend, or let the backend
   consume it from the shared data directory.
2. The backend calls `GET /v1/sessions/{id}` with `Authorization: Bearer $READ_TOKEN` to
   confirm the session is `ready` and read its summary.
3. The backend calls `GET /v1/sessions/{id}/bundle.zip` with the same read token and
   unpacks the bundle.

The ZIP contains the same agent bundle the CLI writes:

```text
summary.md          paste-ready narration and actions
bundle.json         CompiledBundle: keyframes, crops, timeline, annotations, artifacts
scrawl.json         Scrawl v1 subset
analysis.json       capture analysis and warnings
manifest.json       compiled manifest
contact-sheet.png   selected keyframes in one image
frames/frame-*.png  cropped frames with annotations burned in
audio.*             narration, when present
```

An agent or worker should generally start with `bundle.json` (structured facts) and
`summary.md` (human/LLM context), then load the referenced frames and audio as needed.

The relay also has an optional webhook, so a consumer can be notified when a session is
compiled instead of polling.

## Webhooks

Configure a consumer endpoint and a signing secret in the env file:

```sh
HIGHLITE_RELAY_WEBHOOK_URL=https://consumer.example.com/hooks/highlite
HIGHLITE_RELAY_WEBHOOK_SECRET=replace-with-at-least-32-random-characters
HIGHLITE_RELAY_WEBHOOK_ATTEMPTS=3
HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS=5
```

The secret must be at least 16 characters; 32+ random characters are recommended.
Webhook URLs must use HTTPS unless they target loopback.

Events:

- `session.ready` — the compiled bundle is available.
- `session.failed` — extraction or compilation failed; the payload contains the error.

Payload:

```json
{
  "event": "session.ready",
  "deliveryId": "webhook-...",
  "occurredAtMs": 1792687057283,
  "sessionId": "8f7f...",
  "session": {
    "sessionId": "8f7f...",
    "status": "ready",
    "receivedAtMs": 1792687057000,
    "bytes": 903,
    "summary": "...",
    "statusUrl": "/v1/sessions/8f7f...",
    "bundleUrl": "/v1/sessions/8f7f.../bundle.zip"
  }
}
```

Headers:

```text
X-Highlite-Event:      session.ready
X-Highlite-Delivery:   webhook-...
X-Highlite-Timestamp:  1792687057
X-Highlite-Signature:  sha256=<hex>
Content-Type:          application/json
```

The signature is HMAC-SHA256 over:

```text
<timestamp>.<raw request body>
```

Verify it against the raw body before parsing JSON, and reject timestamps outside a short
window. Reuse `X-Highlite-Delivery` to de-duplicate retries, which use the same delivery
id. Redirects are not followed.

```ts
import { createHmac, timingSafeEqual } from 'node:crypto';

const timestamp = request.headers['x-highlite-timestamp'];
const received = request.headers['x-highlite-signature'];
const expected = `sha256=${createHmac('sha256', process.env.HIGHLITE_WEBHOOK_SECRET!)
  .update(`${timestamp}.${rawBody}`)
  .digest('hex')}`;

if (
  !timestamp ||
  !received ||
  Math.abs(Date.now() / 1000 - Number(timestamp)) > 300 ||
  received.length !== expected.length ||
  !timingSafeEqual(Buffer.from(received), Buffer.from(expected))
) {
  throw new Error('Invalid Highlite webhook signature');
}
```

Failed deliveries are retried for network errors, timeouts, `408`, `429`, and `5xx`
responses, with exponential backoff. Delivery state is stored in
`sessions/<id>.json` under `webhook` (`pending`, `delivered`, or `failed`) and pending
deliveries are resumed when the relay restarts. Webhook delivery is asynchronous, so the
upload response does not wait for the consumer.

## SDK configuration

```ts
const capture = createHighlite({
  relay: {
    endpoint: 'https://relay.example.com/v1/sessions',
    token: import.meta.env.VITE_HIGHLITE_INGEST_TOKEN,
  },
});
```

`relay.autoUpload` defaults to `true`; set it to `false` to upload manually with
`await capture.upload()`. `stop()` still resolves with the local bundle if the relay is
unreachable, and emits `relay-failed`. Successful uploads emit `relay-uploaded`.

The ingest token is visible to the browser. Treat it as a scoped capability, not a
server secret: serve the relay over HTTPS, put it behind a reverse proxy with its own
rate limits/WAF, rotate the token, and configure `HIGHLITE_RELAY_ALLOWED_ORIGINS` and
`HIGHLITE_RELAY_ALLOWED_HOSTS` for the exact frontend and relay hostnames. Keep the read token on the
server side; the browser does not need it.

## Security controls

- Separate bearer tokens for ingestion and reads, compared in constant time.
- Configuration comes from an explicit env file; keep it out of version control and mode
  `0600` because it contains tokens and the webhook secret.
- Optional `Host` allowlist to reduce DNS-rebinding exposure.
- Optional CORS `Origin` allowlist; disallowed browser origins receive `403`.
- Upload size, uncompressed size, file-count, path-depth, and symlink limits.
- ZIP entries are rejected unless they stay inside the extraction directory.
- Session ids are validated before they are used in filesystem paths.
- Compile concurrency is bounded, and duplicate in-flight sessions are rejected.
- Request bodies must be `application/zip`; redirects are not followed by the SDK.
- Webhooks are HMAC-SHA256 signed, timestamped, delivery-id-stamped, and never follow
  redirects; non-loopback endpoints must use HTTPS.
- Uploaded archives are deleted after extraction unless `HIGHLITE_RELAY_KEEP_UPLOADS=true`.

The relay does not transcribe narration by default. Set `HIGHLITE_RELAY_TRANSCRIBER_COMMAND` (or
`HIGHLITE_ASR_COMMAND`) to run an ASR command that prints transcript JSON on stdout, for
example the same command accepted by `highlite-compiler bundle --transcribe command`.
Without it, the bundle keeps the audio and records a warning that narration was not
transcribed.

## Storage layout

```text
highlite-relay-data/
  inbox/                  temporary extraction (removed after each upload)
  sessions/<id>.json      status, summary, links, and webhook delivery state
  bundles/<id>/           compiled bundle directory
  downloads/<id>.zip      zipped compiled bundle
  uploads/<id>.zip        original upload, only with HIGHLITE_RELAY_KEEP_UPLOADS
```

Point `HIGHLITE_RELAY_DATA_DIR` at durable storage and back it up according to your retention
policy. The relay does not expire sessions automatically.
