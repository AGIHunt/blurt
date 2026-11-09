//! Pictures of one monitor as D3D11 textures (BGRA), with what changed when the OS says.
//!
//! * Windows.Graphics.Capture first: per monitor, no cursor in the picture (the phone draws it), no yellow border where the OS
//!   lets an app turn it off (Windows 11: GraphicsCaptureAccess Borderless + IsBorderRequired = false), dirty regions from
//!   Windows 11 24H2 (GraphicsCaptureDirtyRegionMode::ReportOnly). The compositor only hands over a frame when something on the
//!   monitor changed, so a still screen costs nothing.
//! * DXGI Desktop Duplication when WGC isn't there (Windows 10 before 1903, some remote sessions): dirty and move rectangles
//!   always, and a frame that is only the pointer moving is skipped.
//! * A synthetic source (text-like rows scrolling) for measuring the encoder where there's no desktop (a service, an SSH
//!   session, CI): examples/win_smoke.rs --synthetic.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use ::windows::core::{factory, Interface, IInspectable};
use ::windows::Foundation::TypedEventHandler;
use ::windows::Graphics::Capture::{
    Direct3D11CaptureFrame, Direct3D11CaptureFramePool, GraphicsCaptureAccess, GraphicsCaptureAccessKind,
    GraphicsCaptureDirtyRegionMode, GraphicsCaptureItem, GraphicsCaptureSession,
};
use ::windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use ::windows::Graphics::DirectX::DirectXPixelFormat;
use ::windows::Graphics::SizeInt32;
use ::windows::Win32::Foundation::RECT;
use ::windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_BIND_SHADER_RESOURCE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT,
};
use ::windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use ::windows::Win32::Graphics::Dxgi::{
    IDXGIDevice, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT,
    DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_MOVE_RECT,
};
use ::windows::Win32::Graphics::Gdi::HMONITOR;
use ::windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use ::windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

use super::geometry::Rect;

/// Wakes the screen's worker: a frame arrived, or a command did.
#[derive(Clone, Default)]
pub struct Signal(Arc<(Mutex<bool>, Condvar)>);

impl Signal {
    pub fn notify(&self) {
        let (m, c) = &*self.0;
        *m.lock().unwrap_or_else(|e| e.into_inner()) = true;
        c.notify_all();
    }

    /// Wait up to `timeout` for a notify (true) or not.
    pub fn wait(&self, timeout: Duration) -> bool {
        let (m, c) = &*self.0;
        let mut set = m.lock().unwrap_or_else(|e| e.into_inner());
        if !*set && !timeout.is_zero() {
            set = c.wait_timeout(set, timeout).unwrap_or_else(|e| e.into_inner()).0;
        }
        std::mem::replace(&mut *set, false)
    }
}

pub struct Frame {
    pub texture: ID3D11Texture2D,
    pub width: u32,
    pub height: u32,
    /// what changed, in the texture's pixels; None: the OS didn't say
    pub dirty: Option<Vec<Rect>>,
    /// when it was composed, seconds on the QPC clock
    pub time: f64,
    _wgc: Option<Direct3D11CaptureFrame>,
}

impl Drop for Frame {
    fn drop(&mut self) {
        if let Some(f) = self._wgc.take() {
            let _ = f.Close();
        }
    }
}

pub enum Capture {
    Wgc(Wgc),
    Dup(Dup),
    Synthetic(Synthetic),
}

impl Capture {
    /// The monitor's pictures, WGC first. `output`: the DXGI output of that monitor, for the fallback.
    pub fn monitor(device: &ID3D11Device, monitor: HMONITOR, output: Option<&IDXGIOutput1>, signal: Signal) -> Result<Capture, String> {
        let wgc_err = match Wgc::new(device, monitor, signal) {
            Ok(w) => return Ok(Capture::Wgc(w)),
            Err(e) => e,
        };
        match output {
            Some(o) => Dup::new(device, o).map(Capture::Dup).map_err(|e| format!("Windows.Graphics.Capture: {wgc_err}; Desktop Duplication: {e}")),
            None => Err(format!("Windows.Graphics.Capture: {wgc_err}")),
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Capture::Wgc(_) => "wgc",
            Capture::Dup(_) => "dxgi-duplication",
            Capture::Synthetic(_) => "synthetic",
        }
    }

    /// The newest picture, waiting up to `timeout` for one (or until `signal` says a command came).
    pub fn next(&mut self, timeout: Duration, signal: &Signal) -> Option<Frame> {
        match self {
            Capture::Wgc(w) => w.next(timeout, signal),
            Capture::Dup(d) => d.next(timeout, signal),
            Capture::Synthetic(s) => s.next(timeout, signal),
        }
    }
}

// MARK: Windows.Graphics.Capture

pub struct Wgc {
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    device: IDirect3DDevice,
    size: SizeInt32,
    dirty_regions: bool,
}

