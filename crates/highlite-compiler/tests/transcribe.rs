use highlite_compiler::{
    TranscriptSegment, WordTiming, parse_transcript_json, parse_whisper_json, shift_transcript,
};

#[test]
fn parses_whisper_segments_and_token_words() {
    let json = r#"{
      "transcription": [
        {
          "offsets": {"from": 0, "to": 2400},
          "text": " Look here.",
          "tokens": [
            {"offsets": {"from": 0, "to": 300}, "text": " Look"},
            {"offsets": {"from": 300, "to": 620}, "text": " here"},
            {"offsets": {"from": 620, "to": 660}, "text": "."}
          ]
        },
        {
          "offsets": {"from": 2400, "to": 4000},
          "text": " This is the chart."
        }
      ]
    }"#;

    let segments = parse_whisper_json(json).expect("whisper JSON");
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].text, "Look here.");
    assert_eq!(
        segments[0].word_timings,
        vec![
            WordTiming {
                start_ms: 0,
                end_ms: 300,
                text: "Look".to_owned()
            },
            WordTiming {
                start_ms: 300,
                end_ms: 660,
                text: "here.".to_owned()
            },
        ]
    );
    // No tokens: spread the segment's words evenly rather than dropping them.
    assert_eq!(segments[1].word_timings.len(), 4);
    assert_eq!(segments[1].word_timings[0].start_ms, 2400);
    assert_eq!(segments[1].word_timings[3].end_ms, 4000);
}

#[test]
fn parses_generic_transcript_json() {
    let json = r#"{
      "segments": [
        {
          "startMs": 500,
          "endMs": 1600,
          "text": "Look at this",
          "words": [
            {"startMs": 500, "endMs": 700, "text": "Look"},
            {"startMs": 700, "endMs": 1100, "text": "at"},
            {"startMs": 1100, "endMs": 1600, "text": "this"}
          ]
        }
      ]
    }"#;

    let segments = parse_transcript_json(json).expect("transcript JSON");
    assert_eq!(segments.len(), 1);
    assert_eq!(segments[0].text, "Look at this");
    assert_eq!(segments[0].word_timings[2].text, "this");

    let bare = r#"[{"startMs": 0, "endMs": 1000, "text": "Here"}]"#;
    let segments = parse_transcript_json(bare).expect("bare array");
    assert_eq!(segments.len(), 1);
    assert!(segments[0].word_timings.is_empty());
}

#[test]
fn shifts_audio_timings_onto_the_session_clock_and_clips_the_tail() {
    let segments = vec![TranscriptSegment {
        id: Some("s1".to_owned()),
        start_ms: 0,
        end_ms: 1_500,
        text: "Look here".to_owned(),
        word_timings: vec![
            WordTiming {
                start_ms: 0,
                end_ms: 300,
                text: "Look".to_owned(),
            },
            WordTiming {
                start_ms: 1_400,
                end_ms: 1_600,
                text: "here".to_owned(),
            },
        ],
    }];

    let shifted = shift_transcript(segments, 800, 2_000);
    assert_eq!(shifted[0].start_ms, 800);
    assert_eq!(shifted[0].end_ms, 2_000);
    assert_eq!(shifted[0].word_timings.len(), 1);
    assert_eq!(shifted[0].word_timings[0].start_ms, 800);
    assert_eq!(shifted[0].word_timings[0].end_ms, 1_100);
}

#[test]
fn drops_speech_that_starts_after_the_capture_ended() {
    let segments = vec![TranscriptSegment {
        id: None,
        start_ms: 3_000,
        end_ms: 4_000,
        text: "too late".to_owned(),
        word_timings: Vec::new(),
    }];

    assert!(shift_transcript(segments, 0, 2_500).is_empty());
}

#[test]
fn parses_parakeet_words_and_groups_them_at_pauses() {
    let json = r#"{
      "text": "Look here. This is the chart.",
      "frame_sec": 0.08,
      "words": [
        {"w": "Look", "start": 0.10, "end": 0.30, "conf": 0.99},
        {"w": "here.", "start": 0.30, "end": 0.60, "conf": 0.98},
        {"w": "This", "start": 1.50, "end": 1.70, "conf": 0.97},
        {"w": "is", "start": 1.70, "end": 1.80, "conf": 0.99},
        {"w": "the", "start": 1.80, "end": 1.90, "conf": 0.99},
        {"w": "chart.", "start": 1.90, "end": 2.20, "conf": 0.99}
      ],
      "tokens": []
    }"#;

    let segments = highlite_compiler::parse_parakeet_json(json).expect("parakeet JSON");
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].text, "Look here.");
    assert_eq!(segments[0].start_ms, 100);
    assert_eq!(segments[0].end_ms, 600);
    assert_eq!(segments[0].word_timings[1].text, "here.");
    assert_eq!(segments[1].text, "This is the chart.");
    assert_eq!(segments[1].start_ms, 1_500);
    assert_eq!(segments[1].end_ms, 2_200);
}

#[test]
fn parakeet_returns_an_error_when_text_has_no_word_timings() {
    let error = highlite_compiler::parse_parakeet_json(r#"{"text":"hello","words":[]}"#)
        .expect_err("timings are required");
    assert!(error.to_string().contains("without word timings"));

    assert!(
        highlite_compiler::parse_parakeet_json(r#"{"text":"","words":[]}"#)
            .expect("empty output is silence")
            .is_empty()
    );
}
