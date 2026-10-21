mod common;

use common::{normalize_numbers, read_fixture};
use highlite_compiler::{CompileInput, ScrawlExportOptions, compile_capture, to_scrawl_bundle};

#[test]
fn matches_the_golden_bundle() {
    let input: CompileInput =
        serde_json::from_value(read_fixture("capture.json")).expect("valid compile input");
    let compiled = compile_capture(&input);

    let mut actual = serde_json::to_value(&compiled).expect("serializable bundle");
    let mut expected = read_fixture("expected-bundle.json");
    normalize_numbers(&mut actual);
    normalize_numbers(&mut expected);

    assert_eq!(actual, expected);
}

#[test]
fn matches_the_golden_scrawl_export() {
    let input: CompileInput =
        serde_json::from_value(read_fixture("capture.json")).expect("valid compile input");
    let compiled = compile_capture(&input);
    let scrawl = to_scrawl_bundle(&compiled, &ScrawlExportOptions::default())
        .expect("scrawl export should have a viewport");

    let mut actual = serde_json::to_value(&scrawl).expect("serializable scrawl bundle");
    let mut expected = read_fixture("expected-scrawl.json");
    normalize_numbers(&mut actual);
    normalize_numbers(&mut expected);

    assert_eq!(actual, expected);
}
