use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use gtk::gdk;
use gtk::gdk_pixbuf;
use gtk::glib;
use gtk::prelude::*;
use gtk::{
    Application, ApplicationWindow, Button, CssProvider, Image, Justification, Label, Orientation,
    Stack, StackTransitionType,
};
use highlite_desktop::config::DesktopPaths;
use highlite_desktop::relay::{RelayPoll, RelayProcess, locate_relay_binary};
use highlite_desktop::state::{Action, Phase, SharedState, Snapshot};
use highlite_desktop::tray::{self, HighliteTray};
use ksni::blocking::Handle;
use webkit2gtk::{
    LoadEvent, NavigationPolicyDecision, NavigationPolicyDecisionExt, PolicyDecisionExt,
    PolicyDecisionType, SettingsExt, URIRequestExt, WebContext, WebView, WebViewExt,
};

const APP_ID: &str = "com.highlite.Highlite";
const APP_ICON: &[u8] = include_bytes!("../assets/icons/highlite-256.png");
const STATUS_ICON: &[u8] = include_bytes!("../assets/icons/highlite-128.png");
const CSS: &str = r#"
.highlite-root {
  background-color: #1d151a;
}
.highlite-title {
  color: #f8f5f2;
  font-size: 32px;
  font-weight: 700;
}
.highlite-status {
  color: #efff3d;
  font-size: 16px;
  font-weight: 600;
}
.highlite-detail {
  color: #cbbbc4;
  font-size: 13px;
}
.highlite-muted {
  color: #8f7f88;
  font-size: 12px;
}
button.highlite-primary {
  background-image: none;
  background-color: #efff3d;
  color: #241a20;
  border-radius: 8px;
  border-width: 0;
  padding: 9px 18px;
  font-weight: 700;
}
button.highlite-primary:hover {
  background-color: #f8ff73;
}
"#;

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn request_shutdown(_signal: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Relaxed);
}

fn install_signal_handlers() {
    unsafe {
        libc::signal(
            libc::SIGTERM,
            request_shutdown as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            request_shutdown as *const () as libc::sighandler_t,
        );
    }
}

struct Shell {
    application: Application,
    window: ApplicationWindow,
    stack: Stack,
    status_label: Label,
    detail_label: Label,
    footer_label: Label,
    tray_note: Label,
    retry_button: Button,
    paths: DesktopPaths,
    binary: Option<PathBuf>,
    shared: Arc<SharedState>,
    relay: RefCell<Option<RelayProcess>>,
    webview: RefCell<Option<WebView>>,
    dashboard_url: RefCell<Option<String>>,
    dashboard_port: Rc<Cell<u16>>,
    tray: RefCell<Option<Handle<HighliteTray>>>,
    last_ui_revision: Cell<u64>,
    last_tray_revision: Cell<u64>,
    ready_logged: Cell<bool>,
    quitting: Cell<bool>,
}

