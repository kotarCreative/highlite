//! Narration transcription.
//!
//! The compiler owns transcription so a capture can be compiled on a laptop, a
//! CI machine, or a server without a browser-side ASR integration. Backends are
//! deliberately small: a whisper.cpp subprocess and a generic JSON command.
//! The core compiler stays pure; only these adapters touch the filesystem.

use std::error::Error;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;

use crate::model::{TranscriptSegment, WordTiming};

#[derive(Debug, Clone)]
pub struct TranscribeError {
    message: String,
}

impl TranscribeError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for TranscribeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for TranscribeError {}

pub struct TranscriptionRequest<'a> {
    pub audio_path: &'a Path,
    pub language: Option<&'a str>,
}

/// A narration transcriber. Returned segments use the audio's own time base;
/// [`shift_transcript`] moves them onto the session clock.
pub trait Transcriber {
    fn transcribe(
        &self,
        request: &TranscriptionRequest<'_>,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError>;
}

/// Move ASR timings from the audio clock onto the session clock.
pub fn shift_transcript(
    segments: Vec<TranscriptSegment>,
    offset_ms: u64,
    duration_ms: u64,
) -> Vec<TranscriptSegment> {
    segments
        .into_iter()
        .filter_map(|mut segment| {
            if segment.text.trim().is_empty() {
                return None;
            }
            segment.start_ms = segment.start_ms.saturating_add(offset_ms);
            segment.end_ms = segment.end_ms.saturating_add(offset_ms);
            if duration_ms > 0 && segment.start_ms >= duration_ms {
                return None;
            }
            if duration_ms > 0 {
                segment.end_ms = segment.end_ms.min(duration_ms);
            }
            if segment.end_ms <= segment.start_ms {
                segment.end_ms = segment.start_ms.saturating_add(1);
            }
            segment.text = segment.text.trim().to_owned();

            segment.word_timings.retain_mut(|word| {
                word.start_ms = word.start_ms.saturating_add(offset_ms);
                word.end_ms = word.end_ms.saturating_add(offset_ms);
                if duration_ms > 0 {
                    word.start_ms = word.start_ms.min(duration_ms);
                    word.end_ms = word.end_ms.min(duration_ms);
                }
                word.end_ms > word.start_ms && !word.text.trim().is_empty()
            });

            Some(segment)
        })
        .collect()
}

#[derive(Debug, Clone)]
pub struct WhisperCliTranscriber {
    pub binary: PathBuf,
    pub model: PathBuf,
    pub ffmpeg: PathBuf,
    pub language: Option<String>,
}

impl WhisperCliTranscriber {
    /// Build a backend from explicit paths, falling back to environment
    /// variables and `PATH` lookups for the binary and ffmpeg.
    pub fn detect(
        model: Option<&Path>,
        binary: Option<&Path>,
        language: Option<&str>,
    ) -> Option<Self> {
        let model = model
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os("HIGHLITE_WHISPER_MODEL").map(PathBuf::from))?;
        let binary = binary
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os("HIGHLITE_WHISPER_BIN").map(PathBuf::from))
            .or_else(|| find_in_path(&["whisper-cli", "whisper-cpp", "whisper"]))?;
        let ffmpeg = std::env::var_os("HIGHLITE_FFMPEG")
            .map(PathBuf::from)
            .or_else(|| find_in_path(&["ffmpeg"]))?;

        Some(Self {
            binary,
            model,
            ffmpeg,
            language: language.map(str::to_owned),
        })
    }
}

impl Transcriber for WhisperCliTranscriber {
    fn transcribe(
        &self,
        request: &TranscriptionRequest<'_>,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError> {
        let work = temp_directory("whisper");
        fs::create_dir_all(&work).map_err(|error| {
            TranscribeError::new(format!("Could not create a temporary folder: {error}"))
        })?;
        let result = self.transcribe_in(request, &work);
        let _ = fs::remove_dir_all(&work);
        result
    }
}

