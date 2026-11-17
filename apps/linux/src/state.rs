//! State shared between the GTK main thread and the StatusNotifier tray thread.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub phase: Phase,
    pub port: Option<u16>,
    pub relay_pid: Option<u32>,
    pub binary: Option<PathBuf>,
    pub detail: String,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Stopped,
            port: None,
            relay_pid: None,
            binary: None,
            detail: "Relay is stopped.".to_owned(),
        }
    }
}

impl Snapshot {
    pub fn status_line(&self) -> String {
        match self.phase {
            Phase::Stopped => "Relay stopped".to_owned(),
            Phase::Starting => "Starting relay…".to_owned(),
            Phase::Running => match self.port {
                Some(port) => format!("Relay running on 127.0.0.1:{port}"),
                None => "Relay running".to_owned(),
            },
            Phase::Stopping => "Stopping relay…".to_owned(),
            Phase::Failed => "Relay needs attention".to_owned(),
        }
    }

    pub fn compact_detail(&self) -> String {
        let detail = self.detail.trim();
        if detail.is_empty() {
            String::new()
        } else if detail.chars().count() > 180 {
            let mut clipped: String = detail.chars().take(177).collect();
            clipped.push('…');
            clipped
        } else {
            detail.to_owned()
        }
    }

    pub fn is_running(&self) -> bool {
        self.phase == Phase::Running
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Show,
    Present,
    Start,
    Stop,
    Restart,
    Quit,
}

pub struct SharedState {
    snapshot: Mutex<Snapshot>,
    actions: Mutex<VecDeque<Action>>,
    revision: AtomicU64,
    tray_available: AtomicBool,
}

impl SharedState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            snapshot: Mutex::new(Snapshot::default()),
            actions: Mutex::new(VecDeque::new()),
            revision: AtomicU64::new(0),
            tray_available: AtomicBool::new(false),
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone()
    }

    pub fn publish(&self, snapshot: Snapshot) {
        let changed = {
            let mut current = self
                .snapshot
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            if *current == snapshot {
                false
            } else {
                *current = snapshot;
                true
            }
        };
        if changed {
            self.revision.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Relaxed)
    }

    pub fn push_action(&self, action: Action) {
        let mut actions = self
            .actions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if matches!(action, Action::Show | Action::Present) && actions.contains(&action) {
            return;
        }
        actions.push_back(action);
    }

    pub fn take_actions(&self) -> Vec<Action> {
        let mut actions = self
            .actions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        actions.drain(..).collect()
    }

    pub fn set_tray_available(&self, available: bool) {
        self.tray_available.store(available, Ordering::Relaxed);
    }

    pub fn tray_available(&self) -> bool {
        self.tray_available.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publishes_changes_and_coalesces_show_actions() {
        let state = SharedState::new();
        let initial = state.revision();
        state.publish(Snapshot {
            phase: Phase::Running,
            port: Some(41234),
            relay_pid: Some(10),
            binary: None,
            detail: "ready".to_owned(),
        });
        assert!(state.revision() > initial);
        assert_eq!(
            state.snapshot().status_line(),
            "Relay running on 127.0.0.1:41234"
        );
        state.publish(state.snapshot());
        let unchanged = state.revision();
        state.publish(state.snapshot());
        assert_eq!(state.revision(), unchanged);

        state.push_action(Action::Show);
        state.push_action(Action::Show);
        state.push_action(Action::Present);
        state.push_action(Action::Present);
        state.push_action(Action::Quit);
        assert_eq!(
            state.take_actions(),
            vec![Action::Show, Action::Present, Action::Quit]
        );
        assert!(state.take_actions().is_empty());
    }
}