impl Shell {
    fn new(application: &Application) -> Result<Self, String> {
        install_css()?;
        let paths = DesktopPaths::from_environment()?;
        paths.prepare()?;
        let shared = SharedState::new();
        let binary = locate_relay_binary(None);

        let window = ApplicationWindow::builder()
            .application(application)
            .title("Highlite")
            .default_width(1180)
            .default_height(820)
            .build();
        window.set_widget_name("highlite-window");
        window.style_context().add_class("highlite-root");
        if let Ok(pixbuf) = gdk_pixbuf::Pixbuf::from_read(APP_ICON) {
            window.set_icon(Some(&pixbuf));
        }

        let stack = Stack::new();
        stack.style_context().add_class("highlite-root");
        stack.set_transition_type(StackTransitionType::Crossfade);
        stack.set_transition_duration(150);
        window.add(&stack);

        let status_root = gtk::Box::new(Orientation::Vertical, 0);
        status_root.set_widget_name("highlite-window");
        status_root.style_context().add_class("highlite-root");
        status_root.set_halign(gtk::Align::Center);
        status_root.set_valign(gtk::Align::Center);

        let content = gtk::Box::new(Orientation::Vertical, 12);
        content.set_margin_top(48);
        content.set_margin_bottom(48);
        content.set_margin_start(48);
        content.set_margin_end(48);
        content.set_halign(gtk::Align::Center);

        if let Ok(pixbuf) = gdk_pixbuf::Pixbuf::from_read(STATUS_ICON) {
            let image = Image::from_pixbuf(Some(&pixbuf));
            image.set_pixel_size(96);
            content.add(&image);
        }

        let title = Label::new(None);
        title.set_markup("<span>Highlite</span>");
        title.style_context().add_class("highlite-title");
        content.add(&title);

        let status_label = Label::new(Some("Relay stopped"));
        status_label.style_context().add_class("highlite-status");
        status_label.set_justify(Justification::Center);
        content.add(&status_label);

        let detail_label = Label::new(Some("Start the local relay to open the session dashboard."));
        detail_label.style_context().add_class("highlite-detail");
        detail_label.set_line_wrap(true);
        detail_label.set_justify(Justification::Center);
        detail_label.set_max_width_chars(72);
        content.add(&detail_label);

        let retry_button = Button::with_label("Start relay");
        retry_button.style_context().add_class("highlite-primary");
        retry_button.set_halign(gtk::Align::Center);
        retry_button.set_margin_top(8);
        content.add(&retry_button);

        let tray_note = Label::new(Some(
            "Tray icon unavailable. Closing this window quits Highlite.",
        ));
        tray_note.style_context().add_class("highlite-muted");
        tray_note.set_line_wrap(true);
        tray_note.set_justify(Justification::Center);
        tray_note.set_max_width_chars(72);
        tray_note.set_visible(false);
        content.add(&tray_note);

        let footer_label = Label::new(Some(&format!(
            "Captures stay on this device: {}",
            paths.data_dir.display()
        )));
        footer_label.style_context().add_class("highlite-muted");
        footer_label.set_line_wrap(true);
        footer_label.set_justify(Justification::Center);
        footer_label.set_max_width_chars(72);
        footer_label.set_margin_top(18);
        footer_label.set_selectable(true);
        content.add(&footer_label);

        status_root.add(&content);
        stack.add_named(&status_root, "status");
        stack.set_visible_child_name("status");

        let tray = match tray::spawn(Arc::clone(&shared)) {
            Ok(handle) => {
                if !shared.tray_available() {
                    eprintln!(
                        "highlite-desktop: no StatusNotifierWatcher; tray icon unavailable and closing the window will quit"
                    );
                }
                Some(handle)
            }
            Err(error) => {
                eprintln!("highlite-desktop: tray unavailable: {error}");
                None
            }
        };
        Ok(Self {
            application: application.clone(),
            window,
            stack,
            status_label,
            detail_label,
            footer_label,
            tray_note,
            retry_button,
            paths,
            binary,
            shared,
            relay: RefCell::new(None),
            webview: RefCell::new(None),
            dashboard_url: RefCell::new(None),
            dashboard_port: Rc::new(Cell::new(0)),
            tray: RefCell::new(tray),
            last_ui_revision: Cell::new(0),
            last_tray_revision: Cell::new(0),
            ready_logged: Cell::new(false),
            quitting: Cell::new(false),
        })
    }

    fn wire(self: &Rc<Self>) {
        let retry = Rc::clone(self);
        self.retry_button.connect_clicked(move |_| {
            retry.start_relay_from_user();
        });

        let close = Rc::clone(self);
        self.window.connect_delete_event(move |_, _| {
            if close.quitting.get() {
                return glib::Propagation::Proceed;
            }
            if close.shared.tray_available() {
                close.window.hide();
            } else {
                close.request_quit();
            }
            glib::Propagation::Stop
        });
    }

    fn open(self: &Rc<Self>) {
        self.window.present();
    }

    fn install_timer(self: &Rc<Self>) {
        let shell = Rc::clone(self);
        glib::timeout_add_local(Duration::from_millis(250), move || {
            if shell.quitting.get() {
                return glib::ControlFlow::Break;
            }
            if SHUTDOWN_REQUESTED.load(Ordering::Relaxed) {
                shell.request_quit();
                return glib::ControlFlow::Break;
            }
            shell.tick();
            glib::ControlFlow::Continue
        });
    }

