//! "Move Chladni to your Applications folder?" at a launch from anywhere else: the mounted DMG,
//! ~/Downloads, or an App Translocation mirror of either. LetsMove's logic, cut down: copy the
//! bundle to /Applications (never ~/Applications), replacing and first quitting an older copy
//! there, register it with LaunchServices so it shows in Apps/Launchpad, relaunch it, eject the
//! DMG we ran from, quit. Falls back to an admin prompt when /Applications is not writable, and
//! says so in an alert when even that fails. See docs/streams/installer.md.
//!
//! Env knobs (tests and scripts):
//!   SPOTLESS_NO_MOVE=1           never offer (smoke/perf scripts; LIMUSIC_MULTI and ENCORE_PERF
//!                                also turn it off)
//!   SPOTLESS_MOVE_TARGET=<dir>   install there instead of /Applications; also enables the offer
//!                                in debug builds, ignores "Don't ask again", and relaunches the
//!                                binary directly (inheriting env) instead of through `open`
//!   SPOTLESS_MOVE_ANSWER=move|later  answer the dialog without showing it

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const APPLICATIONS: &str = "/Applications";
const DECLINED_KEY: &str = "SpotlessMoveToApplicationsDeclined";

/// A launch that should be offered the move: where the bundle really lives, and where it goes.
pub(crate) struct Offer {
    bundle: PathBuf,
    target: PathBuf,
    test: bool,
}

/// Decided before any plugin runs, because a pending offer must keep the single-instance plugin
/// out: otherwise a new copy launched from the DMG would just wake the old one in /Applications
/// and exit, and could never replace it.
pub(crate) fn pending() -> Option<Offer> {
    let env = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty());
    if ["SPOTLESS_NO_MOVE", "LIMUSIC_MULTI", "ENCORE_PERF"].into_iter().any(|k| env(k).is_some()) {
        return None;
    }
    let custom = env("SPOTLESS_MOVE_TARGET").map(PathBuf::from);
    let test = custom.is_some();
    if cfg!(debug_assertions) && !test {
        return None;
    }
    let bundle = bundle_of(&std::env::current_exe().ok()?)?;
    let bundle = untranslocate(&bundle).unwrap_or(bundle);
    let target = custom.unwrap_or_else(|| PathBuf::from(APPLICATIONS));
    if !needs_move(&bundle, &target) || (!test && declined()) {
        return None;
    }
    Some(Offer { bundle, target, test })
}

/// The `.app` that holds this executable (`X.app/Contents/MacOS/exe`), if any.
fn bundle_of(exe: &Path) -> Option<PathBuf> {
    let macos = exe.parent()?;
    let contents = macos.parent()?;
    let app = contents.parent()?;
    (macos.file_name()? == "MacOS"
        && contents.file_name()? == "Contents"
        && app.extension()? == "app")
        .then(|| app.to_path_buf())
}

/// Anywhere under the target (or /Applications, for a custom one) counts as installed.
fn needs_move(bundle: &Path, target: &Path) -> bool {
    !bundle.starts_with(target) && (target != Path::new(APPLICATIONS) || !bundle.starts_with(APPLICATIONS))
}

/// The mount point of the disk image `path` is on, from `hdiutil info`'s tab-separated lines.
fn dmg_mount(path: &Path, hdiutil_info: &str) -> Option<PathBuf> {
    hdiutil_info
        .lines()
        .filter_map(|l| l.rsplit('\t').next())
        .map(str::trim)
        .filter(|m| m.starts_with("/Volumes/"))
        .map(PathBuf::from)
        .find(|m| path.starts_with(m))
}

