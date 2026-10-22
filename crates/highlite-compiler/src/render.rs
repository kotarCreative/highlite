//! Frame rendering: crop keyframes, burn annotations into them, and compose a
//! contact sheet for an agent to look at first.

use std::error::Error;
use std::fmt;
use std::path::Path;
use std::sync::OnceLock;

use ab_glyph::{Font, FontVec, PxScale, ScaleFont, point};
use image::{Rgba, RgbaImage};

use crate::model::{Annotation, AnnotationKind, KeyframeReason, NormalizedRect, ViewportRect};

const FONT_BYTES: &[u8] = include_bytes!("../assets/LiberationSans-Regular.ttf");
/// The SDK draws annotations with a 4 CSS pixel stroke and a 14 CSS pixel arrow head.
const DEFAULT_STROKE_WIDTH_CSS_PX: f64 = 4.0;
const ARROW_HEAD_CSS_PX: f64 = 14.0;
const INK: Rgba<u8> = Rgba([255, 59, 92, 255]);
const HIGHLIGHT: Rgba<u8> = Rgba([255, 214, 10, 61]);
const BACKGROUND: Rgba<u8> = Rgba([17, 19, 24, 255]);
const CELL: Rgba<u8> = Rgba([28, 31, 38, 255]);
const BORDER: Rgba<u8> = Rgba([54, 59, 70, 255]);
const TEXT: Rgba<u8> = Rgba([238, 240, 245, 255]);
const MUTED: Rgba<u8> = Rgba([158, 165, 178, 255]);

#[derive(Debug, Clone)]
pub struct RenderError {
    message: String,
}

impl RenderError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for RenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl Error for RenderError {}

fn font() -> &'static FontVec {
    static FONT: OnceLock<FontVec> = OnceLock::new();
    FONT.get_or_init(|| {
        FontVec::try_from_vec(FONT_BYTES.to_vec()).expect("the bundled font must be valid")
    })
}

fn with_alpha(color: Rgba<u8>, alpha: f32) -> Rgba<u8> {
    Rgba([
        color[0],
        color[1],
        color[2],
        (color[3] as f32 * alpha.clamp(0.0, 1.0)).round() as u8,
    ])
}

fn blend(image: &mut RgbaImage, x: i32, y: i32, color: Rgba<u8>) {
    if x < 0 || y < 0 {
        return;
    }
    let (x, y) = (x as u32, y as u32);
    if x >= image.width() || y >= image.height() {
        return;
    }
    let source = color[3] as u32;
    if source == 0 {
        return;
    }
    let target = image.get_pixel_mut(x, y);
    let inverse = 255 - source;
    for channel in 0..3 {
        target[channel] =
            ((color[channel] as u32 * source + target[channel] as u32 * inverse) / 255) as u8;
    }
    target[3] = 255;
}

fn fill_rect(image: &mut RgbaImage, x: i32, y: i32, width: i32, height: i32, color: Rgba<u8>) {
    for py in y..y + height {
        for px in x..x + width {
            blend(image, px, py, color);
        }
    }
}

fn draw_rect_stroke(
    image: &mut RgbaImage,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    thickness: i32,
    color: Rgba<u8>,
) {
    fill_rect(image, x, y, width, thickness, color);
    fill_rect(image, x, y + height - thickness, width, thickness, color);
    fill_rect(image, x, y, thickness, height, color);
    fill_rect(image, x + width - thickness, y, thickness, height, color);
}

fn draw_disc(image: &mut RgbaImage, cx: f64, cy: f64, radius: f64, color: Rgba<u8>) {
    if radius <= 0.0 {
        return;
    }
    let radius_squared = radius * radius;
    let min_x = (cx - radius).floor() as i32;
    let max_x = (cx + radius).ceil() as i32;
    let min_y = (cy - radius).floor() as i32;
    let max_y = (cy + radius).ceil() as i32;
    for y in min_y..=max_y {
        for x in min_x..=max_x {
            let dx = x as f64 + 0.5 - cx;
            let dy = y as f64 + 0.5 - cy;
            if dx * dx + dy * dy <= radius_squared {
                blend(image, x, y, color);
            }
        }
    }
}

fn draw_line(
    image: &mut RgbaImage,
    from: (f64, f64),
    to: (f64, f64),
    thickness: f64,
    color: Rgba<u8>,
) {
    let (x0, y0) = from;
    let (x1, y1) = to;
    let dx = x1 - x0;
    let dy = y1 - y0;
    let steps = dx.abs().max(dy.abs()).ceil().max(1.0) as i32;
    for step in 0..=steps {
        let t = step as f64 / steps as f64;
        draw_disc(image, x0 + dx * t, y0 + dy * t, thickness / 2.0, color);
    }
}

