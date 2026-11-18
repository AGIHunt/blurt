//! The monitor's PipeWire stream (the fd and node from the portal's ScreenCast), read directly with libpipewire rather than
//! GStreamer's pipewiresrc: only the stream itself carries the pointer (cursor meta: position and bitmap, since the cursor is
//! not drawn into the frames) and what changed (video damage), and pipewiresrc passes neither on.
//!
//! Frames are asked for in shared memory (MemFd / MemPtr), never DMA-BUF: the crop is cut on the CPU anyway, and a mapped
//! buffer needs no GPU. Each frame's damage goes into the Mirror (mirror.rs); the feeder (screen.rs) is woken when it touches
//! the crop. The pointer and its look go to `Shared.cursor`, where Input::pointer and cursor_shape read them.

use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use pipewire as pw;
use pw::spa;
use spa::pod::{ChoiceValue, Object, Pod, Property, PropertyFlags, Value};
use spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Id};

use super::math::Rect;
use super::mirror::Mirror;
use crate::host::CursorShape;

/// What the stream knows about the pointer.
#[derive(Default)]
pub struct Cursor {
    /// where it is, in frame pixels (may be outside the monitor's frame, or None when GNOME says it isn't on this monitor)
    pub at: Option<(i32, i32)>,
    pub shape: Option<CursorShape>,
    /// the shape changed since `cursor_shape()` last took it
    pub shape_new: bool,
    shape_hash: u64,
}

/// Between the PipeWire thread, the feeder and Input.
#[derive(Default)]
pub struct Shared {
    pub mirror: Mutex<Mirror>,
    pub cursor: Mutex<Cursor>,
    /// frame pixels per logical point (the monitor's scale), once both sizes are known
    pub scale: Mutex<f64>,
    /// frames with a picture from the compositor, and pointer-only updates, since the feeder's last report
    pub frames_in: std::sync::atomic::AtomicU32,
    pub cursor_only: std::sync::atomic::AtomicU32,
}

/// A changed frame went into the mirror: its damage (None: all of it) and when it arrived (the backend's clock).
pub type OnFrame = Arc<dyn Fn(Option<Vec<Rect>>, f64) + Send + Sync>;

pub struct Capture {
    quit: Option<pw::channel::Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        if let Some(q) = self.quit.take() {
            let _ = q.send(());
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn gst_format(f: spa::param::video::VideoFormat) -> Option<&'static str> {
    use spa::param::video::VideoFormat as F;
    Some(match f {
        F::BGRx => "BGRx",
        F::BGRA => "BGRA",
        F::RGBx => "RGBx",
        F::RGBA => "RGBA",
        F::xRGB => "xRGB",
        F::xBGR => "xBGR",
        F::ARGB => "ARGB",
        F::ABGR => "ABGR",
        _ => return None,
    })
}

fn pod(obj: Object) -> Vec<u8> {
    spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &Value::Object(obj)).unwrap().0.into_inner()
}

fn enum_format() -> Vec<u8> {
    use spa::param::format::{FormatProperties, MediaSubtype, MediaType};
    use spa::param::video::VideoFormat as F;
    let obj = spa::pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(FormatProperties::MediaType, Id, MediaType::Video),
        spa::pod::property!(FormatProperties::MediaSubtype, Id, MediaSubtype::Raw),
        spa::pod::property!(FormatProperties::VideoFormat, Choice, Enum, Id, F::BGRx, F::BGRx, F::BGRA, F::RGBx, F::RGBA, F::xRGB, F::xBGR, F::ARGB, F::ABGR),
        spa::pod::property!(
            FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            spa::utils::Rectangle { width: 1920, height: 1080 },
            spa::utils::Rectangle { width: 1, height: 1 },
            spa::utils::Rectangle { width: 16384, height: 16384 }
        ),
        spa::pod::property!(
            FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            spa::utils::Fraction { num: 60, denom: 1 },
            spa::utils::Fraction { num: 0, denom: 1 },
            spa::utils::Fraction { num: 1000, denom: 1 }
        ),
    );
    pod(obj)
}

