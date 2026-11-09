# OpenCode recipe

The `opencode` recipe routes a compiled Highlite session to an **existing**
[OpenCode](https://opencode.ai/) session. It uses the relay's default AI provider to
rank eligible sessions from bounded metadata, then waits for you to confirm a target.
It never creates an OpenCode session and never submits a prompt automatically.

OpenCode's API is experimental. The relay requires the `opencode` **v2** CLI and checks
the major version before discovery. Request and response shapes were checked against
the installed OpenCode V2.0.32 CLI/OpenAPI. End-to-end recipe behavior is verified with a
fake authenticated CLI only; real OpenCode session delivery was not exercised. Treat
OpenCode upgrades as potentially breaking until the CLI contract is revalidated.

## How routing works

1. You configure a required **project directory** and a trusted prompt.
2. Discovery asks the authenticated CLI for recent sessions in that directory.
3. The relay keeps only root sessions whose `location.directory` exactly equals the
   configured directory. It excludes children (`parentID`), archived sessions, and
   nested directories. IDs must start with `ses`.
4. The AI provider receives only approved, project-scoped routing metadata:
   - the first 4096 bytes of the compiled `summary.md` (on a UTF-8 boundary),
   - optional page title and URL,
   - candidate ID, title, directory, project name, and timestamps.
     Candidate metadata is limited to the configured project directory; no message
     history, prompt history, costs, or session content is included.
5. The AI returns one candidate ID with a confidence and a short reason. A response
   outside the discovered ID list becomes **no suggestion**; you can still choose a
   target manually.
6. The run stores the exact prompt preview. Nothing is sent until you submit with
   `confirm: true`.

There is no focused-window or active-application detection. A session open in another
window does not influence the target. No automatic submission follows from a
suggestion, and no prompt history or session content is read for routing.

### Prompt contents

`promptPreview` is built once at suggestion time and is immutable for that revision:

- your trusted prompt (up to 16 KiB),
- an inline excerpt of the capture summary (up to 48 KiB with a truncation marker),
- at most 64 KiB total.

The excerpt is sent inline. The prompt never asks OpenCode to read a relay-local bundle
path, because a remote OpenCode service may not share the relay's filesystem.

## OpenCode CLI transport

The relay invokes the CLI; it does not hardcode an OpenCode service URL or read OpenCode
service/config files. OpenCode's own discovery and authentication flow applies. The CLI
may start or connect to the user's local OpenCode service while it runs; Highlite does
not manage that service or its lifetime.

```text
opencode api server.info
opencode api session.list --param limit=<n> --param order=desc --param archived=false --param directory=<dir>
opencode api project.list
opencode api session.get --param sessionID=<ses...>
opencode api session.prompt --param sessionID=<ses...> --data '<json>'
```

Binary lookup order:

1. `settings.opencodePath`
2. `HIGHLITE_OPENCODE_BIN`
3. `opencode` on `PATH`

A configured path containing `/` must be absolute. The relay spawns the CLI without a
shell, with `NO_COLOR=1`, bounded stdout/stderr and timeouts (discovery 20 s, session get
10 s, prompt 30 s). It removes `HIGHLITE_RELAY_*` and `HIGHLITE_CONFIG_DIR` from the
child environment. Only the HTTP status on stderr is classified; raw stdout/stderr and
prompt text are never stored in errors or activity.

## Configuration

All recipe endpoints require the relay **read token**. Configuration, discovery, run
start, and submission are loopback-only.

`OpenCodeSettings`:

```json
{
  "enabled": false,
  "autoDraft": false,
  "directory": "/Users/me/work/app",
  "prompt": "Route this capture to the session that matches the work shown.",
  "opencodePath": null,
  "maxCandidates": 30
}
```

Validation:

- `directory` is required. While enabled it must be a non-empty absolute path; empty is
  allowed only while disabled.
- `prompt` is non-empty, at most 16 KiB, and contains no NUL.
- `opencodePath` is `null` or a valid path as described above.
- `maxCandidates` is 5–50; the default is 30.
- Enabling the recipe requires a default AI provider.

Saving configuration does not run discovery or verify the OpenCode path. `autoDraft`
only creates a pending suggestion; it does not submit.

| Method | Path                                        | Purpose                                   |
| ------ | ------------------------------------------- | ----------------------------------------- |
| GET    | `/v1/recipes/opencode`                      | Recipe version, settings, management flag |
| POST   | `/v1/recipes/opencode`                      | Save `{settings}` (loopback only)         |
| POST   | `/v1/recipes/opencode/discover`             | Discover sessions and projects            |
| GET    | `/v1/sessions/{id}/recipes/opencode`        | Return `{run}` or `{run: null}`           |
| POST   | `/v1/sessions/{id}/recipes/opencode`        | Start analysis; `202`                     |
| POST   | `/v1/sessions/{id}/recipes/opencode/submit` | Confirm and submit; `202`                 |
| GET    | `/v1/activity?limit=25`                     | Recent recipe activity metadata           |

Discovery returns the CLI version, the configured directory, eligible candidates, and
project names. It returns metadata only: no messages, histories, costs, tokens, or
capture content. Candidate titles are truncated to 200 characters, directories to 512,
and project names to 200. Missing titles become `"Untitled session"`. OpenCode epoch
seconds are normalized to milliseconds.

## Run lifecycle

```text
queued -> analyzing -> suggested | failed
suggested | failed -> submitting -> submitted | failed | submit-unknown
```

- `suggested` is the normal pending state. It persists until you act.
- `failed` before submission can be regenerated.
- `failed` after a clear submission rejection can be retried with the same revision and
  target.
- `submitted` and `submit-unknown` are terminal.
- On restart, interrupted `queued`/`analyzing` runs become `failed` (regenerate), while
  `submitting` becomes `submit-unknown` (check OpenCode manually).

Each run stores its settings snapshot, resolved provider metadata, eligible session IDs,
candidates, suggestion, prompt preview, revision, target details, timestamps, and a safe
error. It does not store provider keys or OpenCode credentials.

### Submit guards

Before any CLI call, submission requires:

- `confirm` exactly `true`,
- an enabled recipe,
- the current `settings.directory` to equal the run's stored directory,
- a `sessionId` from `run.eligibleSessionIds`,
- a `session.get` revalidation showing the same directory, no parent, and no archive,
- a `suggested` run or a clear-rejection `failed` run with the matching revision.

`submitted` returns the existing run. `submitting` and `submit-unknown` return `409`.

The submission body sends the **stored** `promptPreview` exactly:

```json
{
  "id": "msg_<deterministic>",
  "text": "<stored promptPreview>",
  "delivery": "queue"
}
```

The deterministic ID is `msg_` plus the first 32 hex characters of
`sha256("highlite\0<sessionId>\0<revision>\0<opencodeSessionId>")`. It is a hint, not an
exactly-once guarantee.

## Failure handling

- Exit 0 with a valid `msg_` message ID **and** a returned `data.sessionID` equal to the
  chosen target: `submitted`, recording the actual ID, target title/session, and
  submission time. This confirms queued admission by OpenCode, not agent execution or
  completion of the work.
- Non-zero with `HTTP 400`, `401`, `403`, or `404`: clear rejection, `failed`.
- Any other failure (`409`, `429`, `5xx`, timeout, missing HTTP status, or an invalid
  exit-0 body such as a missing/invalid message ID or mismatched `data.sessionID`):
  `submit-unknown`.
- `submit-unknown` is never retried automatically. Check OpenCode manually before
  deciding what happened.
- Errors never include raw CLI output, prompt text, or credentials.

## Activity

`GET /v1/activity?limit=25` returns the most recently updated recipe runs, newest first.
`limit` is 1–100. Items are metadata only:

```json
{
  "recipe": "opencode",
  "sessionId": "hl-...",
  "status": "suggested",
  "updatedAtMs": 1760000000000,
  "title": "Checkout page",
  "opencodeSessionId": "ses_...",
  "opencodeTitle": "Checkout bug",
  "error": null
}
```

Activity never includes prompts, drafts, capture summaries, candidate lists, or raw
errors. Malformed run files are skipped and errors are truncated.

## Storage and privacy

- Recipe settings live in the central relay config directory alongside
  `providers.json`. Run state is stored privately under `<data-dir>` with private,
  atomic writes.
- OpenCode authentication is managed by the OpenCode CLI. The relay stores no OpenCode
  token and the native app stores none.
- AI routing sends only the bounded capture excerpt and candidate metadata. Treat
  capture text as untrusted data; the model output is restricted to one candidate ID,
  confidence, and a short reason.
- The full prompt is sent only after explicit confirmation.

## Testing

```sh
pnpm test:opencode
```

This builds `highlite-relay` and runs the recipe against a local fake authenticated
OpenCode CLI, a fake OpenAI-compatible AI endpoint, and a real relay. It uses temporary
directories under `/tmp/opencode` when available. No real OpenCode service, session
history, provider key, or paid model call is used.

The smoke test covers exact-directory discovery, child/archived/other-project exclusion,
newest-first candidate capping, version-major rejection, eligible-ID enforcement, AI
suggestion and hallucinated IDs, no candidates without an AI call, AI failure, no
automatic submission, prompt-preview immutability, confirm/revision/directory and
pre-submit revalidation guards, preview-equals-sent, invalid exit-0 and HTTP 401/404/409
classification, clear rejection versus `submit-unknown`, no automatic retry, CLI
environment and call-order hygiene, and activity redaction.

Known limitations:

- Only existing OpenCode sessions are supported; new sessions are out of scope.
- There is no exactly-once delivery guarantee.
- Real OpenCode session delivery, real session histories, provider credentials, and the
  native macOS app integration were not verified by this smoke test.
- The OpenCode API is experimental, and real-tenant behavior still needs validation with
  your installed CLI and sessions.
- The web relay UI remains Jira-only in this slice.
