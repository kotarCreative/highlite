# Jira issue recipe

The built-in `jira-issue` recipe, version `1.1.0`, turns a compiled Highlite session
into a Jira issue using your custom prompt and the relay's **default AI provider**.
It can draft automatically when a new upload compiles successfully, then either wait
for you to review the issue or publish it automatically. **Review first** is the
default; uploading a session never posts to Jira until you explicitly enable
automatic publishing.

This implementation targets **Jira Cloud REST v3**, using an account email and an
unscoped Atlassian API token with access to the site. Jira Data Center and scoped-token
gateway URLs are not supported in this first slice. The account needs Browse projects
and Create issues permissions for the destination project.

## Set up in the UI

1. Configure an AI connection under **Providers**, and select it as the default.
2. Open **Recipes** in a loopback-bound relay started with `--ui`.
3. Enter your Jira site origin (for example `https://team.atlassian.net`), account
   email, API token, project key, and numeric issue type ID.
4. Write the custom analysis prompt. For example:

   > Focus on user-facing defects in the checkout flow. Include reproduction steps,
   > observed behavior, expected behavior supported by the narration, and evidence
   > timestamps. Identify missing evidence rather than inventing it.

5. Optionally supply static extra Jira fields as a JSON object, such as
   `{"labels":["highlite"],"customfield_10010":{"value":"Web"}}`. These accommodate
   fields required by your project's create screen; the LLM cannot populate arbitrary
   Jira fields or override the destination.
6. Choose **After drafting**:
   - **Review first** (default) creates a draft and waits for you to edit and approve it.
   - **Publish automatically to Jira** posts each successfully generated draft without
     review. This also applies when you manually regenerate a draft with the recipe
     configured for automatic publication.

7. Optionally enable **Automatically draft new sessions**, then save. This starts the
   flow when a new session compiles; with it off, you can still start the flow manually
   for any ready session.

Use the issue type **ID**, not its display name. Project administrators can find IDs
in Jira settings, or use Jira's create-issue metadata endpoint
`GET /rest/api/3/issue/createmeta/{projectIdOrKey}/issuetypes`. Required custom fields
and allowed values vary by project and issue type; automatic discovery is not yet
part of the setup form.

Saving stores configuration; it does not verify Jira credentials or create an issue.
API tokens are never retrieved by the UI. A blank token on edit preserves the saved
token only for the same site and account email; changing either requires a new token.

## Publication modes

Newly compiled sessions queue drafts without delaying ingestion for the model's
response. Automatic drafting is opt-in and does not backfill historical sessions.
Repeated uploads of an already compiled session do not generate another draft.

Select a session to see its **Jira issue** section. Existing sessions can use the
generation button manually. The publication mode chosen when the draft was generated
is shown with the destination and provider/model.

- **Review first** stops at `draft`. Review the summary and description, edit as
  necessary, save the changes, then choose **Publish to Jira** and confirm. Draft edits
  and approvals carry a revision so a stale tab cannot publish changed content.
- **Publish automatically** posts the validated draft immediately. There is no review
  step, so treat this as a deliberate automation setting rather than a convenience
  default. The issue uses the destination captured in that run's settings; later
  configuration changes require regenerating the draft. A manual **Generate & publish**
  action asks for confirmation because it cannot be undone.

The result includes the Jira issue key and a link to the issue. Description text is
converted deterministically to Atlassian Document Format paragraphs, not interpreted
as HTML or executed as markup.

Each session has one recipe run. In review mode, **Regenerate Jira draft** replaces an
unpublished draft and its edits with a new analysis using the current settings. In
automatic mode the regenerated draft is published immediately. Failed generation can
be retried manually. Published issues and uncertain publications cannot be regenerated
or automatically republished through this recipe.

Changing the publication mode does not retroactively publish an existing review draft;
it applies the next time a draft is generated. If analysis is still running when you
switch to review, automatic publication rechecks the setting and stops before contacting
Jira, leaving a reviewable draft. A Jira request that has already been dispatched cannot
be recalled. The run records the recipe version,
prompt/settings snapshot (including publication mode), resolved AI provider and model,
revision, draft, errors, and external issue reference—but no provider key or Jira API
token. If Jira destination settings change after drafting, regenerate the draft before
publishing to the new destination. Changes to the prompt alone do not alter an existing
draft.

## Privacy and model support

- The AI provider receives `summary.md`, `bundle.json`, and `analysis.json`, which
  include narration/transcript and recorded interaction context. Capture content is
  treated as untrusted evidence, not instructions. Jira credentials are never sent
  to the model, and model output is restricted to summary/description strings.
- Images are **off by default**. Opting in sends `contact-sheet.png` to the configured
  model when available. Captured pixels are not automatically redacted; review the
  capture surface before enabling this. The chosen model must support image inputs.
- Raw audio, the original capture ZIP, and individual frame files are not uploaded by
  this recipe. Jira receives the issue fields—reviewed, or automatically approved when
  that mode is enabled—and a Highlite session identity property; it does not receive
  the prompt, original bundle, or media attachments.
