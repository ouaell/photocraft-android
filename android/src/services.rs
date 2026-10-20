//! App-private directories and the injected `Services` set for Android.
//!
//! Mirror of `apps/photocraft/src/services.rs` for the subset M1 delivers
//! (import/export/write/save_file/encode_png/prefs/history log). No dialogs,
//! clipboard, recovery or automation services yet: those are later milestones
//! (see `docs/decisions/006-android-entry-minimal-services.md`).

use photocraft_codecs::{ChannelLayout, EncodeOptions, Image};
use photocraft_doc::Document;
use photocraft_ui_egui::{Services, ExportSettings};
use std::path::{Path, PathBuf};

/// The three app-private roots under the app's internal data directory
/// (`AndroidApp::internal_data_path`, `/data/user/0/<pkg>` on a real device):
/// all three live on the same private volume, so storage availability is uniform.
#[derive(Debug, Clone)]
pub struct Dirs {
    /// `PHOTOCRAFT_CONFIG_DIR`: preferences (and, in M5+, recovery and presets).
    pub config: PathBuf,
    /// `HOME`: loose per-user data; `xdg` under it feeds the font loader.
    pub files: PathBuf,
    /// `TMPDIR`: temporary files (encode scratch space).
    pub cache: PathBuf,
}

impl Dirs {
    /// Storage-off fallback when the OS gives no internal path (never seen on
    /// a real Android launch; keeps the shell bootable and logging instead of dying).
    pub fn off() -> Dirs {
        Dirs {
            config: PathBuf::from("/missing/picsh/config"),
            files: PathBuf::from("/missing/picsh/files"),
            cache: PathBuf::from("/missing/picsh/cache"),
        }
    }
}

/// Resolve and create the app directories. Only a missing internal data path is
/// fatal; individual directory creations are best-effort (a later write attempt
/// surfaces the real error to the user).
pub fn app_dirs(app: &winit::platform::android::activity::AndroidApp) -> Result<Dirs, String> {
    let base = app.internal_data_path().ok_or("no internal data directory")?;
    let dirs = Dirs {
        config: base.join("config"),
        files: base.join("files"),
        cache: base.join("cache"),
    };
    for dir in [&dirs.config, &dirs.files, &dirs.cache] {
        if let Err(e) = std::fs::create_dir_all(dir) {
            log::warn!("Picsh: cannot create {}: {e}", dir.display());
        }
    }
    // The text engine scans $XDG_DATA_HOME/fonts for the bundled set and falls back to
    // /system/fonts; apps that set both keep their own fonts reachable while the loader
    // still finds the system ones (crates/text/src/fonts.rs).
    let xdg = dirs.files.join("xdg");
    if let Err(e) = std::fs::create_dir_all(&xdg) {
        log::warn!("Picsh: cannot create {}: {e}", xdg.display());
    } else {
        let fonts = xdg.join("fonts");
        match std::fs::symlink_metadata(&fonts) {
            Ok(_) => {}
            Err(_) => {
                if let Err(e) = std::os::unix::fs::symlink("/system/fonts", &fonts) {
                    log::warn!("Picsh: cannot symlink xdg/fonts to /system/fonts: {e}");
                }
            }
        }
    }
    Ok(dirs)
}

pub fn prefs_file(dirs: &Dirs) -> PathBuf {
    dirs.config.join("preferences.json")
}

/// Write `bytes` crash-safely (temp file beside the target, fsync, rename, directory fsync).
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    photocraft_format::atomic_write(path, bytes).map_err(|e| e.to_string())
}

fn write_atomic_progress(path: &Path, bytes: &[u8], progress: &dyn Fn(f32)) -> Result<(), String> {
    photocraft_format::atomic_write_progress(path, bytes, progress).map_err(|e| e.to_string())
}

