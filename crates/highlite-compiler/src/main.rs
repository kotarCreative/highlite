use std::env;
use std::error::Error;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use highlite_compiler::{
    BundleOptions, CommandTranscriber, CompileInput, CompileOptions, HighliteManifest,
    ParakeetCliTranscriber, ScrawlExportOptions, TranscribeError, Transcriber,
    TranscriptionRequest, WhisperCliTranscriber, compile_capture, shift_transcript,
    to_scrawl_bundle, write_bundle,
};

const USAGE: &str = "\
highlite-compiler — compile a Highlite capture

Usage:
  highlite-compiler compile [--pretty] < input.json > bundle.json
  highlite-compiler scrawl  [--pretty] < input.json > scrawl.json
  highlite-compiler bundle <capture-dir> --out <bundle-dir> [options]

Input for compile/scrawl is a CompileInput object. Output is JSON on stdout.

Bundle options:
  --out <dir>                 required; where summary.md, frames/, and JSON go
  --transcribe <mode>         auto (default), off, whisper, parakeet, or command
  --transcriber-command <cmd> program that prints transcript JSON (audio path appended)
  --model <path>              whisper.cpp model (or HIGHLITE_WHISPER_MODEL)
  --whisper <path>            whisper.cpp binary (or HIGHLITE_WHISPER_BIN)
  --parakeet-model <path>     parakeet.cpp GGUF (or HIGHLITE_PARAKEET_MODEL)
  --parakeet <path>           parakeet-cli binary (or HIGHLITE_PARAKEET_BIN)
  --language <code>           ASR language hint, for example en
  --max-keyframes <n>         override the duration-based keyframe budget
  --no-crop                   keep full frames instead of compiler crops
  --no-annotations            do not burn annotations into frames
  --no-contact-sheet          skip contact-sheet.png
  --contact-sheet-width <px>  default 1600

A capture directory holds manifest.json and the media it references (frames/,
audio). The bundle command transcribes narration when the manifest has no
transcript, then writes summary.md, scrawl.json, bundle.json, analysis.json,
manifest.json, contact-sheet.png, and frames/frame-XX.png.
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TranscribeMode {
    Auto,
    Off,
    Whisper,
    Parakeet,
    Command,
}

impl TranscribeMode {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "auto" => Ok(Self::Auto),
            "off" | "none" => Ok(Self::Off),
            "whisper" => Ok(Self::Whisper),
            "parakeet" => Ok(Self::Parakeet),
            "command" => Ok(Self::Command),
            other => Err(format!(
                "unknown transcription mode {other}; expected auto, off, whisper, parakeet, or command"
            )),
        }
    }
}

#[derive(Debug, Clone)]
struct BundleArgs {
    capture: PathBuf,
    output: PathBuf,
    transcribe: TranscribeMode,
    transcriber_command: Option<String>,
    model: Option<PathBuf>,
    whisper: Option<PathBuf>,
    parakeet_model: Option<PathBuf>,
    parakeet: Option<PathBuf>,
    language: Option<String>,
    max_keyframes: Option<u32>,
    crop: bool,
    annotations: bool,
    contact_sheet: bool,
    contact_sheet_width: u32,
}

impl Default for BundleArgs {
    fn default() -> Self {
        Self {
            capture: PathBuf::new(),
            output: PathBuf::new(),
            transcribe: TranscribeMode::Auto,
            transcriber_command: None,
            model: None,
            whisper: None,
            parakeet_model: None,
            parakeet: None,
            language: None,
            max_keyframes: None,
            crop: true,
            annotations: true,
            contact_sheet: true,
            contact_sheet_width: 1600,
        }
    }
}

fn value_for(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    *index += 1;
    args.get(*index)
        .cloned()
        .ok_or_else(|| format!("{flag} needs a value"))
}

