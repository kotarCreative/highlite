use highlite_compiler::{
    Annotation, AnnotationKind, CoordinateSpace, KeyframeReason, NormalizedRect, Point, SheetFrame,
    ViewportRect, render_contact_sheet, render_frame,
};
use image::{Rgba, RgbaImage};
use std::path::{Path, PathBuf};

const BACKGROUND: Rgba<u8> = Rgba([20, 20, 24, 255]);

fn annotation(kind: AnnotationKind, points: Vec<(f64, f64)>) -> Annotation {
    annotation_with_width(kind, points, None)
}

fn annotation_with_width(
    kind: AnnotationKind,
    points: Vec<(f64, f64)>,
    stroke_width: Option<f64>,
) -> Annotation {
    Annotation {
        id: "a1".to_owned(),
        at_ms: 100,
        kind,
        points: points.into_iter().map(|(x, y)| Point { x, y }).collect(),
        coordinate_space: CoordinateSpace::ViewportNormalized,
        stroke_width,
        fade_after_ms: None,
        fade_duration_ms: None,
        target_id: None,
    }
}

fn source_image(directory: &Path) -> PathBuf {
    source_image_sized(directory, 400, 300)
}

fn source_image_sized(directory: &Path, width: u32, height: u32) -> PathBuf {
    let image = RgbaImage::from_pixel(width, height, BACKGROUND);
    let path = directory.join(format!("source-{width}x{height}.png"));
    image.save(&path).expect("save source");
    path
}

fn black_source_image(directory: &Path, width: u32, height: u32) -> PathBuf {
    let image = RgbaImage::from_pixel(width, height, Rgba([0, 0, 0, 255]));
    let path = directory.join(format!("black-{width}x{height}.png"));
    image.save(&path).expect("save source");
    path
}

fn viewport(width: f64, height: f64) -> ViewportRect {
    ViewportRect {
        x: 0.0,
        y: 0.0,
        width,
        height,
    }
}

fn ink_rows(image: &RgbaImage, x: u32) -> usize {
    (0..image.height())
        .filter(|y| *image.get_pixel(x, *y) != BACKGROUND)
        .count()
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
        None,
        100,
    )
    .expect("render");

    assert_eq!(rendered.image.dimensions(), (240, 180));
    // This sample is outside the highlight even though the highlight overlaps the crop.
    assert_eq!(*rendered.image.get_pixel(120, 90), BACKGROUND);

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
        None,
        100,
    )
    .expect("render");
    let center = rendered.image.get_pixel(60, 60);
    assert_ne!(*center, BACKGROUND, "highlight must be visible");
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

    let rendered = render_frame(&path, None, &annotations, None, 100).expect("render");
    assert_eq!(rendered.image.dimensions(), (400, 300));
    assert!(rendered.image.pixels().any(|pixel| *pixel != BACKGROUND));
}

#[test]
fn draws_the_sdk_stroke_width_in_captured_pixels() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image_sized(directory.path(), 1_000, 800);
    let line = annotation(AnnotationKind::Freehand, vec![(0.2, 0.5), (0.8, 0.5)]);

    let rendered =
        render_frame(&path, None, &[line], Some(viewport(1_000.0, 800.0)), 100).expect("render");

    assert_eq!(
        ink_rows(&rendered.image, 500),
        4,
        "a 4 CSS px stroke at 1x capture scale must stay 4 pixels"
    );
}

#[test]
fn scales_the_stroke_width_to_a_high_density_capture() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image_sized(directory.path(), 2_000, 1_600);
    let line = annotation(AnnotationKind::Freehand, vec![(0.2, 0.5), (0.8, 0.5)]);

    let rendered =
        render_frame(&path, None, &[line], Some(viewport(1_000.0, 800.0)), 100).expect("render");

    assert_eq!(
        ink_rows(&rendered.image, 1_000),
        8,
        "a 4 CSS px stroke in a 2x capture must be 8 pixels"
    );
}

#[test]
fn cropping_does_not_thin_the_annotation_stroke() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image_sized(directory.path(), 1_000, 800);
    let line = annotation(AnnotationKind::Freehand, vec![(0.3, 0.5), (0.7, 0.5)]);

    let rendered = render_frame(
        &path,
        Some(NormalizedRect {
            x: 0.25,
            y: 0.25,
            width: 0.5,
            height: 0.5,
        }),
        &[line],
        Some(viewport(1_000.0, 800.0)),
        100,
    )
    .expect("render");

    assert_eq!(rendered.image.dimensions(), (500, 400));
    assert_eq!(
        ink_rows(&rendered.image, 250),
        4,
        "cropping must not shrink the stroke width"
    );
}

#[test]
fn honors_an_explicit_stroke_width() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image_sized(directory.path(), 1_000, 800);
    let line = annotation_with_width(
        AnnotationKind::Freehand,
        vec![(0.2, 0.5), (0.8, 0.5)],
        Some(8.0),
    );

    let rendered =
        render_frame(&path, None, &[line], Some(viewport(1_000.0, 800.0)), 100).expect("render");

    assert_eq!(ink_rows(&rendered.image, 500), 8);
}

#[test]
fn burns_mid_fade_annotations_at_full_opacity() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = black_source_image(directory.path(), 1_000, 800);
    let mut line = annotation(AnnotationKind::Freehand, vec![(0.2, 0.5), (0.8, 0.5)]);
    line.at_ms = 0;
    line.fade_after_ms = Some(1_000);
    line.fade_duration_ms = Some(1_000);
    let view = Some(viewport(1_000.0, 800.0));

    let full = render_frame(&path, None, std::slice::from_ref(&line), view, 0)
        .expect("full")
        .image;
    let mid_fade = render_frame(&path, None, std::slice::from_ref(&line), view, 1_500)
        .expect("mid fade")
        .image;
    let gone = render_frame(&path, None, std::slice::from_ref(&line), view, 2_000)
        .expect("gone")
        .image;

    assert_eq!(*full.get_pixel(500, 400), Rgba([255, 59, 92, 255]));
    assert_eq!(
        *mid_fade.get_pixel(500, 400),
        Rgba([255, 59, 92, 255]),
        "a frame captured mid-fade must still carry a readable, fully opaque stroke"
    );
    assert_eq!(
        *gone.get_pixel(500, 400),
        Rgba([0, 0, 0, 255]),
        "a keyframe after the fade must not burn the annotation"
    );
}

#[test]
fn composes_a_contact_sheet_with_a_cell_per_frame() {
    let directory = tempfile::tempdir().expect("temp dir");
    let path = source_image(directory.path());
    let first = render_frame(&path, None, &[], None, 100)
        .expect("first")
        .image;
    let second = render_frame(&path, None, &[], None, 100)
        .expect("second")
        .image;

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