fn buffers_and_metas(width: u32, height: u32, stride: u32) -> Vec<Vec<u8>> {
    use spa::sys as s;
    let int = |v: i32| Value::Int(v);
    let p = |key: u32, value: Value| Property { key, flags: PropertyFlags::empty(), value };
    let mem = (1i32 << s::SPA_DATA_MemFd) | (1i32 << s::SPA_DATA_MemPtr);
    let buffers = Object {
        type_: s::SPA_TYPE_OBJECT_ParamBuffers,
        id: s::SPA_PARAM_Buffers,
        properties: vec![
            p(s::SPA_PARAM_BUFFERS_buffers, Value::Choice(ChoiceValue::Int(Choice(ChoiceFlags::empty(), ChoiceEnum::Range { default: 4, min: 2, max: 8 })))),
            p(s::SPA_PARAM_BUFFERS_blocks, int(1)),
            p(s::SPA_PARAM_BUFFERS_size, int((stride * height) as i32)),
            p(s::SPA_PARAM_BUFFERS_stride, int(stride as i32)),
            p(s::SPA_PARAM_BUFFERS_dataType, Value::Choice(ChoiceValue::Int(Choice(ChoiceFlags::empty(), ChoiceEnum::Flags { default: mem, flags: vec![mem] })))),
        ],
    };
    let meta = |kind: u32, size: Value| Object {
        type_: s::SPA_TYPE_OBJECT_ParamMeta,
        id: s::SPA_PARAM_Meta,
        properties: vec![p(s::SPA_PARAM_META_type, Value::Id(Id(kind))), p(s::SPA_PARAM_META_size, size)],
    };
    let cursor_size = |side: usize| {
        (std::mem::size_of::<s::spa_meta_cursor>() + std::mem::size_of::<s::spa_meta_bitmap>() + side * side * 4) as i32
    };
    let _ = width;
    vec![
        pod(buffers),
        pod(meta(s::SPA_META_Header, int(std::mem::size_of::<s::spa_meta_header>() as i32))),
        pod(meta(
            s::SPA_META_Cursor,
            Value::Choice(ChoiceValue::Int(Choice(ChoiceFlags::empty(), ChoiceEnum::Range { default: cursor_size(64), min: cursor_size(1), max: cursor_size(512) }))),
        )),
        pod(meta(
            s::SPA_META_VideoDamage,
            Value::Choice(ChoiceValue::Int(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Range {
                    default: (std::mem::size_of::<s::spa_meta_region>() * 16) as i32,
                    min: std::mem::size_of::<s::spa_meta_region>() as i32,
                    max: (std::mem::size_of::<s::spa_meta_region>() * 64) as i32,
                },
            ))),
        )),
    ]
}

struct Format {
    width: u32,
    height: u32,
    format: Option<&'static str>,
}

fn hash(b: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    b.hash(&mut h);
    h.finish()
}

/// The cursor's bitmap (RGBA / BGRA / ARGB…) as a PNG: straight RGBA rows.
fn bitmap_png(format: spa::param::video::VideoFormat, w: u32, h: u32, stride: usize, data: &[u8]) -> Option<Vec<u8>> {
    use spa::param::video::VideoFormat as F;
    let order: [usize; 4] = match format {
        F::RGBA | F::RGBx => [0, 1, 2, 3],
        F::BGRA | F::BGRx => [2, 1, 0, 3],
        F::ARGB | F::xRGB => [1, 2, 3, 0],
        F::ABGR | F::xBGR => [3, 2, 1, 0],
        _ => return None,
    };
    let opaque = matches!(format, F::RGBx | F::BGRx | F::xRGB | F::xBGR);
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h as usize {
        let row = data.get(y * stride..y * stride + w as usize * 4)?;
        for px in row.as_chunks::<4>().0 {
            rgba.extend_from_slice(&[px[order[0]], px[order[1]], px[order[2]], if opaque { 255 } else { px[order[3]] }]);
        }
    }
    let mut out = vec![];
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut wr = enc.write_header().ok()?;
        wr.write_image_data(&rgba).ok()?;
    }
    Some(out)
}

/// Starts reading the stream on a thread of its own. `fd`: the portal's PipeWire remote (None: the user's own daemon, for
/// tests with a `pipewiresink` node). Returns once connected, or why not.
pub fn start(fd: Option<OwnedFd>, node: Option<u32>, shared: Arc<Shared>, now: fn() -> f64, on_frame: OnFrame) -> Result<Capture, String> {
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    let (quit_tx, quit_rx) = pw::channel::channel::<()>();
    let thread = std::thread::Builder::new()
        .name("blurt-remote-pw".into())
        .spawn(move || {
            let r = run(fd, node, shared, now, on_frame, quit_rx, &ready_tx);
            if let Err(e) = r {
                let _ = ready_tx.send(Err(e));
            }
        })
        .map_err(|e| e.to_string())?;
    match ready_rx.recv_timeout(std::time::Duration::from_secs(10)) {
        Ok(Ok(())) => Ok(Capture { quit: Some(quit_tx), thread: Some(thread) }),
        Ok(Err(e)) => {
            let _ = thread.join();
            Err(e)
        }
        Err(_) => {
            let _ = quit_tx.send(());
            Err("the screen stream didn't start".into())
        }
    }
}