fn parse_bundle_args(args: &[String]) -> Result<BundleArgs, String> {
    let mut parsed = BundleArgs::default();
    let mut positional: Vec<&String> = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let argument = args[index].as_str();
        match argument {
            "--out" => parsed.output = PathBuf::from(value_for(args, &mut index, "--out")?),
            "--transcribe" => {
                parsed.transcribe =
                    TranscribeMode::parse(&value_for(args, &mut index, "--transcribe")?)?
            }
            "--transcriber-command" => {
                parsed.transcriber_command =
                    Some(value_for(args, &mut index, "--transcriber-command")?)
            }
            "--model" => {
                parsed.model = Some(PathBuf::from(value_for(args, &mut index, "--model")?))
            }
            "--whisper" => {
                parsed.whisper = Some(PathBuf::from(value_for(args, &mut index, "--whisper")?))
            }
            "--parakeet-model" => {
                parsed.parakeet_model = Some(PathBuf::from(value_for(
                    args,
                    &mut index,
                    "--parakeet-model",
                )?))
            }
            "--parakeet" => {
                parsed.parakeet = Some(PathBuf::from(value_for(args, &mut index, "--parakeet")?))
            }
            "--language" => parsed.language = Some(value_for(args, &mut index, "--language")?),
            "--max-keyframes" => {
                let value = value_for(args, &mut index, "--max-keyframes")?;
                parsed.max_keyframes = Some(
                    value
                        .parse()
                        .map_err(|_| format!("--max-keyframes needs a number, got {value}"))?,
                );
            }
            "--no-crop" => parsed.crop = false,
            "--no-annotations" => parsed.annotations = false,
            "--no-contact-sheet" => parsed.contact_sheet = false,
            "--contact-sheet-width" => {
                let value = value_for(args, &mut index, "--contact-sheet-width")?;
                parsed.contact_sheet_width = value
                    .parse()
                    .map_err(|_| format!("--contact-sheet-width needs a number, got {value}"))?;
            }
            flag if flag.starts_with('-') => return Err(format!("unknown option: {flag}")),
            _ => positional.push(&args[index]),
        }
        index += 1;
    }

    if let Some(capture) = positional.first() {
        parsed.capture = PathBuf::from(capture);
    } else {
        return Err("bundle needs a capture directory".to_owned());
    }
    if parsed.output.as_os_str().is_empty() {
        return Err("bundle needs --out <bundle-dir>".to_owned());
    }
    Ok(parsed)
}

fn load_input(capture: &Path, args: &BundleArgs) -> Result<CompileInput, Box<dyn Error>> {
    let input_path = capture.join("input.json");
    let manifest_path = capture.join("manifest.json");

    let mut input = if input_path.is_file() {
        serde_json::from_str(&fs::read_to_string(&input_path)?)?
    } else if manifest_path.is_file() {
        CompileInput {
            manifest: serde_json::from_str::<HighliteManifest>(&fs::read_to_string(
                &manifest_path,
            )?)?,
            frames: None,
            viewport: None,
            options: None,
        }
    } else {
        return Err(format!("{} has no manifest.json or input.json.", capture.display()).into());
    };

    let options = input.options.get_or_insert_with(CompileOptions::default);
    if let Some(max_keyframes) = args.max_keyframes {
        options.max_keyframes = Some(max_keyframes);
    }
    if !args.crop {
        options.crop = Some(false);
    }

    Ok(input)
}

fn transcriber_for(args: &BundleArgs) -> Result<Box<dyn Transcriber>, Box<dyn Error>> {
    let command = args
        .transcriber_command
        .clone()
        .or_else(|| env::var("HIGHLITE_ASR_COMMAND").ok());

    if matches!(args.transcribe, TranscribeMode::Command) {
        let command = command
            .ok_or("--transcribe command needs --transcriber-command or HIGHLITE_ASR_COMMAND.")?;
        return Ok(Box::new(CommandTranscriber::new(&command)?));
    }

    if matches!(args.transcribe, TranscribeMode::Auto)
        && let Some(command) = command
    {
        return Ok(Box::new(CommandTranscriber::new(&command)?));
    }

    let parakeet_configured =
        args.parakeet_model.is_some() || env::var_os("HIGHLITE_PARAKEET_MODEL").is_some();

    if matches!(args.transcribe, TranscribeMode::Parakeet)
        || (matches!(args.transcribe, TranscribeMode::Auto) && parakeet_configured)
    {
        let transcriber = ParakeetCliTranscriber::detect(
            args.parakeet_model.as_deref(),
            args.parakeet.as_deref(),
            args.language.as_deref(),
        )
        .ok_or(
            "Parakeet was selected, but parakeet-cli or a Parakeet GGUF is missing. \
             Pass --parakeet <parakeet-cli> and --parakeet-model <model.gguf>, set \
             HIGHLITE_PARAKEET_BIN / HIGHLITE_PARAKEET_MODEL, or use --transcribe whisper.",
        )?;
        eprintln!(
            "Transcribing with parakeet-cli ({}).",
            transcriber.model.display()
        );
        return Ok(Box::new(transcriber));
    }

    if let Some(transcriber) = WhisperCliTranscriber::detect(
        args.model.as_deref(),
        args.whisper.as_deref(),
        args.language.as_deref(),
    ) {
        eprintln!(
            "Transcribing with whisper.cpp ({}).",
            transcriber.model.display()
        );
        return Ok(Box::new(transcriber));
    }

    if matches!(args.transcribe, TranscribeMode::Whisper) {
        return Err(TranscribeError::new(
            "Whisper was selected, but whisper-cli or a model is missing. Pass \
             --whisper <whisper-cli> and --model <model.bin>, set HIGHLITE_WHISPER_BIN / \
             HIGHLITE_WHISPER_MODEL, or use --transcribe off.",
        )
        .into());
    }

    Err(TranscribeError::new(
        "No transcriber is available. For English, download a Parakeet GGUF and pass \
         --parakeet-model <model.gguf> (plus --parakeet <parakeet-cli> if it is not on PATH). \
         For Whisper, pass --model <model.bin>. You can also pass \
         --transcriber-command <program> or use --transcribe off.",
    )
    .into())
}

