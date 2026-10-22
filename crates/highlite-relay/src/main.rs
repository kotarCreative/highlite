use std::env;
use std::error::Error;

use highlite_relay::{build_app, config_from_args, resume_pending_webhooks};
use tokio::net::TcpListener;

const USAGE: &str = "\
highlite-relay — receive and compile Highlite capture bundles

Usage:
  highlite-relay --env-file <path> [--env-file <path> ...]

Options:
  --env-file <path>   relay configuration file; repeatable, later files win
  --bind <addr>       listen address override
  --data-dir <dir>    storage root override
  --ui                serve the local sessions UI at /
  -h, --help          show this help

All relay settings live in the env file. Process environment variables override
the file, and --bind / --data-dir override both. Supported names:

  HIGHLITE_RELAY_BIND                    default 127.0.0.1:8787
  HIGHLITE_RELAY_DATA_DIR                default ./highlite-relay-data
  HIGHLITE_RELAY_INGEST_TOKEN            comma-separated ingest tokens
  HIGHLITE_RELAY_READ_TOKEN              comma-separated read tokens
  HIGHLITE_RELAY_ALLOWED_HOSTS           comma-separated Host allowlist
  HIGHLITE_RELAY_ALLOWED_ORIGINS         comma-separated browser Origin allowlist
  HIGHLITE_RELAY_MAX_UPLOAD_MB           default 64
  HIGHLITE_RELAY_MAX_UNCOMPRESSED_MB     default 256
  HIGHLITE_RELAY_MAX_FILES               default 2000
  HIGHLITE_RELAY_CONCURRENCY             default 2
  HIGHLITE_RELAY_KEEP_UPLOADS            true or false, default false
  HIGHLITE_RELAY_UI                      serve the local sessions UI
  HIGHLITE_RELAY_ALLOW_PIPELINES         allow local pipeline commands
  HIGHLITE_RELAY_PIPELINES_FILE          default <data-dir>/pipelines.json
  HIGHLITE_RELAY_PIPELINE_CONCURRENCY    default 2
  HIGHLITE_RELAY_TRANSCRIBER_COMMAND     ASR command; audio path is appended
  HIGHLITE_RELAY_LANGUAGE                ASR language hint
  HIGHLITE_RELAY_MAX_KEYFRAMES           compiler keyframe cap (default: compiler default)
  HIGHLITE_RELAY_MIN_GAP_MS              minimum keyframe gap
  HIGHLITE_RELAY_CLAUSE_GAP_MS           narration clause gap
  HIGHLITE_RELAY_CROP_PADDING_PX         crop padding in pixels
  HIGHLITE_RELAY_CROP                    true or false; crop keyframes
  HIGHLITE_RELAY_COVERAGE                true or false; coverage selection
  HIGHLITE_RELAY_SPEECH_CUES             true or false; spoken-cue selection
  HIGHLITE_RELAY_CUE_WINDOW_MS           spoken-cue search window
  HIGHLITE_RELAY_BURN_ANNOTATIONS        true or false, default true
  HIGHLITE_RELAY_CONTACT_SHEET           true or false, default true
  HIGHLITE_RELAY_CONTACT_SHEET_WIDTH     contact sheet width, default 1600
  HIGHLITE_RELAY_WEBHOOK_URL             signed completion webhook
  HIGHLITE_RELAY_WEBHOOK_SECRET          HMAC-SHA256 secret, 16+ characters
  HIGHLITE_RELAY_WEBHOOK_TIMEOUT_SECONDS default 5
  HIGHLITE_RELAY_WEBHOOK_ATTEMPTS        default 3

HIGHLITE_RELAY_ENV_FILE can supply a default env-file path.
HIGHLITE_ASR_COMMAND is accepted as a fallback for the transcriber command.

Endpoints:
  POST /v1/sessions              ingest an application/zip capture
  GET  /v1/sessions              list sessions
  GET  /v1/sessions/{id}         session status and summary
  GET  /v1/sessions/{id}/bundle.zip
  GET  /v1/sessions/{id}/runs    pipeline runs for a session
  POST /v1/sessions/{id}/pipelines/{name}
  GET  /v1/pipelines             configured pipelines
  GET  /v1/runs/{id}             pipeline run status and output
  GET  /healthz
  GET  /                         local sessions UI with --ui

POST /v1/sessions requires an ingest token; all other /v1 routes require a
read token. When HIGHLITE_RELAY_ALLOWED_ORIGINS is empty, browsers cannot call
the relay cross-origin. When HIGHLITE_RELAY_ALLOWED_HOSTS is empty for a
concrete bind address, that address is accepted automatically.
";

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args
        .iter()
        .any(|argument| argument == "--help" || argument == "-h")
    {
        print!("{USAGE}");
        return Ok(());
    }

    let config = config_from_args(&args)?;
    if config.read_tokens.is_empty() {
        eprintln!("warning: no read token configured; session reads are disabled.");
    }
    if config.allowed_hosts.is_empty() {
        eprintln!("warning: no allowed host configured; Host header checks are disabled.");
    }
    if config.allowed_origins.is_empty() {
        if config.ui {
            eprintln!(
                "note: no allowed origin configured; only same-origin requests from the bundled UI are accepted."
            );
        } else {
            eprintln!("warning: no allowed origin configured; browser uploads will fail CORS.");
        }
    }
    if config.webhook.is_none() {
        eprintln!("note: no webhook configured; consumers must poll session status.");
    }

    let app = build_app(config.clone())?;
    let resumed = resume_pending_webhooks(config.clone()).await?;
    if resumed > 0 {
        eprintln!("resumed {resumed} pending webhook delivery(ies).");
    }
    let listener = TcpListener::bind(&config.bind).await?;
    let address = listener.local_addr()?;
    eprintln!(
        "highlite-relay listening on http://{address} (data: {})",
        config.data_dir.display()
    );
    if config.ui {
        let mut ui_address = address;
        if ui_address.ip().is_unspecified() {
            ui_address.set_ip(std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST));
        }
        match config.read_tokens.first() {
            Some(token) => {
                eprintln!("highlite sessions UI: http://{ui_address}/#token={token}")
            }
            None => eprintln!(
                "highlite sessions UI: http://{ui_address}/ (reads are disabled until a read token is configured)"
            ),
        }
    }
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