impl Wgc {
    fn new(device: &ID3D11Device, monitor: HMONITOR, signal: Signal) -> Result<Wgc, String> {
        let e = |what: &str, err: ::windows::core::Error| format!("{what}: {err}");
        if !GraphicsCaptureSession::IsSupported().unwrap_or(false) {
            return Err("not supported here".into());
        }
        let interop = factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(|x| e("interop", x))?;
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor) }.map_err(|x| e("CreateForMonitor", x))?;
        let dxgi: IDXGIDevice = device.cast().map_err(|x| e("IDXGIDevice", x))?;
        let insp: IInspectable = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }.map_err(|x| e("WinRT device", x))?;
        let d3d: IDirect3DDevice = insp.cast().map_err(|x| e("IDirect3DDevice", x))?;
        let size = item.Size().map_err(|x| e("size", x))?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size)
            .map_err(|x| e("frame pool", x))?;
        let s = signal.clone();
        pool.FrameArrived(&TypedEventHandler::<Direct3D11CaptureFramePool, IInspectable>::new(move |_, _| {
            s.notify();
            Ok(())
        }))
        .map_err(|x| e("FrameArrived", x))?;
        let session = pool.CreateCaptureSession(&item).map_err(|x| e("session", x))?;
        // the phone draws the pointer itself (Windows 10 2004+)
        let _ = session.SetIsCursorCaptureEnabled(false);
        // no yellow frame around the screen where the OS lets us (Windows 11; unpackaged apps are granted without a prompt)
        if let Ok(op) = GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Borderless) {
            let _ = op.join();
        }
        let _ = session.SetIsBorderRequired(false);
        // which parts changed (Windows 11 24H2+)
        let dirty_regions = session.SetDirtyRegionMode(GraphicsCaptureDirtyRegionMode::ReportOnly).is_ok();
        session.StartCapture().map_err(|x| e("StartCapture", x))?;
        Ok(Wgc { pool, session, device: d3d, size, dirty_regions })
    }

    fn next(&mut self, timeout: Duration, signal: &Signal) -> Option<Frame> {
        let mut frame = self.pool.TryGetNextFrame().ok();
        if frame.is_none() {
            signal.wait(timeout);
            frame = self.pool.TryGetNextFrame().ok();
        }
        let mut frame = frame?;
        // only the newest: older ones are worth nothing now
        while let Ok(newer) = self.pool.TryGetNextFrame() {
            let _ = frame.Close();
            frame = newer;
        }
        let size = frame.ContentSize().ok()?;
        if size.Width != self.size.Width || size.Height != self.size.Height {
            // the monitor changed resolution: the next frames come at the new size
            self.size = size;
            let _ = self.pool.Recreate(&self.device, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
            let _ = frame.Close();
            return None;
        }
        let surface = frame.Surface().ok()?;
        let access: IDirect3DDxgiInterfaceAccess = surface.cast().ok()?;
        let texture: ID3D11Texture2D = unsafe { access.GetInterface() }.ok()?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut desc) };
        let time = frame.SystemRelativeTime().map(|t| t.Duration as f64 / 1e7).unwrap_or_else(|_| super::monitors::now());
        let dirty = if self.dirty_regions {
            frame.DirtyRegions().ok().and_then(|v| {
                let n = v.Size().ok()?;
                let rects: Vec<Rect> = (0..n)
                    .filter_map(|i| v.GetAt(i).ok())
                    .map(|r| Rect { left: r.X, top: r.Y, right: r.X + r.Width, bottom: r.Y + r.Height })
                    .collect();
                // an empty list says nothing for sure: compare instead
                (!rects.is_empty()).then_some(rects)
            })
        } else {
            None
        };
        Some(Frame { texture, width: desc.Width, height: desc.Height, dirty, time, _wgc: Some(frame) })
    }
}