fn transcribe_if_needed(
    input: &mut CompileInput,
    capture: &Path,
    args: &BundleArgs,
) -> Result<(), Box<dyn Error>> {
    if matches!(args.transcribe, TranscribeMode::Off) || !input.manifest.transcript.is_empty() {
        return Ok(());
    }

    let Some(audio) = input.manifest.artifacts.audio.clone() else {
        return Ok(());
    };
    let audio_path = capture.join(&audio);
    if !audio_path.is_file() {
        return Err(format!(
            "The manifest references missing audio at {}",
            audio_path.display()
        )
        .into());
    }

    let transcriber = transcriber_for(args)?;
    let segments = transcriber.transcribe(&TranscriptionRequest {
        audio_path: &audio_path,
        language: args.language.as_deref(),
    })?;
    if segments.is_empty() {
        return Err("The transcriber returned no speech.".into());
    }

    let offset = input.manifest.audio_offset_ms.unwrap_or(0);
    let segments = shift_transcript(segments, offset, input.manifest.duration_ms);
    eprintln!(
        "Transcribed {} segment(s) (audio offset {} ms).",
        segments.len(),
        offset
    );
    input.manifest.transcript = segments;
    Ok(())
}

fn run_bundle(args: &[String]) -> Result<(), Box<dyn Error>> {
    let parsed = parse_bundle_args(args)?;
    if !parsed.capture.is_dir() {
        return Err(format!("{} is not a capture directory.", parsed.capture.display()).into());
    }
    let capture = parsed.capture.canonicalize()?;
    let mut input = load_input(&capture, &parsed)?;
    transcribe_if_needed(&mut input, &capture, &parsed)?;

    let mut compiled = compile_capture(&input);
    let written = write_bundle(
        &mut compiled,
        &capture,
        &parsed.output,
        &BundleOptions {
            annotations: parsed.annotations,
            contact_sheet: parsed.contact_sheet,
            contact_sheet_width: parsed.contact_sheet_width,
        },
    )?;

    eprintln!(
        "Wrote {} keyframe(s) and {} to {}",
        written.keyframe_paths.len(),
        written
            .contact_sheet
            .as_deref()
            .unwrap_or("no contact sheet"),
        written.directory.display()
    );
    let mut stdout = io::stdout().lock();
    stdout.write_all(written.summary.as_bytes())?;
    Ok(())
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print!("{USAGE}");
        return Ok(());
    }

    let command_index = args.iter().position(|arg| !arg.starts_with('-'));
    let command = command_index.map_or("compile", |index| args[index].as_str());
    let pretty = args.iter().any(|arg| arg == "--pretty");

    if command == "bundle" {
        return run_bundle(&args[command_index.expect("bundle is present") + 1..]);
    }

    if !matches!(command, "compile" | "scrawl") {
        return Err(format!("unknown command: {command}\n\n{USAGE}").into());
    }

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let request: CompileInput = serde_json::from_str(&input)?;
    let compiled = compile_capture(&request);

    let rendered = match command {
        "scrawl" => {
            let scrawl = to_scrawl_bundle(&compiled, &ScrawlExportOptions::default())?;
            if pretty {
                serde_json::to_string_pretty(&scrawl)?
            } else {
                serde_json::to_string(&scrawl)?
            }
        }
        _ => {
            if pretty {
                serde_json::to_string_pretty(&compiled)?
            } else {
                serde_json::to_string(&compiled)?
            }
        }
    };
    let mut stdout = io::stdout().lock();
    stdout.write_all(rendered.as_bytes())?;
    stdout.write_all(b"\n")?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