    fn start_relay_from_user(self: &Rc<Self>) {
        if self.quitting.get() {
            return;
        }
        if self.relay.borrow().is_some() {
            self.open_dashboard();
            return;
        }
        let Some(binary) = self.binary.clone() else {
            self.publish_failed(
                "highlite-relay was not found. Build it with `cargo build -p highlite-relay`, install the app with its bundled relay, or set HIGHLITE_RELAY_BIN."
                    .to_owned(),
            );
            return;
        };
        match RelayProcess::spawn(&self.paths, &binary, None) {
            Ok(process) => {
                self.ready_logged.set(false);
                let info = process.info().clone();
                *self.relay.borrow_mut() = Some(process);
                self.shared.publish(Snapshot {
                    phase: Phase::Starting,
                    port: Some(info.port),
                    relay_pid: Some(info.pid),
                    binary: Some(info.binary),
                    detail: "Waiting for the local relay health and token checks.".to_owned(),
                });
                self.apply_snapshot();
            }
            Err(error) => self.publish_failed(error),
        }
    }

    fn stop_relay(&self) {
        if let Some(mut process) = self.relay.borrow_mut().take() {
            process.stop();
        }
        self.ready_logged.set(false);
        self.clear_webview();
        self.shared.publish(Snapshot {
            phase: Phase::Stopped,
            port: None,
            relay_pid: None,
            binary: self.binary.clone(),
            detail: "Relay is stopped. Start it to reopen the local session dashboard.".to_owned(),
        });
        self.apply_snapshot();
    }

    fn restart_relay(self: &Rc<Self>) {
        self.stop_relay();
        self.start_relay_from_user();
    }

    fn open_dashboard(self: &Rc<Self>) {
        if self.shared.snapshot().is_running() {
            self.window.present();
            if self.webview.borrow().is_some() {
                self.stack.set_visible_child_name("dashboard");
            }
            return;
        }
        if self.relay.borrow().is_some() {
            self.window.present();
            return;
        }
        self.window.present();
        self.start_relay_from_user();
    }

    fn publish_failed(&self, detail: String) {
        self.shared.publish(Snapshot {
            phase: Phase::Failed,
            port: None,
            relay_pid: None,
            binary: self.binary.clone(),
            detail,
        });
        self.apply_snapshot();
    }

    fn tick(self: &Rc<Self>) {
        for action in self.shared.take_actions() {
            match action {
                Action::Show => self.open_dashboard(),
                Action::Present => self.window.present(),
                Action::Start => self.start_relay_from_user(),
                Action::Stop => self.stop_relay(),
                Action::Restart => self.restart_relay(),
                Action::Quit => {
                    self.request_quit();
                    return;
                }
            }
        }

        let poll = {
            let mut relay = self.relay.borrow_mut();
            relay.as_mut().map(RelayProcess::poll)
        };
        if let Some(poll) = poll {
            match poll {
                RelayPoll::Starting => {
                    if self.shared.snapshot().phase != Phase::Starting {
                        let info = self
                            .relay
                            .borrow()
                            .as_ref()
                            .map(|process| process.info().clone());
                        if let Some(info) = info {
                            self.shared.publish(Snapshot {
                                phase: Phase::Starting,
                                port: Some(info.port),
                                relay_pid: Some(info.pid),
                                binary: Some(info.binary),
                                detail: "Waiting for the local relay health and token checks."
                                    .to_owned(),
                            });
                        }
                    }
                }
                RelayPoll::Ready => {
                    let ready = self
                        .relay
                        .borrow()
                        .as_ref()
                        .map(|process| (process.info().clone(), process.dashboard_url()));
                    if let Some((info, url)) = ready {
                        self.shared.publish(Snapshot {
                            phase: Phase::Running,
                            port: Some(info.port),
                            relay_pid: Some(info.pid),
                            binary: Some(info.binary),
                            detail: format!(
                                "Dashboard served locally from 127.0.0.1:{} with a session-only token. Captures are stored in {}.",
                                info.port,
                                self.paths.data_dir.display()
                            ),
                        });
                        self.ensure_webview(&url, info.port);
                        if !self.ready_logged.replace(true) {
                            eprintln!(
                                "highlite-desktop: relay ready at http://127.0.0.1:{}/ (token withheld)",
                                info.port
                            );
                        }
                    }
                }
                RelayPoll::Failed(detail) => {
                    self.ready_logged.set(false);
                    eprintln!("highlite-desktop: relay failed: {detail}");
                    if let Some(mut process) = self.relay.borrow_mut().take() {
                        process.stop();
                    }
                    self.clear_webview();
                    self.publish_failed(detail);
                }
            }
        }

        let revision = self.shared.revision();
        if revision != self.last_ui_revision.get() {
            self.last_ui_revision.set(revision);
            self.apply_snapshot();
        }
        if revision != self.last_tray_revision.get() {
            self.last_tray_revision.set(revision);
            if let Some(handle) = self.tray.borrow().as_ref() {
                tray::publish(handle, &self.shared.snapshot());
            }
        }
        self.update_tray_note();
    }

