pub mod alignment;
pub mod bundle;
pub mod compiler;
pub mod cues;
pub mod model;
pub mod render;
pub mod scrawl;
pub mod summary;
pub mod transcribe;

pub use alignment::{AlignedText, AlignmentTarget, align_transcript};
pub use bundle::{BundleOptions, WrittenBundle, write_bundle};
pub use compiler::{
    DocsResolver, compile_capture, compile_capture_with, docs_refs, keyframe_budget,
};
pub use cues::{SpeechCue, detect_speech_cues};
pub use model::*;
pub use render::{RenderedFrame, SheetFrame, render_contact_sheet, render_frame, save_png};
pub use scrawl::*;
pub use summary::build_handoff_summary;
pub use transcribe::{
    CommandTranscriber, ParakeetCliTranscriber, TranscribeError, Transcriber, TranscriptionRequest,
    WhisperCliTranscriber, parse_parakeet_json, parse_transcript_json, parse_whisper_json,
    shift_transcript,
};