fn draw_polyline(image: &mut RgbaImage, points: &[(f64, f64)], thickness: f64, color: Rgba<u8>) {
    for window in points.windows(2) {
        draw_line(image, window[0], window[1], thickness, color);
    }
}

fn draw_ellipse(
    image: &mut RgbaImage,
    center: (f64, f64),
    radii: (f64, f64),
    thickness: f64,
    color: Rgba<u8>,
) {
    let steps = ((radii.0.max(radii.1) * 2.0) as i32).clamp(48, 720);
    let mut previous: Option<(f64, f64)> = None;
    for step in 0..=steps {
        let angle = std::f64::consts::TAU * step as f64 / steps as f64;
        let point = (
            center.0 + radii.0 * angle.cos(),
            center.1 + radii.1 * angle.sin(),
        );
        if let Some(previous) = previous {
            draw_line(image, previous, point, thickness, color);
        }
        previous = Some(point);
    }
}

fn mapped_points(
    points: &[crate::model::Point],
    origin: (f64, f64),
    source: (u32, u32),
) -> Vec<(f64, f64)> {
    points
        .iter()
        .map(|point| {
            (
                point.x * source.0 as f64 - origin.0,
                point.y * source.1 as f64 - origin.1,
            )
        })
        .collect()
}

fn stroke_scale(source: (u32, u32), viewport: Option<ViewportRect>) -> f64 {
    viewport
        .filter(|viewport| viewport.width.is_finite() && viewport.width > 0.0)
        .map(|viewport| source.0 as f64 / viewport.width)
        .filter(|scale| scale.is_finite() && *scale > 0.0)
        .unwrap_or(1.0)
}

fn paint_annotation(
    image: &mut RgbaImage,
    annotation: &Annotation,
    source: (u32, u32),
    origin: (f64, f64),
    scale: f64,
    at_ms: u64,
) {
    // A keyframe captured during the overlay fade is still evidence the user pointed
    // at something, so burn the stroke at full opacity. Only fully faded annotations
    // are skipped.
    if annotation.opacity_at(at_ms) <= 0.0 {
        return;
    }
    let points = mapped_points(&annotation.points, origin, source);
    if points.len() < 2 {
        return;
    }
    let first = points[0];
    let last = points[points.len() - 1];
    // Reproduce the CSS-pixel stroke the user drew instead of deriving a thinner
    // width from the (possibly cropped) output image.
    let stroke_width = annotation
        .stroke_width
        .filter(|width| width.is_finite() && *width > 0.0)
        .unwrap_or(DEFAULT_STROKE_WIDTH_CSS_PX);
    let thickness = (stroke_width * scale).max(1.0);
    let head = (ARROW_HEAD_CSS_PX * scale).max(thickness * 3.0);

    match annotation.kind {
        AnnotationKind::Freehand => draw_polyline(image, &points, thickness, INK),
        AnnotationKind::Circle => {
            let center = ((first.0 + last.0) / 2.0, (first.1 + last.1) / 2.0);
            let radii = (
                ((last.0 - first.0).abs() / 2.0).max(2.0),
                ((last.1 - first.1).abs() / 2.0).max(2.0),
            );
            draw_ellipse(image, center, radii, thickness, INK);
        }
        AnnotationKind::Highlight => {
            let x = first.0.min(last.0).round() as i32;
            let y = first.1.min(last.1).round() as i32;
            let width = (last.0 - first.0).abs().round() as i32;
            let height = (last.1 - first.1).abs().round() as i32;
            fill_rect(image, x, y, width, height, HIGHLIGHT);
            draw_rect_stroke(
                image,
                x,
                y,
                width,
                height,
                thickness.round().max(1.0) as i32,
                INK,
            );
        }
        AnnotationKind::Arrow => {
            let angle = (last.1 - first.1).atan2(last.0 - first.0);
            let head_left = (
                last.0 - head * (angle - std::f64::consts::FRAC_PI_6).cos(),
                last.1 - head * (angle - std::f64::consts::FRAC_PI_6).sin(),
            );
            let head_right = (
                last.0 - head * (angle + std::f64::consts::FRAC_PI_6).cos(),
                last.1 - head * (angle + std::f64::consts::FRAC_PI_6).sin(),
            );
            draw_line(image, first, last, thickness, INK);
            draw_line(image, last, head_left, thickness, INK);
            draw_line(image, last, head_right, thickness, INK);
        }
    }
}

fn text_width(text: &str, size: f32) -> f32 {
    let font = font();
    let scaled = font.as_scaled(PxScale::from(size));
    text.chars()
        .map(|character| scaled.h_advance(font.glyph_id(character)))
        .sum()
}