impl WhisperCliTranscriber {
    fn transcribe_in(
        &self,
        request: &TranscriptionRequest<'_>,
        work: &Path,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError> {
        if !self.model.is_file() {
            return Err(TranscribeError::new(format!(
                "The whisper model was not found at {}.",
                self.model.display()
            )));
        }

        let wav = work.join("audio.wav");
        decode_to_wav(&self.ffmpeg, request.audio_path, &wav)?;

        let prefix = work.join("transcript");
        let json_path = prefix.with_extension("json");
        let mut last_stderr = String::new();

        // Prefer full JSON (token timings); older whisper.cpp builds only know -oj.
        for output_flag in ["-ojf", "-oj"] {
            let _ = fs::remove_file(&json_path);
            let mut command = Command::new(&self.binary);
            command
                .arg("-m")
                .arg(&self.model)
                .arg("-f")
                .arg(&wav)
                .arg(output_flag)
                .arg("-np")
                .arg("-of")
                .arg(&prefix);
            if let Some(language) = request.language.or(self.language.as_deref()) {
                command.arg("-l").arg(language);
            }
            let output = command.output().map_err(|error| {
                TranscribeError::new(format!(
                    "Could not run whisper ({}): {error}",
                    self.binary.display()
                ))
            })?;
            if output.status.success() && json_path.is_file() {
                let json = fs::read_to_string(&json_path).map_err(|error| {
                    TranscribeError::new(format!(
                        "whisper did not write {}: {error}",
                        json_path.display()
                    ))
                })?;
                return parse_whisper_json(&json);
            }
            last_stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        }

        Err(TranscribeError::new(format!(
            "whisper failed: {last_stderr}"
        )))
    }
}

/// English-first backend for NVIDIA Parakeet models through `parakeet.cpp`.
///
/// `parakeet.cpp` runs Parakeet, CTC, RNN-T and TDT GGUFs. It is a different
/// model family from Whisper, so it needs its own binary and model flags.
#[derive(Debug, Clone)]
pub struct ParakeetCliTranscriber {
    pub binary: PathBuf,
    pub model: PathBuf,
    pub ffmpeg: PathBuf,
    pub language: Option<String>,
}

impl ParakeetCliTranscriber {
    pub fn detect(
        model: Option<&Path>,
        binary: Option<&Path>,
        language: Option<&str>,
    ) -> Option<Self> {
        let model = model
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os("HIGHLITE_PARAKEET_MODEL").map(PathBuf::from))?;
        let binary = binary
            .map(Path::to_path_buf)
            .or_else(|| std::env::var_os("HIGHLITE_PARAKEET_BIN").map(PathBuf::from))
            .or_else(|| find_in_path(&["parakeet-cli", "parakeet"]))?;
        let ffmpeg = std::env::var_os("HIGHLITE_FFMPEG")
            .map(PathBuf::from)
            .or_else(|| find_in_path(&["ffmpeg"]))?;

        Some(Self {
            binary,
            model,
            ffmpeg,
            language: language.map(str::to_owned),
        })
    }
}

impl Transcriber for ParakeetCliTranscriber {
    fn transcribe(
        &self,
        request: &TranscriptionRequest<'_>,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError> {
        let work = temp_directory("parakeet");
        fs::create_dir_all(&work).map_err(|error| {
            TranscribeError::new(format!("Could not create a temporary folder: {error}"))
        })?;
        let result = self.transcribe_in(request, &work);
        let _ = fs::remove_dir_all(&work);
        result
    }
}

