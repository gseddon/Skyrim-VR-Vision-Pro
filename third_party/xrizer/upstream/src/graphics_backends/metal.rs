//! Apple Metal backend; used only when the host and real provider are connected.
use super::GraphicsBackend;
use crate::{metal_graphics, metal_host_bridge::{self, Bridge}};
use openvr as vr;
use openxr as xr;
use std::ffi::c_void;

pub struct MetalData {
    queue: usize,
    images: Vec<usize>,
    format: Option<i64>,
}
impl MetalData {
    pub fn new() -> Option<Self> {
        metal_host_bridge::with_host(|host| unsafe { Bridge::new(host) }.ok().map(|b| b.queue() as usize))?
            .map(|queue| Self { queue, images: Vec::new(), format: None })
    }
    fn describe(texture: usize, bounds: vr::VRTextureBounds_t, color: vr::EColorSpace) -> Result<(xr::SwapchainCreateInfo<metal_graphics::Metal>, metal_host_bridge::TextureInfo), ()> {
        metal_host_bridge::with_host(|host| {
            let bridge = unsafe { Bridge::new(host) }.map_err(|_| ())?;
            let info = bridge.describe(texture as *mut c_void).map_err(|_| ())?;
            // No implicit conversion. Gamma and Auto accept an sRGB texture, and
            // also an UNORM texture whose texels are already gamma-encoded
            // (the D3D11 R8G8B8A8_UNORM submission). Those texels are copied
            // as stored. Linear stays UNORM-only.
            let format_ok = match color {
                vr::EColorSpace::Auto | vr::EColorSpace::Gamma => matches!(info.format, 70 | 80 | 71 | 81),
                vr::EColorSpace::Linear => matches!(info.format, 70 | 80),
            };
            if !format_ok { return Err(()); }
            let [u0, v0, u1, v1] = [bounds.uMin, bounds.vMin, bounds.uMax, bounds.vMax];
            if ![u0,v0,u1,v1].iter().all(|x| x.is_finite() && (0.0..=1.0).contains(x)) || u0 >= u1 || v0 >= v1 { return Err(()); }
            let px = metal_host_bridge::pixel_coordinate;
            let (x0,y0,x1,y1) = (px(u0,info.width).ok_or(())?,px(v0,info.height).ok_or(())?,px(u1,info.width).ok_or(())?,px(v1,info.height).ok_or(())?);
            if x1 <= x0 || y1 <= y0 { return Err(()); }
            Ok((xr::SwapchainCreateInfo {
                create_flags: xr::SwapchainCreateFlags::EMPTY,
                usage_flags: xr::SwapchainUsageFlags::COLOR_ATTACHMENT | xr::SwapchainUsageFlags::TRANSFER_DST,
                format: info.format, sample_count: 1, width: x1 - x0, height: y1 - y0,
                face_count: 1, array_size: 2, mip_count: 1,
            }, info))
        }).ok_or(())?
    }
}
impl GraphicsBackend for MetalData {
    type Api = metal_graphics::Metal;
    type OpenVrTexture = usize;
    type NiceFormat = i64;
    fn to_nice_format(format: i64) -> i64 { format }
    fn session_create_info(&self) -> metal_graphics::SessionCreateInfo {
        metal_graphics::SessionCreateInfo { command_queue: self.queue as *mut c_void }
    }
    fn get_texture(texture: &vr::Texture_t) -> Option<usize> {
        (texture.eType == vr::ETextureType::DirectX && !texture.handle.is_null()).then_some(texture.handle as usize)
    }
    fn swapchain_info_for_texture(&self, _: usize, _: vr::VRTextureBounds_t, _: vr::EColorSpace) -> xr::SwapchainCreateInfo<Self::Api> {
        unreachable!("Metal requires the fallible backend path")
    }
    fn try_swapchain_info_for_texture(&self, texture: usize, bounds: vr::VRTextureBounds_t, color: vr::EColorSpace) -> Result<xr::SwapchainCreateInfo<Self::Api>, ()> {
        Self::describe(texture, bounds, color).map(|(info, _)| info)
    }
    fn store_swapchain_images(&mut self, images: Vec<*mut c_void>, format: i64) {
        self.images = images.into_iter().map(|image| image as usize).collect(); self.format = Some(format);
    }
    fn copy_texture_to_swapchain(&self, _: vr::EVREye, _: usize, _: vr::EColorSpace, _: vr::VRTextureBounds_t, _: usize, _: vr::EVRSubmitFlags) -> xr::Extent2Di {
        unreachable!("Metal requires the fallible backend path")
    }
    fn try_copy_texture_to_swapchain(&self, eye: vr::EVREye, texture: usize, color: vr::EColorSpace, bounds: vr::VRTextureBounds_t, image_index: usize, flags: vr::EVRSubmitFlags) -> Result<xr::Extent2Di, ()> {
        if flags.0 != 0 { return Err(()); }
        let (info, source_info) = Self::describe(texture, bounds, color)?;
        if self.format != Some(info.format) { return Err(()); }
        let dst = *self.images.get(image_index).ok_or(())? as *mut c_void;
        let (width, height) = metal_host_bridge::with_host(|host| {
            unsafe { Bridge::new(host) }.map_err(|_| ())?.copy(texture as *mut c_void, dst, eye as u32, color as u32, [bounds.uMin,bounds.vMin,bounds.uMax,bounds.vMax], Some(source_info)).map_err(|_| ())
        }).ok_or(())??;
        if width > i32::MAX as u32 || height > i32::MAX as u32 { return Err(()); }
        Ok(xr::Extent2Di { width: width as i32, height: height as i32 })
    }
    fn copy_overlay_to_swapchain(&mut self, _: usize, _: vr::VRTextureBounds_t, _: usize) -> xr::Extent2Di {
        unreachable!("Metal overlay submissions are rejected")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metal_host_bridge::{Host, Texture, CopyRequest, xrizer_configure_metal_host};
    use std::{mem::size_of, ptr};
    #[derive(Default)] struct State { releases: u32, copies: u32, fail: bool }
    fn p(n: usize) -> *mut c_void { n as *mut c_void }
    unsafe extern "C" fn acquire(ctx: *mut c_void, h: *mut c_void, out: *mut Texture) -> i32 {
        if h != p(10) { return -1; }
        let _ = ctx;
        unsafe { *out = Texture { texture: p(11), device: p(12), lease: p(13), format: 80, width: 64, height: 32, sample_count: 1 }; }
        0
    }
    unsafe extern "C" fn copy(ctx: *mut c_void, r: *const CopyRequest) -> i32 {
        let state = unsafe { &mut *(ctx as *mut State) };
        let req = unsafe { &*r };
        assert_eq!((req.eye, req.x, req.y, req.width, req.height), (1, 16, 0, 32, 32));
        assert_eq!(req.destination, p(14));
        state.copies += 1;
        if state.fail { -1 } else { 0 }
    }
    unsafe extern "C" fn release(ctx: *mut c_void, lease: *mut c_void) {
        assert_eq!(lease, p(13)); unsafe { (*(ctx as *mut State)).releases += 1; }
    }
    #[test]
    fn resolves_and_copies_directx_with_failures() {
        assert!(MetalData::new().is_none());
        let state = Box::leak(Box::new(State::default()));
        let host = Host { abi_version: 1, struct_size: size_of::<Host>() as u32,
            context: state as *mut _ as *mut _, device: p(12), command_queue: p(15),
            acquire: Some(acquire), copy_complete: Some(copy), release: Some(release) };
        assert_eq!(unsafe { xrizer_configure_metal_host(&host) }, 0);
        assert_eq!(unsafe { xrizer_configure_metal_host(&host) }, -1);
        let mut backend = MetalData::new().unwrap();
        let bounds = vr::VRTextureBounds_t { uMin: 0.25, vMin: 0., uMax: 0.75, vMax: 1. };
        let info = backend.try_swapchain_info_for_texture(10, bounds, vr::EColorSpace::Linear).unwrap();
        assert_eq!((info.width, info.height, info.array_size, info.format), (32, 32, 2, 80));
        let gamma = backend.try_swapchain_info_for_texture(10, bounds, vr::EColorSpace::Gamma).unwrap();
        assert_eq!((gamma.width, gamma.height, gamma.format), (32, 32, 80));
        let auto = backend.try_swapchain_info_for_texture(10, bounds, vr::EColorSpace::Auto).unwrap();
        assert_eq!(auto.format, 80);
        assert!(backend.try_swapchain_info_for_texture(9, bounds, vr::EColorSpace::Linear).is_err());
        backend.store_swapchain_images(vec![p(14)], 80);
        let result = backend.try_copy_texture_to_swapchain(vr::EVREye::Right, 10, vr::EColorSpace::Linear, bounds, 0, vr::EVRSubmitFlags(0)).unwrap();
        assert_eq!((result.width, result.height), (32,32));
        assert!(backend.try_copy_texture_to_swapchain(vr::EVREye::Right, 10, vr::EColorSpace::Linear, bounds, 1, vr::EVRSubmitFlags(0)).is_err());
        state.fail = true;
        assert!(backend.try_copy_texture_to_swapchain(vr::EVREye::Right, 10, vr::EColorSpace::Linear, bounds, 0, vr::EVRSubmitFlags(0)).is_err());
        assert_eq!(state.copies, 2);
        assert!(state.releases >= 4);
        assert!(MetalData::get_texture(&vr::Texture_t { handle: ptr::null_mut(), eType: vr::ETextureType::DirectX, eColorSpace: vr::EColorSpace::Linear }).is_none());
    }
}