fn run(
    fd: Option<OwnedFd>,
    node: Option<u32>,
    shared: Arc<Shared>,
    now: fn() -> f64,
    on_frame: OnFrame,
    quit: pw::channel::Receiver<()>,
    ready: &std::sync::mpsc::Sender<Result<(), String>>,
) -> Result<(), String> {
    pw::init();
    let ml = pw::main_loop::MainLoopRc::new(None).map_err(|e| format!("pipewire: {e}"))?;
    let ctx = pw::context::ContextRc::new(&ml, None).map_err(|e| format!("pipewire: {e}"))?;
    let core = match fd {
        Some(fd) => ctx.connect_fd_rc(fd, None),
        None => ctx.connect_rc(None),
    }
    .map_err(|e| format!("pipewire connect: {e}"))?;
    let stream = pw::stream::StreamBox::new(
        &core,
        "blurt-remote",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| format!("pipewire stream: {e}"))?;
    let ml2 = ml.clone();
    let _quit = quit.attach(ml.loop_(), move |_| ml2.quit());
    let debug = std::env::var_os("BLURT_REMOTE_DEBUG").is_some();
    let sh = shared.clone();
    let _listener = stream
        .add_local_listener_with_user_data(Format { width: 0, height: 0, format: None })
        .state_changed(move |_, _, old, new| {
            if debug {
                eprintln!("blurt-remote: pipewire stream {old:?} → {new:?}");
            }
        })
        .param_changed(move |stream, f, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = spa::param::video::VideoInfoRaw::new();
            if info.parse(param).is_err() {
                return;
            }
            f.width = info.size().width;
            f.height = info.size().height;
            f.format = gst_format(info.format());
            if debug {
                eprintln!("blurt-remote: pipewire format {:?} {}×{} @{}/{}", info.format(), f.width, f.height, info.framerate().num, info.framerate().denom);
            }
            let params = buffers_and_metas(f.width, f.height, f.width * 4);
            let mut pods: Vec<&Pod> = params.iter().filter_map(|b| Pod::from_bytes(b)).collect();
            let _ = stream.update_params(&mut pods);
        })
        .process(move |stream, f| {
            while let Some(mut b) = stream.dequeue_buffer() {
                // the pointer first: it comes with frames and on its own (a buffer with no picture)
                if let Some(c) = b.find_meta::<spa::buffer::meta::MetaCursor>() {
                    if c.is_valid() && c.id() != 0 {
                        let mut cur = sh.cursor.lock().unwrap();
                        cur.at = Some((c.position().x, c.position().y));
                        if let Some(bm) = c.bitmap() {
                            if let Some(data) = bm.bitmap_data() {
                                let (w, h) = (bm.size().width, bm.size().height);
                                let hsh = hash(data) ^ ((c.hotspot().x as u64) << 32 | c.hotspot().y as u64);
                                if w > 0 && h > 0 && hsh != cur.shape_hash {
                                    cur.shape_hash = hsh;
                                    let scale = *sh.scale.lock().unwrap();
                                    if let Some(png) = bitmap_png(bm.format(), w, h, bm.stride().unsigned_abs() as usize, data) {
                                        let (pw_, ph, hx, hy) = super::math::cursor_points(w, h, c.hotspot().x, c.hotspot().y, scale);
                                        cur.shape = Some(CursorShape { png, hot_x: hx, hot_y: hy, width: pw_, height: ph });
                                        cur.shape_new = true;
                                    }
                                }
                            }
                        }
                    } else if c.is_valid() {
                        // id 0: no new cursor data (or the pointer left this monitor, which GNOME also writes as id 0 with
                        // a position off the frame): the position still counts when it's given
                        let p = c.position();
                        if p.x != 0 || p.y != 0 {
                            sh.cursor.lock().unwrap().at = Some((p.x, p.y));
                        }
                    }
                }
                let corrupted = b
                    .find_meta::<spa::buffer::meta::MetaHeader>()
                    .is_some_and(|h| h.flags().contains(spa::buffer::meta::MetaHeaderFlags::CORRUPTED));
                let damage: Option<Vec<Rect>> = b.find_meta::<spa::buffer::meta::MetaVideoDamage>().map(|d| {
                    d.iter()
                        .map(|r| Rect {
                            x: r.position().x.max(0) as u32,
                            y: r.position().y.max(0) as u32,
                            w: r.size().width,
                            h: r.size().height,
                        })
                        .collect()
                });
                let Some(format) = f.format else { continue };
                let (w, h) = (f.width, f.height);
                let datas = b.datas_mut();
                let Some(d) = datas.first_mut() else { continue };
                let (size, offset, stride) = (d.chunk().size() as usize, d.chunk().offset() as usize, d.chunk().stride());
                let chunk_corrupted = d.chunk().flags().contains(spa::buffer::ChunkFlags::CORRUPTED);
                // a cursor-only update: no picture (GNOME sends size 0, or flags it)
                if corrupted || chunk_corrupted || size == 0 {
                    sh.cursor_only.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    continue;
                }
                let stride = if stride > 0 { stride as usize } else { w as usize * 4 };
                let Some(bytes) = d.data() else { continue };
                let Some(px) = bytes.get(offset..offset + size.min(bytes.len().saturating_sub(offset))) else { continue };
                let applied = sh.mirror.lock().unwrap().apply(px, stride, w, h, format, damage.as_deref());
                if applied {
                    sh.frames_in.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    on_frame(damage, now());
                }
            }
        })
        .register()
        .map_err(|e| format!("pipewire listener: {e}"))?;
    let fmt = enum_format();
    let mut params = [Pod::from_bytes(&fmt).ok_or("format pod")?];
    stream
        .connect(spa::utils::Direction::Input, node, pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS, &mut params)
        .map_err(|e| format!("pipewire connect stream: {e}"))?;
    let _ = ready.send(Ok(()));
    ml.run();
    let _ = stream.disconnect();
    Ok(())
}