impl ParakeetCliTranscriber {
    fn transcribe_in(
        &self,
        request: &TranscriptionRequest<'_>,
        work: &Path,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError> {
        if !self.model.is_file() {
            return Err(TranscribeError::new(format!(
                "The Parakeet model was not found at {}.",
                self.model.display()
            )));
        }

        let wav = work.join("audio.wav");
        decode_to_wav(&self.ffmpeg, request.audio_path, &wav)?;

        let mut command = Command::new(&self.binary);
        command
            .arg("transcribe")
            .arg("--model")
            .arg(&self.model)
            .arg("--input")
            .arg(&wav)
            .arg("--json");
        if let Some(language) = request.language.or(self.language.as_deref()) {
            command.arg("--lang").arg(language);
        }

        let output = command.output().map_err(|error| {
            TranscribeError::new(format!(
                "Could not run parakeet-cli ({}): {error}",
                self.binary.display()
            ))
        })?;
        if !output.status.success() {
            return Err(TranscribeError::new(format!(
                "parakeet-cli failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_parakeet_json(&stdout)
    }
}

#[derive(Debug, Deserialize)]
struct ParakeetWord {
    w: String,
    start: f64,
    end: f64,
}

#[derive(Debug, Deserialize)]
struct ParakeetRoot {
    #[serde(default)]
    text: String,
    #[serde(default)]
    words: Vec<ParakeetWord>,
}

const PARAKEET_SEGMENT_GAP_MS: u64 = 750;

fn seconds_to_ms(seconds: f64) -> u64 {
    if !seconds.is_finite() || seconds <= 0.0 {
        0
    } else {
        (seconds * 1_000.0).round() as u64
    }
}

/// Parse `parakeet-cli transcribe --json`.
///
/// The CLI reports word times in seconds. Words are grouped into segments at
/// pauses so the compiler can align clauses without treating the whole clip as
/// one block.
pub fn parse_parakeet_json(json: &str) -> Result<Vec<TranscriptSegment>, TranscribeError> {
    let root: ParakeetRoot = serde_json::from_str(json)
        .map_err(|error| TranscribeError::new(format!("Could not read parakeet JSON: {error}")))?;

    let mut words: Vec<WordTiming> = Vec::new();
    for word in root.words {
        let text = word.w.trim().to_owned();
        if text.is_empty() {
            continue;
        }
        let start_ms = seconds_to_ms(word.start);
        let end_ms = seconds_to_ms(word.end).max(start_ms.saturating_add(1));
        words.push(WordTiming {
            start_ms,
            end_ms,
            text,
        });
    }

    if words.is_empty() {
        if root.text.trim().is_empty() {
            return Ok(Vec::new());
        }
        return Err(TranscribeError::new(
            "parakeet-cli returned text without word timings; rebuild it with --json support.",
        ));
    }

    words.sort_by_key(|word| word.start_ms);
    let mut segments: Vec<TranscriptSegment> = Vec::new();
    let mut current: Vec<WordTiming> = Vec::new();

    let flush = |current: &mut Vec<WordTiming>, segments: &mut Vec<TranscriptSegment>| {
        if current.is_empty() {
            return;
        }
        let start_ms = current[0].start_ms;
        let end_ms = current[current.len() - 1].end_ms;
        let text = current
            .iter()
            .map(|word| word.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        segments.push(TranscriptSegment {
            id: None,
            start_ms,
            end_ms,
            text,
            word_timings: std::mem::take(current),
        });
    };

    for word in words {
        if let Some(previous) = current.last()
            && word.start_ms.saturating_sub(previous.end_ms) > PARAKEET_SEGMENT_GAP_MS
        {
            flush(&mut current, &mut segments);
        }
        current.push(word);
    }
    flush(&mut current, &mut segments);

    Ok(segments)
}

#[derive(Debug, Clone)]
pub struct CommandTranscriber {
    program: PathBuf,
    args: Vec<String>,
}

impl CommandTranscriber {
    /// A command is split on whitespace and the audio path is appended as the
    /// final argument. It must print transcript JSON on stdout.
    pub fn new(command: &str) -> Result<Self, TranscribeError> {
        let mut parts = command.split_whitespace();
        let program = parts
            .next()
            .ok_or_else(|| TranscribeError::new("The transcriber command is empty."))?;
        Ok(Self {
            program: PathBuf::from(program),
            args: parts.map(str::to_owned).collect(),
        })
    }
}

impl Transcriber for CommandTranscriber {
    fn transcribe(
        &self,
        request: &TranscriptionRequest<'_>,
    ) -> Result<Vec<TranscriptSegment>, TranscribeError> {
        let output = Command::new(&self.program)
            .args(&self.args)
            .arg(request.audio_path)
            .output()
            .map_err(|error| {
                TranscribeError::new(format!(
                    "Could not run the transcriber ({}): {error}",
                    self.program.display()
                ))
            })?;
        if !output.status.success() {
            return Err(TranscribeError::new(format!(
                "The transcriber failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_transcript_json(&stdout)
    }
}

#[derive(Debug, Deserialize)]
struct WhisperOffsets {
    from: u64,
    to: u64,
}

#[derive(Debug, Deserialize)]
struct WhisperToken {
    offsets: WhisperOffsets,
    text: String,
}

#[derive(Debug, Deserialize)]
struct WhisperSegment {
    offsets: WhisperOffsets,
    text: String,
    #[serde(default)]
    tokens: Vec<WhisperToken>,
}

#[derive(Debug, Deserialize)]
struct WhisperRoot {
    transcription: Vec<WhisperSegment>,
}

fn is_special_token(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.is_empty() || (trimmed.starts_with("[_") && trimmed.ends_with("_]"))
}

fn words_from_tokens(tokens: &[WhisperToken]) -> Vec<WordTiming> {
    let mut words: Vec<WordTiming> = Vec::new();
    let mut current: Option<(String, u64, u64)> = None;

    let flush = |current: &mut Option<(String, u64, u64)>, words: &mut Vec<WordTiming>| {
        if let Some((text, start_ms, end_ms)) = current.take() {
            let text = text.trim().to_owned();
            if !text.is_empty() {
                words.push(WordTiming {
                    start_ms,
                    end_ms,
                    text,
                });
            }
        }
    };

    for token in tokens {
        if is_special_token(&token.text) {
            continue;
        }
        let starts_word = token.text.starts_with(' ') || current.is_none();
        if starts_word && current.is_some() {
            flush(&mut current, &mut words);
        }
        let trimmed = token.text.trim();
        match current.as_mut() {
            Some((text, start_ms, end_ms)) => {
                text.push_str(trimmed);
                *start_ms = (*start_ms).min(token.offsets.from);
                *end_ms = (*end_ms).max(token.offsets.to);
            }
            None => current = Some((trimmed.to_owned(), token.offsets.from, token.offsets.to)),
        }
    }
    flush(&mut current, &mut words);

    words
}

fn spread_words(text: &str, start_ms: u64, end_ms: u64) -> Vec<WordTiming> {
    let words: Vec<&str> = text.split_whitespace().collect();
    if words.is_empty() {
        return Vec::new();
    }
    let duration = end_ms.saturating_sub(start_ms);
    words
        .iter()
        .enumerate()
        .map(|(index, word)| {
            let start = start_ms + (duration * index as u64 / words.len() as u64);
            let end = start_ms + (duration * (index as u64 + 1) / words.len() as u64);
            WordTiming {
                start_ms: start,
                end_ms: end,
                text: (*word).to_owned(),
            }
        })
        .collect()
}

/// Parse whisper.cpp `-oj` / `-ojf` output.
pub fn parse_whisper_json(json: &str) -> Result<Vec<TranscriptSegment>, TranscribeError> {
    let root: WhisperRoot = serde_json::from_str(json)
        .map_err(|error| TranscribeError::new(format!("Could not read whisper JSON: {error}")))?;

    let segments: Vec<TranscriptSegment> = root
        .transcription
        .into_iter()
        .filter_map(|segment| {
            let text = segment.text.trim().to_owned();
            if text.is_empty() {
                return None;
            }
            let mut words = words_from_tokens(&segment.tokens);
            if words.is_empty() {
                words = spread_words(&text, segment.offsets.from, segment.offsets.to);
            }
            Some(TranscriptSegment {
                id: None,
                start_ms: segment.offsets.from,
                end_ms: segment.offsets.to.max(segment.offsets.from),
                text,
                word_timings: words,
            })
        })
        .collect();

    Ok(segments)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JsonWord {
    start_ms: u64,
    end_ms: u64,
    text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct JsonSegment {
    start_ms: u64,
    end_ms: u64,
    text: String,
    #[serde(default, alias = "wordTimings")]
    words: Vec<JsonWord>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum JsonTranscript {
    Object { segments: Vec<JsonSegment> },
    Array(Vec<JsonSegment>),
}

/// Parse the generic transcriber command contract.
///
/// ```json
/// {"segments":[{"startMs":0,"endMs":1200,"text":"Look here",
///   "words":[{"startMs":0,"endMs":300,"text":"Look"}]}]}
/// ```
pub fn parse_transcript_json(json: &str) -> Result<Vec<TranscriptSegment>, TranscribeError> {
    let transcript: JsonTranscript = serde_json::from_str(json).map_err(|error| {
        TranscribeError::new(format!("Could not read transcript JSON: {error}"))
    })?;
    let segments = match transcript {
        JsonTranscript::Object { segments } => segments,
        JsonTranscript::Array(segments) => segments,
    };

    Ok(segments
        .into_iter()
        .filter_map(|segment| {
            let text = segment.text.trim().to_owned();
            if text.is_empty() {
                return None;
            }
            Some(TranscriptSegment {
                id: None,
                start_ms: segment.start_ms,
                end_ms: segment.end_ms.max(segment.start_ms),
                text,
                word_timings: segment
                    .words
                    .into_iter()
                    .map(|word| WordTiming {
                        start_ms: word.start_ms,
                        end_ms: word.end_ms,
                        text: word.text,
                    })
                    .collect(),
            })
        })
        .collect())
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn find_in_path(names: &[&str]) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        for name in names {
            let candidate = directory.join(name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

/// Decode any supported audio file to the 16 kHz mono WAV both local engines want.
fn decode_to_wav(ffmpeg: &Path, input: &Path, output: &Path) -> Result<(), TranscribeError> {
    let result = Command::new(ffmpeg)
        .arg("-y")
        .arg("-loglevel")
        .arg("error")
        .arg("-i")
        .arg(input)
        .arg("-ar")
        .arg("16000")
        .arg("-ac")
        .arg("1")
        .arg("-c:a")
        .arg("pcm_s16le")
        .arg(output)
        .output()
        .map_err(|error| {
            TranscribeError::new(format!(
                "Could not run ffmpeg ({}): {error}",
                ffmpeg.display()
            ))
        })?;
    if !result.status.success() {
        return Err(TranscribeError::new(format!(
            "ffmpeg could not decode {}: {}",
            input.display(),
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    Ok(())
}

fn temp_directory(kind: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    std::env::temp_dir().join(format!("highlite-{kind}-{}-{nanos}", std::process::id()))
}
