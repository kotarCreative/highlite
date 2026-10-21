pub mod alignment;
pub mod compiler;
pub mod model;
pub mod scrawl;
pub mod summary;

pub use alignment::{AlignedText, AlignmentTarget, align_transcript};
pub use compiler::{
    DocsResolver, compile_capture, compile_capture_with, docs_refs, keyframe_budget,
};
pub use model::*;
pub use scrawl::*;
pub use summary::build_handoff_summary;
