//! The D3D11 video processor: the crop of the held picture (BGRA, the whole monitor) scaled to the output size and turned into NV12
//! (BT.709, limited range, as the encoder's VUI says), all on the GPU. The output size never changes while the crop does, so a
//! crop change is only a different source rectangle on the next blit: nothing to restart.
//!
//! The held picture is our own copy of the last captured frame, so the capture's buffer goes back at once, and a crop change,
//! a refresh or a keyframe can be made from it while the screen stands still.

use ::windows::core::Interface;
use ::windows::Win32::Foundation::RECT;
use ::windows::Win32::Graphics::Direct3D11::*;
use ::windows::Win32::Graphics::Dxgi::Common::{
    DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709, DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM,
    DXGI_FORMAT_NV12, DXGI_RATIONAL, DXGI_SAMPLE_DESC,
};

use super::geometry::Rect;

/// Outputs in flight: an encoder may still read one while the next is drawn.
const RING: usize = 4;

pub struct Converter {
    context: ID3D11DeviceContext,
    vctx: ID3D11VideoContext,
    vp: ID3D11VideoProcessor,
    held: ID3D11Texture2D,
    input: ID3D11VideoProcessorInputView,
    outputs: Vec<(ID3D11Texture2D, ID3D11VideoProcessorOutputView)>,
    next: usize,
    staging: Option<ID3D11Texture2D>,
    pub in_w: u32,
    pub in_h: u32,
    pub out_w: u32,
    pub out_h: u32,
}

fn tex(device: &ID3D11Device, w: u32, h: u32, format: DXGI_FORMAT, bind: u32, usage: D3D11_USAGE, cpu: u32) -> ::windows::core::Result<ID3D11Texture2D> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: usage,
        BindFlags: bind,
        CPUAccessFlags: cpu,
        MiscFlags: 0,
    };
    let mut t = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut t)) }?;
    t.ok_or_else(|| ::windows::core::Error::from(::windows::Win32::Foundation::E_FAIL))
}

impl Converter {
    pub fn new(device: &ID3D11Device, in_w: u32, in_h: u32, out_w: u32, out_h: u32, fps: u32) -> Result<Converter, String> {
        let e = |what: &str, err: ::windows::core::Error| format!("video processor ({what}): {err}");
        let vdev: ID3D11VideoDevice = device.cast().map_err(|x| e("video device", x))?;
        let context = unsafe { device.GetImmediateContext() }.map_err(|x| e("context", x))?;
        let vctx: ID3D11VideoContext = context.cast().map_err(|x| e("video context", x))?;
        let rate = DXGI_RATIONAL { Numerator: fps.max(1), Denominator: 1 };
        let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
            InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            InputFrameRate: rate,
            InputWidth: in_w,
            InputHeight: in_h,
            OutputFrameRate: rate,
            OutputWidth: out_w,
            OutputHeight: out_h,
            // text: the better scaler, where the driver has a choice
            Usage: D3D11_VIDEO_USAGE_OPTIMAL_QUALITY,
        };
        let en = unsafe { vdev.CreateVideoProcessorEnumerator(&content) }.map_err(|x| e("enumerator", x))?;
        let vp = unsafe { vdev.CreateVideoProcessor(&en, 0) }.map_err(|x| e("processor", x))?;