fn truncate(text: &str, size: f32, max_width: f32) -> String {
    if text_width(text, size) <= max_width {
        return text.to_owned();
    }
    let ellipsis = "…";
    let mut result = String::new();
    for character in text.chars() {
        let candidate = format!("{result}{character}");
        if text_width(&format!("{candidate}{ellipsis}"), size) > max_width {
            break;
        }
        result.push(character);
    }
    format!("{result}{ellipsis}")
}

#[allow(clippy::too_many_arguments)]
fn draw_text(image: &mut RgbaImage, text: &str, x: i32, baseline: i32, size: f32, color: Rgba<u8>) {
    let font = font();
    let scale = PxScale::from(size);
    let scaled = font.as_scaled(scale);
    let mut caret = x as f32;

    for character in text.chars() {
        let id = font.glyph_id(character);
        if let Some(outline) =
            font.outline_glyph(id.with_scale_and_position(scale, point(caret, baseline as f32)))
        {
            let bounds = outline.px_bounds();
            outline.draw(|gx, gy, coverage| {
                let px = bounds.min.x as i32 + gx as i32;
                let py = bounds.min.y as i32 + gy as i32;
                blend(image, px, py, with_alpha(color, coverage));
            });
        }
        caret += scaled.h_advance(id);
    }
}

fn accent(reason: KeyframeReason) -> Rgba<u8> {
    match reason {
        KeyframeReason::Mark => Rgba([255, 190, 61, 255]),
        KeyframeReason::Annotation => Rgba([255, 80, 104, 255]),
        KeyframeReason::SpeechCue => Rgba([179, 136, 255, 255]),
        KeyframeReason::VisualChange => Rgba([84, 196, 255, 255]),
        KeyframeReason::Interaction => Rgba([106, 153, 255, 255]),
    }
}

fn clock(ms: u64) -> String {
    let seconds = ms / 1_000;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

pub struct RenderedFrame {
    pub image: RgbaImage,
}

/// Crop a captured frame and burn its annotations into it.
///
/// `viewport` is the CSS-pixel viewport the annotations were drawn in. It scales
/// stroke widths from CSS pixels to captured pixels so lines keep their original
/// weight, including after a crop. `at_ms` drops annotations whose fade completed;
/// annotations still present are burned at full opacity.
pub fn render_frame(
    source_path: &Path,
    crop: Option<NormalizedRect>,
    annotations: &[Annotation],
    viewport: Option<ViewportRect>,
    at_ms: u64,
) -> Result<RenderedFrame, RenderError> {
    let source = image::open(source_path).map_err(|error| {
        RenderError::new(format!(
            "Could not read frame {}: {error}",
            source_path.display()
        ))
    })?;
    let source = source.to_rgba8();
    let (source_width, source_height) = source.dimensions();
    if source_width == 0 || source_height == 0 {
        return Err(RenderError::new(format!(
            "Frame {} has no pixels.",
            source_path.display()
        )));
    }

    let (x0, y0, width, height) = match crop {
        Some(crop) => {
            let x0 = (crop.x.clamp(0.0, 1.0) * source_width as f64).floor() as u32;
            let y0 = (crop.y.clamp(0.0, 1.0) * source_height as f64).floor() as u32;
            let width = (crop.width.clamp(0.0, 1.0) * source_width as f64)
                .ceil()
                .max(1.0) as u32;
            let height = (crop.height.clamp(0.0, 1.0) * source_height as f64)
                .ceil()
                .max(1.0) as u32;
            (
                x0.min(source_width.saturating_sub(1)),
                y0.min(source_height.saturating_sub(1)),
                width.min(source_width.saturating_sub(x0)),
                height.min(source_height.saturating_sub(y0)),
            )
        }
        None => (0, 0, source_width, source_height),
    };

    let mut frame = if crop.is_some() {
        image::imageops::crop_imm(&source, x0, y0, width, height).to_image()
    } else {
        source
    };

    let scale = stroke_scale((source_width, source_height), viewport);
    for annotation in annotations {
        paint_annotation(
            &mut frame,
            annotation,
            (source_width, source_height),
            (x0 as f64, y0 as f64),
            scale,
            at_ms,
        );
    }

    Ok(RenderedFrame { image: frame })
}

/// Save an already-rendered frame as PNG.
pub fn save_png(image: &RgbaImage, path: &Path) -> Result<(), RenderError> {
    image
        .save_with_format(path, image::ImageFormat::Png)
        .map_err(|error| RenderError::new(format!("Could not write {}: {error}", path.display())))
}

/// One keyframe in the contact sheet.
pub struct SheetFrame<'a> {
    pub image: &'a RgbaImage,
    pub index: usize,
    pub at_ms: u64,
    pub reason: KeyframeReason,
    pub caption: String,
}

fn fill_cell_background(image: &mut RgbaImage, x: i32, y: i32, width: i32, height: i32) {
    fill_rect(image, x, y, width, height, Rgba([24, 26, 32, 255]));
}