    fn apply_snapshot(&self) {
        let snapshot = self.shared.snapshot();
        self.status_label.set_text(&snapshot.status_line());
        self.detail_label.set_text(&snapshot.compact_detail());
        match snapshot.phase {
            Phase::Running => {
                self.retry_button.set_visible(false);
                if self.webview.borrow().is_some() {
                    self.stack.set_visible_child_name("dashboard");
                }
            }
            Phase::Starting => {
                self.retry_button.set_label("Starting…");
                self.retry_button.set_sensitive(false);
                self.retry_button.set_visible(true);
                self.stack.set_visible_child_name("status");
            }
            Phase::Stopped | Phase::Failed => {
                self.retry_button
                    .set_label(if snapshot.phase == Phase::Failed {
                        "Try again"
                    } else {
                        "Start relay"
                    });
                self.retry_button.set_sensitive(true);
                self.retry_button.set_visible(true);
                self.stack.set_visible_child_name("status");
            }
            Phase::Stopping => {
                self.retry_button.set_label("Stopping…");
                self.retry_button.set_sensitive(false);
                self.retry_button.set_visible(true);
                self.stack.set_visible_child_name("status");
            }
        }
    }

    fn update_tray_note(&self) {
        let available = self.shared.tray_available();
        self.tray_note.set_visible(!available);
        if available {
            self.footer_label.set_text(&format!(
                "Captures stay on this device: {}",
                self.paths.data_dir.display()
            ));
        } else {
            self.footer_label.set_text(&format!(
                "Tray icon unavailable on this desktop. Captures stay on this device: {}",
                self.paths.data_dir.display()
            ));
        }
    }

    fn ensure_webview(&self, url: &str, port: u16) {
        self.dashboard_port.set(port);
        let needs_load = self.dashboard_url.borrow().as_deref() != Some(url);
        if self.webview.borrow().is_none() {
            let webview = self.build_webview();
            self.stack.add_named(&webview, "dashboard");
            *self.webview.borrow_mut() = Some(webview);
        }
        if needs_load && let Some(webview) = self.webview.borrow().as_ref() {
            webview.load_uri(url);
            *self.dashboard_url.borrow_mut() = Some(url.to_owned());
        }
        self.stack.set_visible_child_name("dashboard");
    }