        let held = tex(
            device,
            in_w,
            in_h,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
            D3D11_USAGE_DEFAULT,
            0,
        )
        .map_err(|x| e("held picture", x))?;
        let in_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
            FourCC: 0,
            ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 } },
        };
        let mut input = None;
        unsafe { vdev.CreateVideoProcessorInputView(&held, &en, &in_desc, Some(&mut input)) }.map_err(|x| e("input view", x))?;
        let input = input.ok_or("video processor: no input view")?;

        let out_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
            ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
            Anonymous: D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 { Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 } },
        };
        let mut outputs = Vec::with_capacity(RING);
        for _ in 0..RING {
            // the encoder's own bind flag where the driver takes it (NVENC reads it without a copy)
            let t = tex(
                device,
                out_w,
                out_h,
                DXGI_FORMAT_NV12,
                (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_VIDEO_ENCODER.0) as u32,
                D3D11_USAGE_DEFAULT,
                0,
            )
            .or_else(|_| tex(device, out_w, out_h, DXGI_FORMAT_NV12, D3D11_BIND_RENDER_TARGET.0 as u32, D3D11_USAGE_DEFAULT, 0))
            .map_err(|x| e("NV12 output", x))?;
            let mut view = None;
            unsafe { vdev.CreateVideoProcessorOutputView(&t, &en, &out_desc, Some(&mut view)) }.map_err(|x| e("output view", x))?;
            outputs.push((t, view.ok_or("video processor: no output view")?));
        }

        unsafe {
            vctx.VideoProcessorSetStreamFrameFormat(&vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            // no denoise, no edge enhancement, no "auto" anything: the screen as it is
            vctx.VideoProcessorSetStreamAutoProcessingMode(&vp, 0, false);
            let full = RECT { left: 0, top: 0, right: out_w as i32, bottom: out_h as i32 };
            vctx.VideoProcessorSetStreamDestRect(&vp, 0, true, Some(&full));
            vctx.VideoProcessorSetOutputTargetRect(&vp, true, Some(&full));
            if let Ok(v1) = vctx.cast::<ID3D11VideoContext1>() {
                v1.VideoProcessorSetStreamColorSpace1(&vp, 0, DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
                v1.VideoProcessorSetOutputColorSpace1(&vp, DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709);
            } else {
                // Usage 0, RGB_Range 0 (full), YCbCr_Matrix 1 (BT.709), Nominal_Range 1 (16–235)
                let input_cs = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: 0 };
                let output_cs = D3D11_VIDEO_PROCESSOR_COLOR_SPACE { _bitfield: (1 << 2) | (1 << 4) };
                vctx.VideoProcessorSetStreamColorSpace(&vp, 0, &input_cs);
                vctx.VideoProcessorSetOutputColorSpace(&vp, &output_cs);
            }
        }
        Ok(Converter { context, vctx, vp, held, input, outputs, next: 0, staging: None, in_w, in_h, out_w, out_h })
    }

    /// Keep this picture (the capture's texture goes back to the OS right after).
    pub fn hold(&self, texture: &ID3D11Texture2D) {
        unsafe { self.context.CopyResource(&self.held, texture) };
    }

    /// The held picture's `crop` (source pixels) at the output size, as NV12: the next texture of the ring.
    pub fn render(&mut self, crop: &Rect) -> Result<ID3D11Texture2D, String> {
        let (tex, view) = &self.outputs[self.next];
        self.next = (self.next + 1) % self.outputs.len();
        let src = RECT { left: crop.left, top: crop.top, right: crop.right, bottom: crop.bottom };
        unsafe {
            self.vctx.VideoProcessorSetStreamSourceRect(&self.vp, 0, true, Some(&src));
            let stream = D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: true.into(),
                pInputSurface: std::mem::ManuallyDrop::new(Some(self.input.clone())),
                ..Default::default()
            };
            let streams = [stream];
            let r = self.vctx.VideoProcessorBlt(&self.vp, view, 0, &streams);
            // the view's reference in the stream struct
            let [mut s] = streams;
            std::mem::ManuallyDrop::drop(&mut s.pInputSurface);
            r.map_err(|e| format!("video processor blt: {e}"))?;
        }
        Ok(tex.clone())
    }

    /// An NV12 output read back to memory, rows packed (`out_w` bytes a row of Y, then the interleaved UV rows): for comparing with
    /// the last frame sent, and for the software encoder.
    pub fn read(&mut self, nv12: &ID3D11Texture2D, out: &mut Vec<u8>) -> Result<(), String> {
        if self.staging.is_none() {
            let device = unsafe { self.context.GetDevice() }.map_err(|e| e.to_string())?;
            self.staging = Some(
                tex(&device, self.out_w, self.out_h, DXGI_FORMAT_NV12, 0, D3D11_USAGE_STAGING, D3D11_CPU_ACCESS_READ.0 as u32)
                    .map_err(|e| format!("staging: {e}"))?,
            );
        }
        let staging = self.staging.as_ref().unwrap();
        let (w, h) = (self.out_w as usize, self.out_h as usize);
        out.resize(w * h * 3 / 2, 0);
        unsafe {
            self.context.CopyResource(staging, nv12);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(|e| format!("map: {e}"))?;
            let pitch = m.RowPitch as usize;
            let base = m.pData as *const u8;
            for row in 0..h + h / 2 {
                // NV12 in a staging texture: the UV plane right after the Y plane's rows, at the same pitch
                let src = std::slice::from_raw_parts(base.add(row * pitch), w);
                out[row * w..row * w + w].copy_from_slice(src);
            }
            self.context.Unmap(staging, 0);
        }
        Ok(())
    }
}
