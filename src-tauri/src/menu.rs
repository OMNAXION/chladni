//! Native macOS menu bar (Chladni / File / Edit / View / Playback / Window / Help).
//!
//! Two kinds of item:
//!
//! - **Playback** items act in Rust, on the same [`AppState`] methods the media keys and the tray
//!   use, so they work whatever the page is doing (and from the mini player). They emit nothing.
//! - **UI** items (new playlist, find, navigation, panels, zoom, …) emit `menu://<id>` to the main
//!   window with no payload, and the SPA does the work. [`UI_EVENTS`] lists every one; the UI
//!   stream wires them in `ui/src/lib/`.
//!
//! The predefined items (Undo … Select All, Hide, Quit, Minimize, Full Screen) are AppKit's own,
//! so text editing in the webview keeps working exactly as in any Mac app.
//!
//! An accelerator here owns its key combo: the page must not bind the same combo in
//! `shortcuts.ts`, or it handles the key first and the menu item never fires (WKWebView offers a
//! key equivalent to the page before the menu, and a `preventDefault` there consumes it).

use std::sync::Arc;

use tauri::menu::{
    AboutMetadataBuilder, CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu,
    SubmenuBuilder,
};
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::state::AppState;

/// Every item that is forwarded to the page as `menu://<id>`, with its accelerator (for the
/// report and the shortcuts overlay). Keep in sync with [`build`].
pub const UI_EVENTS: &[(&str, &str)] = &[
    ("check-updates", ""),
    ("preferences", "Cmd+,"),
    ("new-playlist", "Cmd+N"),
    ("new-folder", "Alt+Cmd+N"),
    ("find", "Cmd+F"),
    ("search", "Cmd+K"),
    ("back", "Cmd+Left"),
    ("forward", "Cmd+Right"),
    ("toggle-sidebar", "Alt+Shift+L"),
    ("toggle-now-playing", "Alt+Shift+R"),
    ("toggle-queue", "Alt+Shift+Q"),
    ("zoom-in", "Cmd+="),
    ("zoom-out", "Cmd+-"),
    ("zoom-reset", "Cmd+0"),
    ("like", "Alt+Shift+B"),
    ("shortcuts", "Cmd+/"),
];

/// Seconds a Seek Forward / Seek Backward item moves the playhead.
const SEEK_STEP: f64 = 10.0;
/// Volume step for Volume Up / Volume Down, in percent.
const VOLUME_STEP: i64 = 10;

// TODO: Add owner-provided website, help and issue links before restoring those entries.

fn item(
    app: &AppHandle,
    id: &str,
    text: &str,
    accel: Option<&str>,
) -> tauri::Result<MenuItem<Wry>> {
    MenuItem::with_id(app, id, text, true, accel)
}