fn export_options(settings: &ExportSettings) -> photocraft_io::ExportOptions {
    let mut opts = photocraft_io::ExportOptions::default();
    if let Some(q) = settings.jpeg_quality {
        opts.encode.jpeg_quality = q;
    }
    opts.encode.webp_lossless = settings.webp_lossless;
    if let Some(q) = settings.webp_quality {
        opts.encode.webp_quality = q;
    }
    opts.tiff_layers = settings.tiff_layers;
    opts.xmp = if settings.xmp_all { photocraft_io::XmpEmbed::All } else { photocraft_io::XmpEmbed::None };
    opts.tga_bits = settings.tga_bits;
    opts.image_previews = settings.image_previews;
    opts
}

/// The share of a save's progress bar that encoding fills (desktop parity).
const ENCODE_SHARE: f32 = 0.85;

/// A save on a worker thread (`Services::save_file`): encode, then write through
/// `write_atomic_progress`, reporting progress to the ctl (see upstream services.rs).
fn save_through(doc: &Document, path: &str, settings: &ExportSettings, ctl: &photocraft_ui_egui::jobs_ui::SaveCtl) -> Result<Vec<String>, String> {
    ctl.progress(0.0, "Encoding");
    let opts = export_options(settings);
    let cancelled = || ctl.check().is_err();
    let progress = |f: f32| ctl.progress(f * ENCODE_SHARE, "");
    let interrupt = photocraft_raster::Interrupt::new(&cancelled, &progress);
    let r = crate::guard::guard("Save", || photocraft_io::export_with(doc, path, &opts, &interrupt).map_err(|e| e.to_string()))?;
    ctl.commit()?;
    ctl.progress(ENCODE_SHARE, "Writing");
    write_atomic_progress(Path::new(path), &r.bytes, &|f| ctl.progress(ENCODE_SHARE + (0.99 - ENCODE_SHARE) * f, ""))?;
    ctl.progress(1.0, "");
    Ok(r.warnings)
}

/// The `Services` the app gets. Same closures the desktop shell installs where an
/// Android filesystem path exists; `None` where the OS dialog would be required.
pub fn native(dirs: &Dirs) -> Services {
    Services {
        import: Some(Box::new(|name: &str, bytes: &[u8], max_svg_group_depth: usize| {
            crate::guard::guard("Open", || {
                photocraft_io::import_with_svg_group_depth(name, bytes, max_svg_group_depth)
                    .map(|r| (r.document, r.warnings))
                    .map_err(|e| e.to_string())
            })
        })),
        export: Some(Box::new(|doc: &Document, path: &str, settings: &ExportSettings| {
            let opts = export_options(settings);
            crate::guard::guard("Export", || {
                photocraft_io::export(doc, path, &opts).map(|r| (r.bytes, r.warnings)).map_err(|e| e.to_string())
            })
        })),
        write: Some(Box::new(|path: &str, bytes: &[u8]| write_atomic(Path::new(path), bytes))),
        save_file: Some(std::sync::Arc::new(save_through)),
        encode_png: Some(Box::new(|w, h, rgba| {
            let img = Image::from_u8(w, h, ChannelLayout::Rgba, rgba.to_vec()).map_err(|e| e.to_string())?;
            photocraft_codecs::encode(&img, photocraft_codecs::Format::Png, &EncodeOptions::default()).map_err(|e| e.to_string())
        })),
        load_prefs: Some({
            let file = prefs_file(dirs);
            Box::new(move || std::fs::read_to_string(&file).ok())
        }),
        save_prefs: Some({
            let file = prefs_file(dirs);
            Box::new(move |text: &str| write_atomic(&file, text.as_bytes()))
        }),
        append_text: Some(Box::new(|path: &str, text: &str| {
            use std::io::Write;
            let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path).map_err(|e| e.to_string())?;
            f.write_all(text.as_bytes()).map_err(|e| e.to_string())
        })),
        // Files must be opened and saved through a picker (Storage Access Framework) or
        // the share sheet; dialogs, clipboard and URL opening reach Android in M5.
        ..Default::default()
    }
}
