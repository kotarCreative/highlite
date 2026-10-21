use highlite_compiler::{
    Annotation, AnnotationKind, CoordinateSpace, KeyframeReason, NormalizedRect, Point, SheetFrame,
    render_contact_sheet, render_frame,
};
use image::{Rgba, RgbaImage};
use std::path::Path;

fn annotation(kind: AnnotationKind, points: Vec<(f64, f64)>) -> Annotation {
    Annotation {
        id: "a1".to_owned(),
        at_ms: 100,
        kind,
        points: points.into_iter().map(|(x, y)| Point { x, y }).collect(),
        coordinate_space: CoordinateSpace::ViewportNormalized,
        target_id: None,
    }
}

fn source_image(directory: &Path) -> std::path::PathBuf {
    let mut image = RgbaImage::from_pixel(400, 300, Rgba([20, 20, 24, 255]));
    for pixel in image.pixels_mut() {
        *pixel = Rgba([20, 20, 24, 255]);
    }
    let path = directory.join("source.png");
    image.save(&path).expect("save source");
    path
}

#[test]
fn crops_a_frame_and_burns_annotations_at_the_crop_scale() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image(directory.path());
    let highlight = annotation(AnnotationKind::Highlight, vec![(0.1, 0.1), (0.3, 0.3)]);

    let rendered = render_frame(
        &path,
        Some(NormalizedRect {
            x: 0.2,
            y: 0.2,
            width: 0.6,
            height: 0.6,
        }),
        &[highlight],
    )
    .expect("render");

    assert_eq!(rendered.image.dimensions(), (240, 180));
    // This sample is outside the highlight even though the highlight overlaps the crop.
    assert_eq!(*rendered.image.get_pixel(120, 90), Rgba([20, 20, 24, 255]));

    let rendered = render_frame(
        &path,
        Some(NormalizedRect {
            x: 0.2,
            y: 0.2,
            width: 0.6,
            height: 0.6,
        }),
        &[annotation(
            AnnotationKind::Highlight,
            vec![(0.25, 0.25), (0.5, 0.5)],
        )],
    )
    .expect("render");
    let center = rendered.image.get_pixel(60, 60);
    assert_ne!(
        *center,
        Rgba([20, 20, 24, 255]),
        "highlight must be visible"
    );
}

#[test]
fn renders_all_annotation_shapes_without_panicking() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image(directory.path());
    let annotations = vec![
        annotation(
            AnnotationKind::Freehand,
            vec![(0.1, 0.2), (0.2, 0.3), (0.3, 0.25)],
        ),
        annotation(AnnotationKind::Circle, vec![(0.2, 0.2), (0.6, 0.7)]),
        annotation(AnnotationKind::Arrow, vec![(0.3, 0.3), (0.8, 0.8)]),
        annotation(AnnotationKind::Highlight, vec![(0.4, 0.1), (0.9, 0.4)]),
    ];

    let rendered = render_frame(&path, None, &annotations).expect("render");
    assert_eq!(rendered.image.dimensions(), (400, 300));
    assert!(
        rendered
            .image
            .pixels()
            .any(|pixel| *pixel != Rgba([20, 20, 24, 255]))
    );
}

#[test]
fn composes_a_contact_sheet_with_a_cell_per_frame() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image(directory.path());
    let first = render_frame(&path, None, &[]).expect("first").image;
    let second = render_frame(&path, None, &[]).expect("second").image;

    let frames = vec![
        SheetFrame {
            image: &first,
            index: 1,
            at_ms: 4_000,
            reason: KeyframeReason::Mark,
            caption: "marked “Retention”".to_owned(),
        },
        SheetFrame {
            image: &second,
            index: 2,
            at_ms: 12_000,
            reason: KeyframeReason::Interaction,
            caption: "clicked “Date range”".to_owned(),
        },
    ];

    let sheet = render_contact_sheet(&frames, "Analytics", 800).expect("sheet");
    assert_eq!(sheet.width(), 800);
    assert!(sheet.height() > 300);
    assert!(
        sheet
            .pixels()
            .any(|pixel| *pixel != Rgba([17, 19, 24, 255]))
    );
}