/// Build the menu bar. Set as the app menu in lib.rs `setup`.
pub fn build(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let version = app.package_info().version.to_string();
    let about = PredefinedMenuItem::about(
        app,
        Some("About Chladni"),
        Some(
            AboutMetadataBuilder::new()
                .name(Some("Chladni"))
                .version(Some(version))
                .comments(Some(
                    "A free, open-source, ad-free music player.\n\
                     Based on Limusic by SimoHypers (github.com/SimoHypers/limusic).",
                ))
                .license(Some("GPL-3.0-or-later"))
                .build(),
        ),
    )?;
    let sep = || PredefinedMenuItem::separator(app);

    let app_menu = SubmenuBuilder::new(app, "Chladni")
        .item(&about)
        .item(&item(app, "check-updates", "Check for Updates…", None)?)
        .item(&sep()?)
        .item(&item(app, "preferences", "Settings…", Some("Cmd+,"))?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::services(app, None)?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::hide(app, Some("Hide Chladni"))?)
        .item(&PredefinedMenuItem::hide_others(app, None)?)
        .item(&PredefinedMenuItem::show_all(app, None)?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::quit(app, Some("Quit Chladni"))?)
        .build()?;

    // stream: wave2. Spotify's File › Offline Mode: a check item on the downloads setting (the
    // same one as Settings › Storage › Offline mode), kept in step by `sync_offline_mode`.
    let offline = CheckMenuItem::with_id(
        app,
        OFFLINE_MODE,
        "Offline Mode",
        true,
        crate::downloads::offline_mode(),
        None::<&str>,
    )?;
    let file = SubmenuBuilder::with_id(app, FILE_MENU, "File")
        .item(&item(app, "new-playlist", "New Playlist", Some("Cmd+N"))?)
        .item(&item(app, "new-folder", "New Playlist Folder", Some("Alt+Cmd+N"))?)
        .item(&sep()?)
        .item(&offline)
        .item(&sep()?)
        .item(&PredefinedMenuItem::close_window(app, None)?)
        .build()?;

    let edit = SubmenuBuilder::new(app, "Edit")
        .item(&PredefinedMenuItem::undo(app, None)?)
        .item(&PredefinedMenuItem::redo(app, None)?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .item(&PredefinedMenuItem::select_all(app, None)?)
        .item(&sep()?)
        .item(&item(app, "find", "Find", Some("Cmd+F"))?)
        .item(&item(app, "search", "Search", Some("Cmd+K"))?)
        .build()?;

    let view = SubmenuBuilder::new(app, "View")
        .item(&item(app, "back", "Back", Some("Cmd+Left"))?)
        .item(&item(app, "forward", "Forward", Some("Cmd+Right"))?)
        .item(&sep()?)
        .item(&item(app, "toggle-sidebar", "Show/Hide Your Library", Some("Alt+Shift+L"))?)
        .item(&item(app, "toggle-now-playing", "Show/Hide Now Playing View", Some("Alt+Shift+R"))?)
        .item(&item(app, "toggle-queue", "Show/Hide Queue", Some("Alt+Shift+Q"))?)
        .item(&sep()?)
        .item(&item(app, "zoom-in", "Zoom In", Some("Cmd+="))?)
        .item(&item(app, "zoom-out", "Zoom Out", Some("Cmd+-"))?)
        .item(&item(app, "zoom-reset", "Actual Size", Some("Cmd+0"))?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::fullscreen(app, None)?)
        .build()?;

    let playback = SubmenuBuilder::new(app, "Playback")
        .item(&item(app, "play-pause", "Play/Pause", Some("Space"))?)
        .item(&item(app, "next-track", "Next", Some("Ctrl+Cmd+Right"))?)
        .item(&item(app, "previous-track", "Previous", Some("Ctrl+Cmd+Left"))?)
        .item(&sep()?)
        .item(&item(app, "seek-forward", "Seek Forward", Some("Shift+Cmd+Right"))?)
        .item(&item(app, "seek-backward", "Seek Backward", Some("Shift+Cmd+Left"))?)
        .item(&sep()?)
        .item(&item(app, "volume-up", "Volume Up", Some("Cmd+Up"))?)
        .item(&item(app, "volume-down", "Volume Down", Some("Cmd+Down"))?)
        .item(&item(app, "mute", "Mute", Some("Shift+Cmd+Down"))?)
        .item(&sep()?)
        .item(&item(app, "shuffle", "Shuffle", Some("Alt+S"))?)
        .item(&item(app, "repeat", "Repeat", Some("Alt+R"))?)
        .item(&sep()?)
        .item(&item(app, "like", "Save to Liked Songs", Some("Alt+Shift+B"))?)
        .build()?;

    let window = SubmenuBuilder::new(app, "Window")
        .item(&PredefinedMenuItem::minimize(app, None)?)
        .item(&PredefinedMenuItem::maximize(app, Some("Zoom"))?)
        .item(&sep()?)
        .item(&item(app, "mini-player", "Mini Player", Some("Alt+Cmd+M"))?)
        .item(&item(app, "show-main", "Chladni", Some("Alt+Cmd+1"))?)
        .item(&sep()?)
        .item(&PredefinedMenuItem::bring_all_to_front(app, None)?)
        .build()?;

    let help = SubmenuBuilder::new(app, "Help")
        .item(&item(app, "shortcuts", "Keyboard Shortcuts", Some("Cmd+/"))?)
        .build()?;

    let menu = Menu::with_items(app, &[&app_menu, &file, &edit, &view, &playback, &window, &help])?;
    set_nsapp_roles(&window, &help);
    Ok(menu)
}

/// Let AppKit fill in the Window menu's window list and the Help menu's search field.
fn set_nsapp_roles(window: &Submenu<Wry>, help: &Submenu<Wry>) {
    #[cfg(target_os = "macos")]
    {
        let _ = window.set_as_windows_menu_for_nsapp();
        let _ = help.set_as_help_menu_for_nsapp();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (window, help);
}

// ── stream: wave2 (File › Offline Mode) ──
const FILE_MENU: &str = "file";
const OFFLINE_MODE: &str = "offline-mode";

/// The File › Offline Mode item, if the menu bar is up.
fn offline_item(app: &AppHandle) -> Option<CheckMenuItem<Wry>> {
    let file = app.menu()?.get(FILE_MENU)?;
    file.as_submenu()?.get(OFFLINE_MODE)?.as_check_menuitem().cloned()
}

/// Put the check mark where the setting is. The downloads manager calls this on every change,
/// whoever made it (this item, Settings, the UI store).
pub fn sync_offline_mode(app: &AppHandle, on: bool) {
    if let Some(item) = offline_item(app) {
        if item.is_checked().ok() != Some(on) {
            let _ = item.set_checked(on);
        }
    }
}
// ── end stream: wave2 ──

/// The app-wide menu event handler (lib.rs `on_menu_event`). Tray ids (`show`, `play_pause`, …)
/// arrive here too and are ignored: the tray handles its own.
pub fn handle(app: &AppHandle, id: &str) {
    if let Some((ui, _)) = UI_EVENTS.iter().find(|(ui, _)| *ui == id) {
        // The page does the work; it has to be on screen for that.
        if !matches!(*ui, "zoom-in" | "zoom-out" | "zoom-reset" | "like") {
            crate::tray::show_main(app);
        }
        let _ = app.emit_to("main", &format!("menu://{ui}"), ());
        return;
    }
    match id {
        "show-main" => crate::tray::show_main(app),
        // AppKit has already flipped the mark; the setting follows it (and emits
        // `downloads:network`, which the page's store and Settings listen to).
        OFFLINE_MODE => {
            let on = offline_item(app).and_then(|i| i.is_checked().ok());
            if let Some(on) = on {
                crate::downloads::set_offline_mode(on);
            }
        }
        "mini-player" => {
            let handle = app.clone();
            let _ = app.run_on_main_thread(move || {
                if handle.get_webview_window(crate::mini::LABEL).is_some() {
                    crate::mini::dismiss(&handle);
                } else if let Err(e) = crate::mini::open(&handle) {
                    tracing::warn!(error = %e, "menu: mini player failed to open");
                }
            });
        }
        "play-pause" | "next-track" | "previous-track" | "seek-forward" | "seek-backward"
        | "volume-up" | "volume-down" | "mute" | "shuffle" | "repeat" => playback(app, id),
        _ => {}
    }
}

fn playback(app: &AppHandle, id: &str) {
    let Some(state) = app.try_state::<Arc<AppState>>() else { return };
    let state = state.inner().clone();
    let (app, id) = (app.clone(), id.to_owned());
    tauri::async_runtime::spawn(async move {
        match id.as_str() {
            "play-pause" => state.resume_or_toggle().await,
            "next-track" => state.next_in_queue().await,
            "previous-track" => state.prev_in_queue().await,
            "seek-forward" | "seek-backward" => {
                let step = if id == "seek-forward" { SEEK_STEP } else { -SEEK_STEP };
                let _ = state.user_seek((state.current_position() + step).max(0.0)).await;
            }
            "volume-up" => crate::hotkeys::change_volume(&state, &app, |v| v + VOLUME_STEP),
            "volume-down" => crate::hotkeys::change_volume(&state, &app, |v| v - VOLUME_STEP),
            "mute" => crate::hotkeys::toggle_mute(&state, &app),
            "shuffle" => state.toggle_shuffle().await,
            "repeat" => state.cycle_repeat().await,
            _ => {}
        }
    });
}

#[cfg(test)]
mod tests {
    use super::UI_EVENTS;

    /// stream: wave2. Offline Mode acts in Rust (the downloads setting); forwarding it to the page
    /// as well would toggle it twice.
    #[test]
    fn offline_mode_is_handled_natively() {
        assert!(UI_EVENTS.iter().all(|(id, _)| *id != super::OFFLINE_MODE));
    }

    /// Chladni › Check for Updates… is the page's (Settings › About shows the outcome).
    #[test]
    fn check_for_updates_reaches_the_page() {
        assert!(UI_EVENTS.iter().any(|(id, _)| *id == "check-updates"));
    }

    #[test]
    fn ui_event_ids_are_unique_and_url_safe() {
        let mut seen = std::collections::HashSet::new();
        for (id, _) in UI_EVENTS {
            assert!(seen.insert(*id), "duplicate menu id {id}");
            assert!(id.chars().all(|c| c.is_ascii_lowercase() || c == '-'), "{id}");
        }
    }
}