/// Shown in setup, before any window. Returns only when Chladni should carry on from where it
/// is; on a successful move the process exits here.
pub(crate) fn offer(app: &tauri::AppHandle, o: Offer) {
    let name = app.config().product_name.as_deref().unwrap_or("Chladni");
    let move_it = match std::env::var("SPOTLESS_MOVE_ANSWER").as_deref() {
        Ok("move") => true,
        Ok(_) => false,
        Err(_) => {
            let (yes, suppress) = ui::ask(&name);
            if !yes && suppress {
                ui::set_declined(DECLINED_KEY);
            }
            yes
        }
    };
    if move_it {
        let dest = o.target.join(format!("{name}.app"));
        match install(&o.bundle, &dest) {
            Ok(()) => relaunch(&o, &dest),
            Err(None) => {} // the admin prompt was cancelled: run from here, as asked
            Err(Some(e)) => {
                tracing::warn!("move to Applications failed: {e}");
                ui::alert(
                    &format!("{name} couldn't be moved to Applications"),
                    &format!("{e}\n\nYou can drag {name} into Applications yourself."),
                );
            }
        }
    }
    // Carrying on without the single-instance guard: hand over to a copy that is already running.
    if let Some(other) = other_instance() {
        let _ = Command::new("open").arg(&other).status();
        std::process::exit(0);
    }
}

fn declined() -> bool {
    ui::declined(DECLINED_KEY)
}

/// Copy `src` over `dest` (after quitting a copy running from there). `Err(None)` means the user
/// cancelled the admin prompt.
fn install(src: &Path, dest: &Path) -> Result<(), Option<String>> {
    quit_running(dest);
    // Copy next to the destination, then swap, so a failed copy never leaves a half app behind.
    // The quarantine flag goes: the user already approved this app, and a quarantined copy that
    // Finder didn't move would be translocated again.
    const SCRIPT: &str = r#"set -e; t="$2.spotless-new"; rm -rf "$t"; ditto "$1" "$t";
xattr -dr com.apple.quarantine "$t" 2>/dev/null || true; rm -rf "$2"; mv "$t" "$2""#;
    let user = Command::new("/bin/sh").args(["-c", SCRIPT, "sh"]).arg(src).arg(dest).output();
    if matches!(&user, Ok(o) if o.status.success()) {
        register(dest);
        return Ok(());
    }
    // Not writable (or a root-owned old copy): the same script as an administrator.
    let admin = Command::new("osascript")
        .args([
            "-e", "on run argv",
            "-e", "do shell script \"/bin/sh -c \" & quoted form of item 1 of argv & \" sh \" & quoted form of item 2 of argv & \" \" & quoted form of item 3 of argv with prompt \"Chladni needs your permission to install itself in Applications.\" with administrator privileges",
            "-e", "end run",
            SCRIPT,
        ])
        .arg(src)
        .arg(dest)
        .output()
        .map_err(|e| Some(e.to_string()))?;
    if admin.status.success() {
        register(dest);
        return Ok(());
    }
    let err = String::from_utf8_lossy(&admin.stderr);
    if err.contains("-128") {
        return Err(None);
    }
    let user_err = user.map(|o| String::from_utf8_lossy(&o.stderr).trim().to_owned()).unwrap_or_default();
    Err(Some(if user_err.is_empty() { err.trim().to_owned() } else { user_err }))
}

/// Make LaunchServices and Spotlight (and so Apps/Launchpad) see the new copy right away.
fn register(dest: &Path) {
    let _ = Command::new(
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    )
    .arg("-f")
    .arg(dest)
    .status();
    let _ = Command::new("mdimport").arg(dest).stderr(Stdio::null()).status();
}

/// Pids of every other process running this executable, with the bundle each runs from.
fn others() -> Vec<(u32, PathBuf)> {
    let me = std::process::id();
    let Some(exe) = std::env::current_exe().ok().and_then(|e| e.file_name().map(|n| n.to_owned())) else {
        return vec![];
    };
    let out = Command::new("pgrep").arg("-x").arg(&exe).output().map(|o| o.stdout).unwrap_or_default();
    String::from_utf8_lossy(&out)
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
        .filter(|&p| p != me)
        .filter_map(|p| {
            let o = Command::new("ps").args(["-o", "comm=", "-p", &p.to_string()]).output().ok()?;
            let path = PathBuf::from(String::from_utf8_lossy(&o.stdout).trim());
            Some((p, bundle_of(&path)?))
        })
        .collect()
}

fn other_instance() -> Option<PathBuf> {
    others().into_iter().next().map(|(_, b)| b)
}