/// Compose selected keyframes into one contact sheet PNG.
pub fn render_contact_sheet(
    frames: &[SheetFrame<'_>],
    title: &str,
    width: u32,
) -> Result<RgbaImage, RenderError> {
    if frames.is_empty() {
        return Err(RenderError::new(
            "A contact sheet needs at least one keyframe.",
        ));
    }

    let width = width.clamp(640, 2400);
    let count = frames.len();
    let columns = match count {
        1 => 1,
        2..=4 => 2,
        5..=9 => 3,
        _ => 4,
    };
    let padding = (width as f32 * 0.015).round().max(16.0) as i32;
    let gap = (padding as f32 * 0.7).round() as i32;
    let header_height = (width as f32 * 0.055).round().max(56.0) as i32;
    let caption_height = (width as f32 * 0.047).round().max(48.0) as i32;
    let cell_width = (width as i32 - padding * 2 - gap * (columns as i32 - 1)) / columns as i32;
    let image_height = ((cell_width as f32) * 0.62).round() as i32;
    let rows = count.div_ceil(columns) as i32;
    let height = header_height
        + padding
        + rows * (image_height + caption_height)
        + (rows - 1) * gap
        + padding;

    let mut sheet = RgbaImage::from_pixel(width, height as u32, BACKGROUND);

    draw_text(
        &mut sheet,
        title,
        padding,
        header_height / 2 + 8,
        (width as f32 * 0.016).clamp(16.0, 28.0),
        TEXT,
    );
    let subtitle = format!("{count} keyframes · read summary.md first");
    let subtitle_size = (width as f32 * 0.011).clamp(11.0, 16.0);
    draw_text(
        &mut sheet,
        &subtitle,
        width as i32 - padding - text_width(&subtitle, subtitle_size) as i32,
        header_height / 2 + 7,
        subtitle_size,
        MUTED,
    );

    for (position, frame) in frames.iter().enumerate() {
        let column = position as i32 % columns as i32;
        let row = position as i32 / columns as i32;
        let x = padding + column * (cell_width + gap);
        let y = header_height + padding + row * (image_height + caption_height + gap);

        fill_rect(
            &mut sheet,
            x,
            y,
            cell_width,
            image_height + caption_height,
            CELL,
        );
        draw_rect_stroke(
            &mut sheet,
            x,
            y,
            cell_width,
            image_height + caption_height,
            1,
            BORDER,
        );
        fill_rect(&mut sheet, x, y, cell_width, 4, accent(frame.reason));

        fill_cell_background(&mut sheet, x, y, cell_width, image_height);

        let source = frame.image;
        let scale = (cell_width as f64 / source.width() as f64)
            .min(image_height as f64 / source.height() as f64);
        let target_width = (source.width() as f64 * scale).round().max(1.0) as u32;
        let target_height = (source.height() as f64 * scale).round().max(1.0) as u32;
        let resized = image::imageops::resize(
            source,
            target_width,
            target_height,
            image::imageops::FilterType::Triangle,
        );
        let offset_x = x + (cell_width - target_width as i32) / 2;
        let offset_y = y + (image_height - target_height as i32) / 2;
        image::imageops::overlay(&mut sheet, &resized, offset_x as i64, offset_y as i64);

        let caption_y = y + image_height;
        draw_text(
            &mut sheet,
            &format!("#{}", frame.index),
            x + 12,
            caption_y + 24,
            (width as f32 * 0.013).clamp(13.0, 19.0),
            TEXT,
        );
        draw_text(
            &mut sheet,
            &clock(frame.at_ms),
            x + 12
                + (text_width(
                    &format!("#{}", frame.index),
                    (width as f32 * 0.013).clamp(13.0, 19.0),
                ) + 14.0) as i32,
            caption_y + 24,
            (width as f32 * 0.013).clamp(13.0, 19.0),
            MUTED,
        );
        draw_disc(
            &mut sheet,
            (x + cell_width - 16) as f64,
            (caption_y + 18) as f64,
            4.0,
            accent(frame.reason),
        );

        let label_size = (width as f32 * 0.011).clamp(11.0, 15.0);
        let label = truncate(&frame.caption, label_size, (cell_width - 24) as f32);
        draw_text(
            &mut sheet,
            &label,
            x + 12,
            caption_y + caption_height - 12,
            label_size,
            MUTED,
        );
    }

    Ok(sheet)
}

/// Load a frame for sheet composition.
pub fn load_rgba(path: &Path) -> Result<RgbaImage, RenderError> {
    image::open(path)
        .map(|image| image.to_rgba8())
        .map_err(|error| RenderError::new(format!("Could not read {}: {error}", path.display())))
}
