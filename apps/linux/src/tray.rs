//! StatusNotifierItem tray integration. This uses the host's real SNI watcher
//! (for example Omarchy's quickshell bar) rather than assuming a GNOME
//! AppIndicator extension exists.

use std::io::Cursor;
use std::sync::{Arc, OnceLock};

use ksni::blocking::{Handle, TrayMethods};
use ksni::menu::{MenuItem, StandardItem};
use ksni::{Icon, Status, ToolTip, Tray};

use crate::state::{Action, Phase, SharedState, Snapshot};

const TRAY_PNGS: &[&[u8]] = &[
    include_bytes!("../assets/icons/highlite-tray-22.png"),
    include_bytes!("../assets/icons/highlite-tray-24.png"),
    include_bytes!("../assets/icons/highlite-tray-32.png"),
    include_bytes!("../assets/icons/highlite-tray-44.png"),
    include_bytes!("../assets/icons/highlite-tray-48.png"),
    include_bytes!("../assets/icons/highlite-tray-64.png"),
];

pub struct HighliteTray {
    shared: Arc<SharedState>,
    snapshot: Snapshot,
    icons: Vec<Icon>,
}

impl HighliteTray {
    fn new(shared: Arc<SharedState>) -> Self {
        Self {
            snapshot: shared.snapshot(),
            shared,
            icons: tray_icons(),
        }
    }
}

impl Tray for HighliteTray {
    const MENU_ON_ACTIVATE: bool = false;

    fn id(&self) -> String {
        "highlite".to_owned()
    }

    fn title(&self) -> String {
        "Highlite".to_owned()
    }

    fn category(&self) -> ksni::Category {
        ksni::Category::ApplicationStatus
    }

    fn status(&self) -> Status {
        match self.snapshot.phase {
            Phase::Failed => Status::NeedsAttention,
            _ => Status::Active,
        }
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        self.icons.clone()
    }

    fn icon_name(&self) -> String {
        "com.highlite.Highlite".to_owned()
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            icon_name: "com.highlite.Highlite".to_owned(),
            icon_pixmap: self.icons.clone(),
            title: "Highlite".to_owned(),
            description: self.tooltip_text(),
        }
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        self.shared.push_action(Action::Show);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let status = self.snapshot.status_line();
        let detail = self.snapshot.compact_detail();
        let running = self.snapshot.is_running();
        let active = matches!(self.snapshot.phase, Phase::Running | Phase::Starting);

        let mut items = vec![
            StandardItem {
                label: status,
                enabled: false,
                ..Default::default()
            }
            .into(),
        ];
        if matches!(self.snapshot.phase, Phase::Failed) && !detail.is_empty() {
            items.push(
                StandardItem {
                    label: detail,
                    enabled: false,
                    ..Default::default()
                }
                .into(),
            );
        }
        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Open Dashboard".to_owned(),
                enabled: true,
                activate: Box::new(|this: &mut Self| this.shared.push_action(Action::Show)),
                ..Default::default()
            }
            .into(),
        );
        if active {
            items.push(
                StandardItem {
                    label: "Stop Relay".to_owned(),
                    enabled: true,
                    activate: Box::new(|this: &mut Self| this.shared.push_action(Action::Stop)),
                    ..Default::default()
                }
                .into(),
            );
        } else {
            items.push(
                StandardItem {
                    label: "Start Relay".to_owned(),
                    enabled: true,
                    activate: Box::new(|this: &mut Self| this.shared.push_action(Action::Start)),
                    ..Default::default()
                }
                .into(),
            );
        }
        if running {
            items.push(
                StandardItem {
                    label: "Restart Relay".to_owned(),
                    enabled: true,
                    activate: Box::new(|this: &mut Self| this.shared.push_action(Action::Restart)),
                    ..Default::default()
                }
                .into(),
            );
        }
        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Quit Highlite".to_owned(),
                enabled: true,
                activate: Box::new(|this: &mut Self| this.shared.push_action(Action::Quit)),
                ..Default::default()
            }
            .into(),
        );
        items
    }

    fn watcher_online(&self) {
        self.shared.set_tray_available(true);
    }

    fn watcher_offline(&self, _reason: ksni::OfflineReason) -> bool {
        self.shared.set_tray_available(false);
        // If the window was hidden while the tray host was alive, make it
        // reachable again before the tray disappears.
        self.shared.push_action(Action::Present);
        // Keep the item alive so it appears when a StatusNotifierHost starts,
        // for example after the desktop shell restarts.
        true
    }
}

impl HighliteTray {
    fn tooltip_text(&self) -> String {
        let detail = self.snapshot.compact_detail();
        if detail.is_empty() {
            self.snapshot.status_line()
        } else {
            format!("{}\n{detail}", self.snapshot.status_line())
        }
    }
}

pub fn spawn(shared: Arc<SharedState>) -> Result<Handle<HighliteTray>, ksni::Error> {
    let tray = HighliteTray::new(Arc::clone(&shared));
    // Optimistic until ksni reports the watcher missing inside spawn(). Do not
    // set this after spawn: that would overwrite watcher_offline().
    shared.set_tray_available(true);
    match tray.assume_sni_available(true).spawn() {
        Ok(handle) => Ok(handle),
        Err(error) => {
            shared.set_tray_available(false);
            Err(error)
        }
    }
}

pub fn publish(handle: &Handle<HighliteTray>, snapshot: &Snapshot) {
    let snapshot = snapshot.clone();
    let _ = handle.update(move |tray| tray.snapshot = snapshot);
}

fn tray_icons() -> Vec<Icon> {
    static ICONS: OnceLock<Vec<Icon>> = OnceLock::new();
    ICONS
        .get_or_init(|| {
            TRAY_PNGS
                .iter()
                .filter_map(|bytes| decode_argb(bytes))
                .collect()
        })
        .clone()
}

fn decode_argb(bytes: &[u8]) -> Option<Icon> {
    let decoder = png::Decoder::new(Cursor::new(bytes));
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    if frame.color_type != png::ColorType::Rgba
        || frame.width as usize * frame.height as usize * 4 > buffer.len()
    {
        return None;
    }
    let width = i32::try_from(frame.width).ok()?;
    let height = i32::try_from(frame.height).ok()?;
    let rgba = &buffer[..frame.width as usize * frame.height as usize * 4];
    let mut data = Vec::with_capacity(rgba.len());
    let (pixels, remainder) = rgba.as_chunks::<4>();
    debug_assert!(remainder.is_empty());
    for pixel in pixels {
        // StatusNotifierItem expects ARGB32 in network byte order.
        data.extend_from_slice(&[pixel[3], pixel[0], pixel[1], pixel[2]]);
    }
    Some(Icon {
        width,
        height,
        data,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_committed_tray_icon_decodes() {
        let icons = tray_icons();
        assert_eq!(icons.len(), TRAY_PNGS.len());
        for icon in icons {
            assert!(icon.width > 0);
            assert_eq!(
                icon.data.len(),
                icon.width as usize * icon.height as usize * 4
            );
            assert!(
                icon.data
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .any(|pixel| pixel[3] > 0)
            );
        }
    }
}
