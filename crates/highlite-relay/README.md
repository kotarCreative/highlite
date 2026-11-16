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

| Method | Path                                 | Auth   | Purpose                           |
| ------ | ------------------------------------ | ------ | --------------------------------- |
| POST   | `/v1/sessions`                       | ingest | Upload `application/zip` capture  |
| GET    | `/v1/sessions`                       | read   | List stored sessions              |
| GET    | `/v1/sessions/{id}`                  | read   | Status, summary, and bundle links |
| GET    | `/v1/sessions/{id}/bundle.zip`       | read   | Download the compiled bundle      |
| GET    | `/v1/sessions/{id}/runs`             | read   | Pipeline runs for a session       |
| POST   | `/v1/sessions/{id}/pipelines/{name}` | read   | Start a pipeline run              |
| GET    | `/v1/pipelines`                      | read   | Configured pipelines              |
| GET    | `/v1/runs/{id}`                      | read   | Run status, exit code, and output |
| GET    | `/healthz`                           | none   | Liveness check                    |
| GET    | `/`                                  | none   | Local sessions UI                 |

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

## Local sessions UI

Serve a single-page session browser at `/` with `--ui` or `HIGHLITE_RELAY_UI=true`:

```sh
pnpm relay -- --env-file ./relay.env --ui
```

Startup prints a URL with the read token in the fragment:

```text
highlite sessions UI: http://127.0.0.1:8787/#token=...
```

The fragment is never sent to the server; the page moves it into `sessionStorage` and
clears the address bar. The UI lists sessions newest first, shows page, duration, size,
and the compiled summary, and runs configured pipelines. Uploads still come from the
embedded SDK; the UI never accepts file imports.

Recipe setup and later edits use the same compact four-step walkthrough. An explicit
**Test connection** action checks Jira credentials without saving or creating an issue;
project and issue-type dropdowns load choices from Jira instead of asking for IDs.
Sessions, Recipes, and Providers have separate views in the main navigation, so
configuration forms do not share the session-review screen.
The framework-free UI shares a central theme and reusable controls; see
[the relay UI guide](../../docs/relay-ui.md) for its structure and validation workflow.

Same-origin requests from the bundled UI are accepted even when
`HIGHLITE_RELAY_ALLOWED_ORIGINS` is empty. All other origins still need to be allowlisted.

## AI provider connections

Configure provider connections once for future recipes, independently of session
storage. Both the CLI and local UI read and update the same central config file;
changes are visible without restarting the relay. This slice stores connections
and a default model/provider. Saving a connection does **not** verify credentials;
the Jira recipe uses the selected connection when generating a draft.

Supported kinds are `openai`, `anthropic`, and `openai-compatible` (including local
servers). OpenAI and Anthropic use their standard endpoints. Compatible connections
require a base URL; HTTPS is required except for loopback HTTP endpoints. URLs must
not contain embedded credentials, query strings, or fragments.

### CLI

These commands work without a running relay or relay ingest/read tokens:

```sh
# Prompts for a hidden API key; do not put credentials in command arguments.
pnpm relay providers connect work --kind openai --model <model-id>
pnpm relay providers connect personal --kind anthropic --model <model-id>

# Local OpenAI-compatible server without authentication.
pnpm relay providers connect local --kind openai-compatible \
  --base-url http://localhost:11434/v1 --model <model-id> --no-api-key

pnpm relay providers list
pnpm relay providers default local
pnpm relay providers disconnect personal
```

For automation, use `--api-key-stdin` to read a key from a pipe or secret file.
Connection output contains metadata and `hasApiKey`, never the key itself. Connecting
an existing name updates it; CLI connections prompt for a replacement key unless
`--api-key-stdin` or `--no-api-key` is specified. An omitted key preserves an existing
key only when the kind and endpoint are unchanged. `--no-api-key` explicitly clears
any saved key on a compatible connection. Disconnect to remove a connection entirely.

The first connection becomes the default automatically; use `--default` while
connecting, or `providers default <id>`, to change it. Removing the default leaves
no default rather than silently selecting another provider.

### UI

Start a **loopback-bound** relay with `--ui`, authenticate with its read token, and
open **Providers** in the header. Add or edit a connection, replace its key, choose
the default, or disconnect it. Editing never retrieves a saved key: a blank key
preserves it only for the same provider kind and endpoint. API keys are cleared from
the form on submission, leaving Providers, and sign-out; they are never placed in
browser storage.

Provider HTTP routes require the read token, like local pipeline execution. Treat
that token as local administrative access. HTTP provider management is disabled for
non-loopback binds, and ingest tokens cannot manage providers.

| Method | Path                            | Purpose                                                               |
| ------ | ------------------------------- | --------------------------------------------------------------------- |
| GET    | `/v1/providers`                 | Metadata only, plus `enabled` and `defaultProvider`                   |
| POST   | `/v1/providers/{id}`            | Save `{ kind, model, baseUrl?, apiKey?, clearApiKey?, makeDefault? }` |
| POST   | `/v1/providers/{id}/default`    | Select the default connection                                         |
| POST   | `/v1/providers/{id}/disconnect` | Remove the connection and its credential                              |

### Central credential storage

The default folder is:

- Linux: `$XDG_CONFIG_HOME/highlite`, or `~/.config/highlite`.
- macOS: `~/Library/Application Support/Highlite`.
- Windows: `%APPDATA%/Highlite`.