- OpenAI Chat Completions, Anthropic Messages, and OpenAI-compatible chat endpoints
  use a shared generation interface. Compatible servers need not support JSON mode;
  the recipe still validates the returned JSON locally. Unsupported models, refusals,
  truncated responses, and invalid drafts fail visibly rather than silently switching
  providers, dropping requested images, or publishing malformed content.
- Each input text file is limited to 256 KiB and combined text to 512 KiB; the optional
  contact sheet is limited to 4 MiB. Issue summaries are at most 255 characters and
  descriptions at most 32 KiB. Oversized evidence fails explicitly, not silently
  truncated. Provider-specific context/image limits can be lower.

Disabling the recipe stops future automatic drafts and prevents publishing. Queued
analysis rechecks that it is enabled before contacting the model; an already dispatched
request cannot be recalled. Generation and publication share the relay's bounded run
concurrency (`HIGHLITE_RELAY_PIPELINE_CONCURRENCY`).

## Storage, authentication, and failure handling

Recipe settings and the **plaintext Jira token** live in
`<central-config-dir>/jira-recipe.json`, alongside `providers.json`. The same central
folder overrides and private file permissions apply. Keep configuration and backups
out of source control. Runtime state lives in `<data-dir>/recipe-runs/` with private,
atomic writes and cross-process locking. Run files can contain sensitive captured
text and generated issue content; protect the data directory and its backups too.

All recipe endpoints require the relay read token, **including publication**; treat
it as administrative access and never give it to the embedded browser SDK. Configuration
changes additionally require a loopback bind. Once explicitly configured, the curated
recipe can run on a non-loopback relay without enabling shell pipelines.

Publication first persists `publishing`, then dispatches the Jira request. Concurrent
publish attempts cannot create multiple requests for the same draft, and publishing
an already published run simply returns its recorded result. Draft edits and approvals
carry a revision to prevent stale tabs from approving changed content.

- An explicit Jira 4xx rejection returns the run to `draft` with a safe error. In
  automatic mode this stops the run at review, allowing a deliberate manual retry after
  fixing the problem. To change destination fields, regenerate the draft after updating
  the recipe settings.
- A timeout, network failure, 5xx, unexpected response, or restart during publication
  leaves the run `publish-unknown`. **Check Jira manually** for an existing issue.
  Highlite will not automatically retry or offer another create request for that run.
  If no issue was created, create it manually from the saved draft in this first slice.
- Interrupted queued/analyzing runs become `failed` on restart and can be regenerated
  manually. Automatic publication does not resume after a restart. Drafts and published
  results survive restarts. Missing work is not automatically backfilled after an
  abrupt shutdown.
- Remote response bodies and raw model responses are not logged or persisted on
  failure, so upstream errors cannot echo credentials into run records.

## HTTP interface

| Method | Path                                           | Purpose                                                                   |
| ------ | ---------------------------------------------- | ------------------------------------------------------------------------- |
| GET    | `/v1/recipes/jira-issue`                       | Credential-free settings, version, `hasApiToken`, and `managementEnabled` |
| POST   | `/v1/recipes/jira-issue`                       | Save `{settings, apiToken?}`; loopback only                               |
| GET    | `/v1/sessions/{id}/recipes/jira-issue`         | Return `{run}` (`null` if none)                                           |
| POST   | `/v1/sessions/{id}/recipes/jira-issue`         | Generate/retry/regenerate a draft; may publish automatically; `202`       |
| POST   | `/v1/sessions/{id}/recipes/jira-issue/draft`   | Save `{revision, draft: {summary, description}}`                          |
| POST   | `/v1/sessions/{id}/recipes/jira-issue/publish` | Approve `{revision}` for publication; `202`, then poll the run            |

`settings` has the following shape. Omit `apiToken` on updates to preserve the token
for the same account; never embed it in a URL or command argument.

```json
{
  "settings": {
    "enabled": true,
    "autoDraft": true,
    "publishMode": "review",
    "includeImages": false,
    "prompt": "Draft an evidence-backed bug report with reproduction steps.",
    "jira": {
      "siteUrl": "https://team.atlassian.net",
      "email": "person@example.com",
      "projectKey": "TEAM",
      "issueTypeId": "10001",
      "extraFields": { "labels": ["highlite"] }
    }
  },
  "apiToken": "replace-in-a-private-request-body"
}
```

## Validation

`pnpm check` includes mocked-network tests for automatic drafting, both publication
modes, prompt/provider resolution, output validation, review revisions, one-time
publication, Jira formatting, credential redaction, and ambiguous failures.
`pnpm test:recipes` drives the actual relay UI in Chromium against local fake AI/Jira
endpoints—no live credentials or paid model calls are needed. Real Jira tenant
configuration and model compatibility still need verification with your own connections.

Protocol references:

- [Jira Cloud create issue](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-post)
- [Jira Cloud basic authentication](https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/)
- [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create/)
- [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create)
