use crate::model::TranscriptSegment;

const MAX_CLAUSE_WORDS: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AlignmentTarget {
    /// The keyframe moment.
    pub at_ms: u64,
    /// The action that caused it, when known.
    pub anchor_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AlignedText {
    pub said: Option<String>,
    pub transcript_segment_ids: Vec<String>,
}

#[derive(Debug, Clone)]
struct Unit {
    start_ms: u64,
    end_ms: u64,
    text: String,
    segment_id: String,
    is_segment_start: bool,
}

#[derive(Debug, Clone, Copy)]
struct Clause {
    start_ms: u64,
    end_ms: u64,
}

fn segment_id(segment: &TranscriptSegment, index: usize) -> String {
    segment
        .id
        .clone()
        .unwrap_or_else(|| format!("segment-{}", index + 1))
}

fn word_count(text: &str) -> usize {
    text.split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .count()
        .max(1)
}

fn ends_clause(text: &str, clause_words: usize) -> bool {
    let trimmed = text.trim_end().trim_end_matches(|character: char| {
        matches!(character, '"' | '\'' | '”' | '’' | ')' | ']')
    });
    trimmed.ends_with(['.', '!', '?', ';', ':'])
        || (clause_words >= 3 && trimmed.ends_with(','))
        || clause_words >= MAX_CLAUSE_WORDS
}

fn build_units(segments: &[TranscriptSegment]) -> Vec<Unit> {
    let mut units = Vec::new();

    for (index, segment) in segments.iter().enumerate() {
        let id = segment_id(segment, index);
        let mut first_kept = true;
        for word in segment
            .word_timings
            .iter()
            .filter(|word| !word.text.trim().is_empty())
        {
            units.push(Unit {
                start_ms: word.start_ms,
                end_ms: word.end_ms,
                text: word.text.clone(),
                segment_id: id.clone(),
                is_segment_start: first_kept,
            });
            first_kept = false;
        }
        if !first_kept {
            continue;
        }
        if !segment.text.trim().is_empty() {
            units.push(Unit {
                start_ms: segment.start_ms,
                end_ms: segment.end_ms,
                text: segment.text.clone(),
                segment_id: id,
                is_segment_start: true,
            });
        }
    }

    units.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then(left.end_ms.cmp(&right.end_ms))
    });
    units
}

fn build_clauses(units: &[Unit], clause_gap_ms: u64) -> Vec<Clause> {
    let mut clauses: Vec<Clause> = Vec::new();
    let mut previous_end: Option<u64> = None;
    let mut previous_text = String::new();
    let mut clause_words = 0;

    for unit in units {
        let starts_clause = clauses.is_empty()
            || unit.is_segment_start
            || ends_clause(&previous_text, clause_words)
            || previous_end.is_some_and(|end| unit.start_ms.saturating_sub(end) >= clause_gap_ms);

        if starts_clause {
            clauses.push(Clause {
                start_ms: unit.start_ms,
                end_ms: unit.end_ms,
            });
            clause_words = word_count(&unit.text);
        } else if let Some(clause) = clauses.last_mut() {
            clause.end_ms = clause.end_ms.max(unit.end_ms);
            clause_words += word_count(&unit.text);
        }

        previous_end = Some(unit.end_ms);
        previous_text.clone_from(&unit.text);
    }

    clauses
}

fn clause_start_at(anchor_ms: u64, clauses: &[Clause]) -> u64 {
    clauses
        .iter()
        .find(|clause| clause.start_ms <= anchor_ms && anchor_ms <= clause.end_ms)
        .map_or(anchor_ms, |clause| clause.start_ms)
}

fn starts_for(targets: &[AlignmentTarget], clauses: &[Clause]) -> Vec<u64> {
    let mut starts: Vec<u64> = Vec::with_capacity(targets.len());

    for target in targets {
        let mut start = clause_start_at(target.anchor_ms, clauses);
        if let Some(previous) = starts.last().copied()
            && start <= previous
        {
            start = target.anchor_ms.max(previous + 1);
        }
        starts.push(start);
    }

    starts
}

/// Assigns each keyframe the words from the start of the clause in progress at its anchor
/// until the next keyframe. The transcript is partitioned in order: nothing is repeated,
/// and speech before the first keyframe belongs to it.
pub fn align_transcript(
    targets: &[AlignmentTarget],
    segments: &[TranscriptSegment],
    clause_gap_ms: u64,
) -> Vec<AlignedText> {
    if targets.is_empty() {
        return Vec::new();
    }

    let units = build_units(segments);
    if units.is_empty() {
        return vec![AlignedText::default(); targets.len()];
    }

    let clauses = build_clauses(&units, clause_gap_ms);
    let starts = starts_for(targets, &clauses);
    let mut texts = vec![String::new(); targets.len()];
    let mut segment_sets: Vec<Vec<String>> = vec![Vec::new(); targets.len()];

    for unit in &units {
        let mut index = starts
            .iter()
            .rposition(|start| *start <= unit.start_ms.saturating_add(50))
            .unwrap_or(0);

        let attached = unit.text.chars().next().is_some_and(|character| {
            matches!(
                character,
                ',' | '.' | ';' | ':' | '!' | '?' | '\'' | '"' | '’' | ')' | ']'
            )
        });
        if attached && texts[index].is_empty() && index > 0 {
            index -= 1;
        }

        let open = texts[index]
            .chars()
            .last()
            .is_some_and(|character| matches!(character, '(' | '[' | '"' | '“'));
        if !texts[index].is_empty() && !attached && !open {
            texts[index].push(' ');
        }
        texts[index].push_str(&unit.text);
        if !segment_sets[index].contains(&unit.segment_id) {
            segment_sets[index].push(unit.segment_id.clone());
        }
    }

    texts
        .into_iter()
        .zip(segment_sets)
        .map(|(text, transcript_segment_ids)| {
            let text = text.trim();
            AlignedText {
                said: (!text.is_empty()).then(|| text.to_owned()),
                transcript_segment_ids,
            }
        })
        .collect()
}