Set `HIGHLITE_CONFIG_DIR` or pass `--config-dir <dir>` to either the serving command
or provider CLI commands to override it. The relay also accepts `HIGHLITE_CONFIG_DIR`
in its env file; provider CLI commands do not load relay env files, so export the
same override or pass the flag to both.

`providers.json` contains configuration and **plaintext credentials**, not encrypted
secrets. Keep it out of source control and protect backups. On Unix, the folder must
be private (`0700`) and files private (`0600`); Highlite creates them with these modes
and refuses existing files/folders with broader permissions. On Windows, restrict
the folder's ACL to the relay account. Writes use atomic replacement and a
cross-process lock so concurrent CLI/UI updates do not overwrite each other.
Malformed or unsupported config files are not overwritten. Credentials are not
included in capture bundles, provider HTTP responses, or provider CLI output.

## Jira issue recipe

The built-in `jira-issue` recipe analyzes compiled sessions with a custom prompt and
the default AI provider and can automatically draft issues for new sessions. Choose
**Review first** to edit and approve the draft, or **Publish automatically** to create
the Jira Cloud issue without review. Configure it from **Recipes** in the local UI; no
shell pipeline is required. It is disabled by default. Jira credentials live in the
private central config folder, separate from captured sessions and run output. Images
are opt-in, and ambiguous publication failures are never automatically retried.

See [the Jira recipe guide](../../docs/jira-recipe.md) for setup, HTTP endpoints,
credentials, supported models, data sharing, and recovery behavior.

## Pipelines

Pipelines are trusted local commands attached to a compiled session. They are disabled by
default. Enable them with a loopback bind:

```sh
HIGHLITE_RELAY_ALLOW_PIPELINES=true
HIGHLITE_RELAY_PIPELINE_CONCURRENCY=2
# HIGHLITE_RELAY_PIPELINES_FILE=./pipelines.json
```

The config defaults to `<data-dir>/pipelines.json` and is read at startup; restart the
relay after editing it:

```json
{
  "pipelines": [
    {
      "name": "bug-report",
      "description": "Draft a bug report from this session",
      "command": "./scripts/bug-report.sh",
      "cwd": ".",
      "timeoutSeconds": 120,
      "env": { "TEAM": "web" }
    }
  ]
}
```

- `name` (required): 1–64 letters, digits, `-`, or `_`; must be unique.
- `command` (required): run through `/bin/sh -c`, or `cmd /C` on Windows.
- `cwd`: working directory; defaults to the relay's working directory. Relative paths are
  resolved from there.
- `timeoutSeconds`: defaults to `300`. A timed-out command is killed.
- `env`: additional environment variables for the command.

Commands receive absolute paths and the session identity:

| Variable                 | Value                         |
| ------------------------ | ----------------------------- |
| `HIGHLITE_SESSION_ID`    | Session id                    |
| `HIGHLITE_RUN_ID`        | Run id                        |
| `HIGHLITE_BUNDLE_DIR`    | Compiled bundle directory     |
| `HIGHLITE_BUNDLE_ZIP`    | Zipped bundle in `downloads/` |
| `HIGHLITE_SUMMARY_PATH`  | `summary.md`                  |
| `HIGHLITE_MANIFEST_PATH` | `manifest.json`               |
| `HIGHLITE_BUNDLE_JSON`   | `bundle.json`                 |
| `HIGHLITE_REPORT_JSON`   | `report.json`                 |
| `HIGHLITE_SCRAWL_JSON`   | `scrawl.json`                 |
| `HIGHLITE_ANALYSIS_JSON` | `analysis.json`               |

A run can do anything a local shell command can, including posting the summary to an
agent or an issue tracker. Only loopback binds may enable pipelines. The relay also
removes `HIGHLITE_RELAY_INGEST_TOKEN`, `HIGHLITE_RELAY_READ_TOKEN`, and
`HIGHLITE_RELAY_WEBHOOK_SECRET` from the child environment.

`POST /v1/sessions/{id}/pipelines/{name}` returns `202` with a run record. Poll
`GET /v1/runs/{id}` for `queued`, `running`, `succeeded`, or `failed`, plus the exit code
and stdout/stderr (each truncated to 64 KiB). Runs queue up to the configured
concurrency. Anything holding the read token can start a pipeline, so keep the relay
local.

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
summary.md          paste-ready actions, narration, environment and limitations
report.json         ordered report-ready actions with evidence links
bundle.json         CompiledBundle: keyframes, crops, timeline, annotations, artifacts
scrawl.json         Scrawl v1 subset
analysis.json       capture analysis and warnings
manifest.json       compiled manifest
contact-sheet.png   selected keyframes in one image
frames/frame-*.png  cropped frames with annotations burned in
audio.*             narration, when present
```

An agent or worker should generally start with `summary.md` (human/LLM context) and then
load `report.json` (ordered observed actions) or `bundle.json` (all structured facts), plus
the referenced frames and audio as needed.

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

- Separately scoped bearer tokens for ingestion and reads, compared in constant time.
- Configuration comes from an explicit env file; keep it out of version control and mode
  `0600` because it contains tokens and the webhook secret.
- Pipelines are disabled by default, require a loopback bind, run without relay secrets in
  their environment, and are bounded by a timeout and concurrency limit.
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
  runs/<run-id>.json      pipeline run status, exit code, and output
```

Point `HIGHLITE_RELAY_DATA_DIR` at durable storage and back it up according to your retention
policy. The relay does not expire sessions automatically.