    #[allow(deprecated)]
    fn build_webview(&self) -> WebView {
        let context = WebContext::new_ephemeral();
        let webview = WebView::builder().web_context(&context).build();
        webview.set_hexpand(true);
        webview.set_vexpand(true);
        webview.set_background_color(&gdk::RGBA::new(0.114, 0.082, 0.102, 1.0));
        if let Some(settings) = WebViewExt::settings(&webview) {
            settings.set_enable_developer_extras(false);
            settings.set_enable_write_console_messages_to_stdout(false);
            settings.set_enable_page_cache(false);
        }

        let allowed_port = Rc::clone(&self.dashboard_port);
        let window = self.window.clone();
        webview.connect_decide_policy(move |_, decision, decision_type| {
            if decision_type != PolicyDecisionType::NavigationAction {
                return false;
            }
            let Some(navigation) = decision.downcast_ref::<NavigationPolicyDecision>() else {
                return false;
            };
            let uri: Option<String> = navigation
                .request()
                .and_then(|request| request.uri())
                .map(|uri| uri.to_string());
            let Some(uri) = uri else {
                decision.ignore();
                return true;
            };
            if navigation_allowed(&uri, allowed_port.get()) {
                return false;
            }
            decision.ignore();
            open_external(&window, &uri);
            true
        });

        let allowed_port = Rc::clone(&self.dashboard_port);
        webview.connect_load_changed(move |webview, event| {
            if event != LoadEvent::Finished {
                return;
            }
            let Some(uri) = webview.uri() else { return };
            if navigation_allowed(&uri, allowed_port.get()) && uri != "about:blank" {
                eprintln!("highlite-desktop: dashboard loaded");
            }
        });

        let window = self.window.clone();
        webview.connect_create(move |_, navigation| {
            let uri: Option<String> = navigation
                .request()
                .and_then(|request| request.uri())
                .map(|uri| uri.to_string());
            if let Some(uri) = uri {
                open_external(&window, &uri);
            }
            None
        });

        webview
    }

    fn clear_webview(&self) {
        *self.dashboard_url.borrow_mut() = None;
        if let Some(webview) = self.webview.borrow().as_ref() {
            webview.load_uri("about:blank");
        }
    }

    fn request_quit(&self) {
        if self.quitting.get() {
            return;
        }
        self.quitting.set(true);
        self.stop_relay();
        self.clear_webview();
        if let Some(handle) = self.tray.borrow_mut().take() {
            let _ = handle.shutdown();
        }
        self.application.quit();
    }
}

fn navigation_allowed(uri: &str, port: u16) -> bool {
    if uri == "about:blank" {
        return true;
    }
    let prefix = format!("http://127.0.0.1:{port}");
    uri == prefix || uri.starts_with(&format!("{prefix}/"))
}

fn open_external(window: &ApplicationWindow, uri: &str) {
    if uri.starts_with("http://") || uri.starts_with("https://") || uri.starts_with("mailto:") {
        let _ = gtk::show_uri_on_window(Some(window), uri, 0);
    }
}

fn install_css() -> Result<(), String> {
    let provider = CssProvider::new();
    provider
        .load_from_data(CSS.as_bytes())
        .map_err(|error| format!("could not load Highlite styles: {error}"))?;
    if let Some(screen) = gdk::Screen::default() {
        gtk::StyleContext::add_provider_for_screen(
            &screen,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
    Ok(())
}

fn main() -> glib::ExitCode {
    install_signal_handlers();
    let application_id = std::env::var("HIGHLITE_DESKTOP_APP_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| APP_ID.to_owned());
    let application = Application::builder()
        .application_id(application_id)
        .build();
    let shell: Rc<RefCell<Option<Rc<Shell>>>> = Rc::new(RefCell::new(None));
    let shell_for_activate = Rc::clone(&shell);

    application.connect_activate(move |application| {
        if let Some(existing) = shell_for_activate.borrow().as_ref() {
            existing.open_dashboard();
            return;
        }
        match Shell::new(application) {
            Ok(shell) => {
                let shell = Rc::new(shell);
                shell.wire();
                *shell_for_activate.borrow_mut() = Some(Rc::clone(&shell));
                shell.open();
                shell.start_relay_from_user();
                shell.install_timer();
            }
            Err(error) => {
                eprintln!("highlite-desktop: could not start: {error}");
                application.quit();
            }
        }
    });

    application.run()
}

#[cfg(test)]
mod tests {
    use super::navigation_allowed;

    #[test]
    fn only_the_owned_loopback_origin_is_allowed() {
        assert!(navigation_allowed("about:blank", 41234));
        assert!(navigation_allowed("http://127.0.0.1:41234/", 41234));
        assert!(navigation_allowed(
            "http://127.0.0.1:41234/sessions/1",
            41234
        ));
        assert!(!navigation_allowed("http://127.0.0.1:41235/", 41234));
        assert!(!navigation_allowed("https://example.com/", 41234));
        assert!(!navigation_allowed("file:///etc/passwd", 41234));
    }
}
