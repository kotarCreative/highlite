mod common;

use common::words;
use highlite_compiler::{AlignedText, AlignmentTarget, TranscriptSegment, align_transcript};

#[test]
fn starts_a_new_clause_at_a_segment_boundary_and_keeps_segment_ids() {
    let aligned = align_transcript(
        &[
            AlignmentTarget {
                at_ms: 1_000,
                anchor_ms: 1_000,
            },
            AlignmentTarget {
                at_ms: 4_000,
                anchor_ms: 4_000,
            },
        ],
        &[
            TranscriptSegment {
                id: Some("s1".to_owned()),
                start_ms: 0,
                end_ms: 3_000,
                text: "One two.".to_owned(),
                word_timings: words("One two.", 0, 3_000),
            },
            TranscriptSegment {
                id: Some("s2".to_owned()),
                start_ms: 3_000,
                end_ms: 6_000,
                text: "Three four.".to_owned(),
                word_timings: words("Three four.", 3_000, 6_000),
            },
        ],
        1_500,
    );

    assert_eq!(
        aligned,
        vec![
            AlignedText {
                said: Some("One two.".to_owned()),
                transcript_segment_ids: vec!["s1".to_owned()],
            },
            AlignedText {
                said: Some("Three four.".to_owned()),
                transcript_segment_ids: vec!["s2".to_owned()],
            },
        ]
    );
}

#[test]
fn partitions_one_clause_in_order_when_two_keyframes_share_it() {
    let aligned = align_transcript(
        &[
            AlignmentTarget {
                at_ms: 1_500,
                anchor_ms: 1_500,
            },
            AlignmentTarget {
                at_ms: 3_500,
                anchor_ms: 3_500,
            },
        ],
        &[TranscriptSegment {
            id: Some("s1".to_owned()),
            start_ms: 0,
            end_ms: 6_000,
            text: "One two three four five six.".to_owned(),
            word_timings: words("One two three four five six.", 0, 6_000),
        }],
        1_500,
    );

    assert_eq!(
        aligned
            .iter()
            .map(|item| item.said.as_deref())
            .collect::<Vec<_>>(),
        [Some("One two three four"), Some("five six.")]
    );
    assert_eq!(
        aligned
            .iter()
            .map(|item| item.transcript_segment_ids.clone())
            .collect::<Vec<_>>(),
        [vec!["s1".to_owned()], vec!["s1".to_owned()]]
    );
}

#[test]
fn returns_empty_alignment_when_there_is_no_transcript() {
    assert_eq!(
        align_transcript(
            &[AlignmentTarget {
                at_ms: 1_000,
                anchor_ms: 1_000,
            }],
            &[],
            1_500,
        ),
        vec![AlignedText::default()]
    );
}
