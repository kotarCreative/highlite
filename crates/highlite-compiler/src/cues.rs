//! Spoken-cue detection.
//!
//! Scrawl treats words such as “here” and “look” as deliberate requests to show
//! what is on screen. Highlite only has discrete frames, so a cue can promote an
//! existing nearby frame rather than invent one. The compiler reports strong cues
//! that had no frame nearby instead of silently pretending the moment was captured.

use crate::model::{HighliteManifest, TranscriptSegment, WordTiming};

/// Cues that always ask the viewer to look at the current screen.
pub const STRONG_CUES: [&str; 4] = ["here", "look", "watch", "now"];

/// Demonstratives that only count when they land on a visual change.
pub const WEAK_CUES: [&str; 6] = ["this", "that", "these", "those", "see", "there"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpeechCue {
    pub at_ms: u64,
    pub word: String,
    pub strong: bool,
}

fn normalize_word(text: &str) -> String {
    text.trim_matches(|character: char| !character.is_alphanumeric())
        .to_lowercase()
}

fn classify(word: &str) -> Option<bool> {
    let normalized = normalize_word(word);
    if STRONG_CUES.contains(&normalized.as_str()) {
        Some(true)
    } else if WEAK_CUES.contains(&normalized.as_str()) {
        Some(false)
    } else {
        None
    }
}

fn cue_from_word(word: &WordTiming) -> Option<SpeechCue> {
    let strong = classify(&word.text)?;
    Some(SpeechCue {
        at_ms: word.start_ms + (word.end_ms.saturating_sub(word.start_ms) / 2),
        word: normalize_word(&word.text),
        strong,
    })
}

/// Estimate word timings for segments that only have segment-level text.
fn estimated_cues(segment: &TranscriptSegment) -> Vec<SpeechCue> {
    let text = segment.text.as_str();
    let total_chars = text.chars().count().max(1);
    let duration = segment.end_ms.saturating_sub(segment.start_ms);
    let mut cues = Vec::new();
    let mut char_index = 0_usize;

    for word in text.split_whitespace() {
        let word_chars = word.chars().count();
        if let Some(strong) = classify(word) {
            let midpoint = char_index + (word_chars / 2);
            let at_ms = segment.start_ms
                + ((midpoint as u64).saturating_mul(duration) / total_chars as u64);
            cues.push(SpeechCue {
                at_ms,
                word: normalize_word(word),
                strong,
            });
        }
        char_index += word_chars + 1;
    }

    cues
}

fn merge_close(cues: Vec<SpeechCue>) -> Vec<SpeechCue> {
    let mut sorted = cues;
    sorted.sort_by_key(|cue| cue.at_ms);
    let mut merged: Vec<SpeechCue> = Vec::new();

    for cue in sorted {
        match merged.last() {
            Some(previous) if cue.at_ms.abs_diff(previous.at_ms) <= 600 => {
                // Prefer the strong cue in a phrase such as “look at this”.
                if cue.strong && !previous.strong {
                    *merged.last_mut().expect("checked above") = cue;
                }
            }
            _ => merged.push(cue),
        }
    }

    merged
}

fn cues_for_segment(segment: &TranscriptSegment) -> Vec<SpeechCue> {
    if segment.word_timings.is_empty() {
        return estimated_cues(segment);
    }

    segment
        .word_timings
        .iter()
        .filter_map(cue_from_word)
        .collect()
}

/// Find deliberate spoken cues in the transcript, in time order.
pub fn detect_speech_cues(manifest: &HighliteManifest) -> Vec<SpeechCue> {
    merge_close(
        manifest
            .transcript
            .iter()
            .flat_map(cues_for_segment)
            .collect(),
    )
}

/// The cue window used for weak demonstratives, derived from the strong window.
pub fn weak_window_ms(strong_window_ms: u64) -> u64 {
    (strong_window_ms / 3).clamp(250, 900)
}