/// SIGTERM whatever runs from `dest`, SIGKILL after 5 s.
fn quit_running(dest: &Path) {
    let pids: Vec<String> =
        others().into_iter().filter(|(_, b)| b == dest).map(|(p, _)| p.to_string()).collect();
    if pids.is_empty() {
        return;
    }
    let _ = Command::new("kill").args(&pids).status();
    for _ in 0..50 {
        let alive = Command::new("kill").arg("-0").args(&pids).stderr(Stdio::null()).status();
        if !matches!(alive, Ok(s) if s.success()) {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let _ = Command::new("kill").arg("-9").args(&pids).status();
}

/// Once this process is gone: open the new copy and eject the DMG we came from. Then exit.
fn relaunch(o: &Offer, dest: &Path) -> ! {
    let info = Command::new("hdiutil").arg("info").output().map(|o| o.stdout).unwrap_or_default();
    let mount = dmg_mount(&o.bundle, &String::from_utf8_lossy(&info)).unwrap_or_default();
    let exe = std::env::current_exe().ok().and_then(|e| e.file_name().map(|n| n.to_owned())).unwrap_or_default();
    const SCRIPT: &str = r#"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done
if [ "$4" = test ]; then LIMUSIC_MULTI=1 "$2/Contents/MacOS/$5" >/dev/null 2>&1 & else open "$2"; fi
if [ -n "$3" ]; then for i in 1 2 3 4 5 6 7 8 9 10; do hdiutil detach "$3" -quiet && break; sleep 1; done; fi"#;
    let _ = Command::new("/bin/sh")
        .args(["-c", SCRIPT, "sh", &std::process::id().to_string()])
        .arg(dest)
        .arg(&mount)
        .arg(if o.test { "test" } else { "" })
        .arg(&exe)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    tracing::info!(to = %dest.display(), from = %o.bundle.display(), "moved to Applications, relaunching");
    std::process::exit(0)
}

/// The real location of an App Translocation mirror (Security.framework, macOS 10.12+).
fn untranslocate(bundle: &Path) -> Option<PathBuf> {
    use std::ffi::c_void;
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    if !bundle.to_string_lossy().contains("/AppTranslocation/") {
        return None;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFURLCreateFromFileSystemRepresentation(a: *const c_void, b: *const u8, n: isize, dir: u8) -> *const c_void;
        fn CFURLGetFileSystemRepresentation(u: *const c_void, resolve: u8, b: *mut u8, n: isize) -> u8;
        fn CFRelease(p: *const c_void);
    }
    #[link(name = "Security", kind = "framework")]
    extern "C" {
        fn SecTranslocateCreateOriginalPathForURL(u: *const c_void, err: *mut *const c_void) -> *const c_void;
    }
    let raw = bundle.as_os_str().as_bytes();
    // SAFETY: plain CoreFoundation create/get/release on owned references, a bounded buffer.
    unsafe {
        let url = CFURLCreateFromFileSystemRepresentation(std::ptr::null(), raw.as_ptr(), raw.len() as isize, 1);
        if url.is_null() {
            return None;
        }
        let orig = SecTranslocateCreateOriginalPathForURL(url, std::ptr::null_mut());
        CFRelease(url);
        if orig.is_null() {
            return None;
        }
        let mut buf = vec![0u8; 4096];
        let ok = CFURLGetFileSystemRepresentation(orig, 1, buf.as_mut_ptr(), buf.len() as isize);
        CFRelease(orig);
        if ok == 0 {
            return None;
        }
        buf.truncate(buf.iter().position(|&b| b == 0)?);
        Some(PathBuf::from(std::ffi::OsString::from_vec(buf)))
    }
}

/// NSAlert and NSUserDefaults through the objc runtime (no AppKit bindings in the tree).
mod ui {
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool};
    use objc2::{class, msg_send};

    fn ns(s: &str) -> Retained<AnyObject> {
        let c = std::ffi::CString::new(s.replace('\0', "")).unwrap();
        // SAFETY: a NUL-terminated UTF-8 string; the result is autoreleased and retained here.
        unsafe { msg_send![class!(NSString), stringWithUTF8String: c.as_ptr()] }
    }

    fn defaults() -> Retained<AnyObject> {
        unsafe { msg_send![class!(NSUserDefaults), standardUserDefaults] }
    }

    pub(super) fn declined(key: &str) -> bool {
        let b: Bool = unsafe { msg_send![&*defaults(), boolForKey: &*ns(key)] };
        b.as_bool()
    }

    pub(super) fn set_declined(key: &str) {
        unsafe {
            let _: () = msg_send![&*defaults(), setBool: Bool::YES, forKey: &*ns(key)];
        }
    }

    fn alert_with(title: &str, text: &str, buttons: &[&str], suppress: bool) -> (isize, bool) {
        // SAFETY: main thread (Tauri's setup), standard NSAlert API.
        unsafe {
            let app: Retained<AnyObject> = msg_send![class!(NSApplication), sharedApplication];
            let _: () = msg_send![&*app, activateIgnoringOtherApps: Bool::YES];
            let alert: Retained<AnyObject> = msg_send![class!(NSAlert), new];
            let _: () = msg_send![&*alert, setMessageText: &*ns(title)];
            let _: () = msg_send![&*alert, setInformativeText: &*ns(text)];
            for b in buttons {
                let _: *mut AnyObject = msg_send![&*alert, addButtonWithTitle: &*ns(b)];
            }
            if suppress {
                let _: () = msg_send![&*alert, setShowsSuppressionButton: Bool::YES];
                let btn: *mut AnyObject = msg_send![&*alert, suppressionButton];
                let _: () = msg_send![btn, setTitle: &*ns("Don't ask again")];
            }
            let r: isize = msg_send![&*alert, runModal];
            let on = suppress && {
                let btn: *mut AnyObject = msg_send![&*alert, suppressionButton];
                let state: isize = msg_send![btn, state];
                state == 1
            };
            (r, on)
        }
    }

    /// (move?, "Don't ask again" ticked?)
    pub(super) fn ask(name: &str) -> (bool, bool) {
        let (r, suppress) = alert_with(
            &format!("Move {name} to your Applications folder?"),
            &format!("{name} will open from there, and show up in your Apps and Launchpad."),
            &["Move to Applications", "Not Now"],
            true,
        );
        (r == 1000, suppress) // NSAlertFirstButtonReturn
    }

    pub(super) fn alert(title: &str, text: &str) {
        alert_with(title, text, &["OK"], false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_bundle() {
        let b = bundle_of(Path::new("/Volumes/Chladni/Chladni.app/Contents/MacOS/limusic-app"));
        assert_eq!(b.as_deref(), Some(Path::new("/Volumes/Chladni/Chladni.app")));
        assert_eq!(bundle_of(Path::new("/Users/x/app/target/release/limusic-app")), None);
        assert_eq!(bundle_of(Path::new("/x/Chladni/Contents/MacOS/limusic-app")), None);
    }

    #[test]
    fn decides_when_to_offer() {
        let apps = Path::new("/Applications");
        assert!(needs_move(Path::new("/Volumes/Chladni/Chladni.app"), apps));
        assert!(needs_move(Path::new("/Users/x/Downloads/Chladni.app"), apps));
        assert!(needs_move(Path::new("/Users/x/Applications/Chladni.app"), apps));
        assert!(!needs_move(Path::new("/Applications/Chladni.app"), apps));
        assert!(!needs_move(Path::new("/Applications/Music/Chladni.app"), apps));
        let t = Path::new("/tmp/t");
        assert!(needs_move(Path::new("/tmp/src/Chladni.app"), t));
        assert!(!needs_move(Path::new("/tmp/t/Chladni.app"), t));
    }

    #[test]
    fn finds_the_dmg_mount() {
        let info = "framework       : 683\n================================================\n\
            image-path      : /Users/x/Downloads/Chladni-0.1.0.dmg\n\
            /dev/disk6\tGUID_partition_scheme\t\n\
            /dev/disk6s1\tApple_HFS\t/Volumes/Chladni 1\n";
        let app = Path::new("/Volumes/Chladni 1/Chladni.app");
        assert_eq!(dmg_mount(app, info).as_deref(), Some(Path::new("/Volumes/Chladni 1")));
        assert_eq!(dmg_mount(Path::new("/Volumes/Chladni/Chladni.app"), info), None);
        assert_eq!(dmg_mount(Path::new("/Users/x/Downloads/Chladni.app"), info), None);
    }
}