impl Drop for Wgc {
    fn drop(&mut self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

// MARK: DXGI Desktop Duplication

pub struct Dup {
    device: ID3D11Device,
    output: IDXGIOutput1,
    dup: Option<IDXGIOutputDuplication>,
    holding: bool,
}

impl Dup {
    fn new(device: &ID3D11Device, output: &IDXGIOutput1) -> Result<Dup, String> {
        let dup = unsafe { output.DuplicateOutput(device) }.map_err(|e| e.to_string())?;
        Ok(Dup { device: device.clone(), output: output.clone(), dup: Some(dup), holding: false })
    }

    fn release(&mut self) {
        if self.holding {
            if let Some(d) = &self.dup {
                let _ = unsafe { d.ReleaseFrame() };
            }
            self.holding = false;
        }
    }

    fn next(&mut self, timeout: Duration, signal: &Signal) -> Option<Frame> {
        // a command waiting goes first
        if signal.wait(Duration::ZERO) {
            signal.notify();
            return None;
        }
        self.release();
        if self.dup.is_none() {
            // lost (a mode change, the secure desktop): try again now and then
            self.dup = unsafe { self.output.DuplicateOutput(&self.device) }.ok();
            if self.dup.is_none() {
                signal.wait(timeout.max(Duration::from_millis(50)));
                return None;
            }
        }
        let dup = self.dup.clone()?;
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut res: Option<IDXGIResource> = None;
        // in short waits, so a command (a crop) isn't held up behind a still screen
        let wait = timeout.min(Duration::from_millis(8)).as_millis() as u32;
        match unsafe { dup.AcquireNextFrame(wait, &mut info, &mut res) } {
            Ok(()) => self.holding = true,
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return None,
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                self.dup = None;
                return None;
            }
            Err(_) => return None,
        }
        // only the pointer moved: nothing for us (it isn't in the picture)
        if info.LastPresentTime == 0 || info.AccumulatedFrames == 0 {
            return None;
        }
        let texture: ID3D11Texture2D = res?.cast().ok()?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut desc) };
        let dirty = Self::rects(&dup, info.TotalMetadataBufferSize);
        Some(Frame {
            texture,
            width: desc.Width,
            height: desc.Height,
            dirty,
            time: super::monitors::qpc_seconds(info.LastPresentTime),
            _wgc: None,
        })
    }

    fn rects(dup: &IDXGIOutputDuplication, size: u32) -> Option<Vec<Rect>> {
        if size == 0 {
            return Some(Vec::new());
        }
        let mut out = Vec::new();
        unsafe {
            let mut moves = vec![DXGI_OUTDUPL_MOVE_RECT::default(); size as usize / std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>() + 1];
            let mut got = 0u32;
            dup.GetFrameMoveRects((moves.len() * std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>()) as u32, moves.as_mut_ptr(), &mut got)
                .ok()?;
            for m in &moves[..got as usize / std::mem::size_of::<DXGI_OUTDUPL_MOVE_RECT>()] {
                let r = m.DestinationRect;
                out.push(Rect { left: r.left, top: r.top, right: r.right, bottom: r.bottom });
            }
            let mut rects = vec![RECT::default(); size as usize / std::mem::size_of::<RECT>() + 1];
            dup.GetFrameDirtyRects((rects.len() * std::mem::size_of::<RECT>()) as u32, rects.as_mut_ptr(), &mut got).ok()?;
            for r in &rects[..got as usize / std::mem::size_of::<RECT>()] {
                out.push(Rect { left: r.left, top: r.top, right: r.right, bottom: r.bottom });
            }
        }
        Some(out)
    }
}

impl Drop for Dup {
    fn drop(&mut self) {
        self.release();
    }
}

// MARK: synthetic

/// Rows of text-like marks scrolling up a white page at a fixed rate: what the Mac's test window shows, without a desktop.
pub struct Synthetic {
    context: ID3D11DeviceContext,
    texture: ID3D11Texture2D,
    width: u32,
    height: u32,
    page: Vec<u8>,
    page_rows: u32,
    n: u32,
    fps: u32,
    last: Option<std::time::Instant>,
}

impl Synthetic {
    pub fn new(device: &ID3D11Device, width: u32, height: u32, fps: u32) -> Result<Synthetic, String> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            ..Default::default()
        };
        let mut t = None;
        unsafe { device.CreateTexture2D(&desc, None, Some(&mut t)) }.map_err(|e| e.to_string())?;
        let context = unsafe { device.GetImmediateContext() }.map_err(|e| e.to_string())?;
        // a page twice as tall as the screen: "words" of dark marks in 18-px lines, as small text is
        let page_rows = height * 2;
        let mut page = vec![255u8; (width * page_rows * 4) as usize];
        let mut seed = 0x2545_F491u32;
        let mut rnd = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        for line in 0..page_rows / 18 {
            let y0 = line * 18 + 4;
            let mut x = 8 + rnd() % 40;
            let end = width.saturating_sub(8 + rnd() % (width / 3).max(1));
            while x + 12 < end {
                let word = 3 + rnd() % 8;
                for _ in 0..word {
                    let gw = 6 + rnd() % 3;
                    for gy in 0..11 {
                        for gx in 0..gw {
                            if rnd() % 3 != 0 {
                                let i = (((y0 + gy) * width + x + gx) * 4) as usize;
                                if i + 3 < page.len() {
                                    page[i..i + 3].copy_from_slice(&[30, 30, 30]);
                                }
                            }
                        }
                    }
                    x += gw + 1;
                }
                x += 6;
            }
        }
        Ok(Synthetic { context, texture: t.ok_or("no texture")?, width, height, page, page_rows, n: 0, fps: fps.max(1), last: None })
    }

    fn next(&mut self, timeout: Duration, signal: &Signal) -> Option<Frame> {
        let gap = Duration::from_secs_f64(1.0 / self.fps as f64);
        if let Some(l) = self.last {
            let left = gap.saturating_sub(l.elapsed());
            if !left.is_zero() {
                signal.wait(left.min(timeout));
                if l.elapsed() < gap {
                    return None;
                }
            }
        }
        self.last = Some(std::time::Instant::now());
        self.n += 1;
        // 3 px a frame, as the Mac's test window scrolls
        let offset = (self.n * 3) % (self.page_rows - self.height);
        let start = (offset * self.width * 4) as usize;
        unsafe {
            self.context.UpdateSubresource(&self.texture, 0, None, self.page[start..].as_ptr() as *const _, self.width * 4, 0);
        }
        Some(Frame {
            texture: self.texture.clone(),
            width: self.width,
            height: self.height,
            dirty: None,
            time: super::monitors::now(),
            _wgc: None,
        })
    }
}
