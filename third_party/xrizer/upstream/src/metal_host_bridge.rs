//! Fail-closed, synchronous host bridge; not yet connected to the compositor.
use std::{ffi::c_void, mem::size_of, ptr, sync::{Mutex, OnceLock}};

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Texture {
    pub(crate) texture: *mut c_void,
    pub(crate) device: *mut c_void,
    pub(crate) lease: *mut c_void,
    pub(crate) format: i64,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) sample_count: u32,
}

#[repr(C)]
pub struct CopyRequest {
    pub(crate) source: *const Texture,
    pub(crate) destination: *mut c_void,
    pub(crate) eye: u32,
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) color_space: u32,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Host {
    pub(crate) abi_version: u32,
    pub(crate) struct_size: u32,
    pub(crate) context: *mut c_void,
    pub(crate) device: *mut c_void,
    pub(crate) command_queue: *mut c_void,
    pub(crate) acquire: Option<unsafe extern "C" fn(*mut c_void, *mut c_void, *mut Texture) -> i32>,
    pub(crate) copy_complete: Option<unsafe extern "C" fn(*mut c_void, *const CopyRequest) -> i32>,
    pub(crate) release: Option<unsafe extern "C" fn(*mut c_void, *mut c_void)>,
}

// The callback context must outlive the process. The mutex serializes host
// access, as required by the C contract; callbacks may not re-enter xrizer.
unsafe impl Send for Host {}
static HOST: OnceLock<Mutex<Host>> = OnceLock::new();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn xrizer_configure_metal_host(host: *const Host) -> i32 {
    if host.is_null() { return -1; }
    // Only the fixed two-word ABI header may be read before checking size.
    // Older callers need not have allocated the remainder of Host.
    let header = host.cast::<u32>();
    let version = unsafe { header.read_unaligned() };
    let struct_size = unsafe { header.add(1).read_unaligned() };
    if version != 1 || (struct_size as usize) < size_of::<Host>() { return -1; }
    let value = unsafe { *host };
    if unsafe { Bridge::new(&value) }.is_err() { return -1; }
    if HOST.set(Mutex::new(value)).is_err() { return -1; }
    0
}

pub fn with_host<T>(f: impl FnOnce(&Host) -> T) -> Option<T> {
    let host = HOST.get()?.lock().ok()?;
    Some(f(&host))
}

#[derive(Copy, Clone, Debug)]
pub struct TextureInfo { pub format: i64, pub width: u32, pub height: u32 }

// Bounds arrive as f32. Accept integer pixel edges within their input rounding
// error, but reject fractional edges; do not silently crop a different pixel.
pub(crate) fn pixel_coordinate(v: f32, size: u32) -> Option<u32> {
    if !v.is_finite() || !(0.0..=1.0).contains(&v) { return None; }
    let value = v as f64 * size as f64;
    let rounded = value.round();
    let tolerance = (size as f64 * f32::EPSILON as f64).clamp(1e-6, 0.25);
    ((value - rounded).abs() <= tolerance && rounded <= u32::MAX as f64).then_some(rounded as u32)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error { InvalidHost, InvalidTexture, Unsupported, InvalidBounds, CopyFailed }

pub struct Bridge<'a> { host: &'a Host }
struct Lease<'a> { host: &'a Host, texture: Texture }
impl Drop for Lease<'_> {
    fn drop(&mut self) {
        // Successful acquire promises a non-null lease and a valid release callback.
        unsafe { (self.host.release.unwrap())(self.host.context, self.texture.lease) }
    }
}

impl<'a> Bridge<'a> {
    /// The host and callbacks must remain valid for 'a, including any active GPU work.
    pub unsafe fn new(host: &'a Host) -> Result<Self, Error> {
        if host.abi_version != 1 || (host.struct_size as usize) < size_of::<Host>() ||
            host.device.is_null() || host.command_queue.is_null() || host.acquire.is_none() ||
            host.copy_complete.is_none() || host.release.is_none() {
            return Err(Error::InvalidHost);
        }
        Ok(Self { host })
    }

    fn acquire(&self, handle: *mut c_void) -> Result<Lease<'_>, Error> {
        if handle.is_null() { return Err(Error::InvalidTexture); }
        let mut texture = Texture { texture: ptr::null_mut(), device: ptr::null_mut(), lease: ptr::null_mut(), format: 0, width: 0, height: 0, sample_count: 0 };
        let status = unsafe { (self.host.acquire.unwrap())(self.host.context, handle, &mut texture) };
        if status != 0 { return Err(Error::InvalidTexture); }
        if texture.lease.is_null() { return Err(Error::InvalidTexture); }
        let lease = Lease { host: self.host, texture };
        if texture.texture.is_null() || texture.device != self.host.device || texture.width == 0 || texture.height == 0 {
            return Err(Error::InvalidTexture);
        }
        if texture.sample_count != 1 { return Err(Error::Unsupported); }
        Ok(lease)
    }

    pub fn queue(&self) -> *mut c_void { self.host.command_queue }

    pub fn describe(&self, handle: *mut c_void) -> Result<TextureInfo, Error> {
        let lease = self.acquire(handle)?;
        Ok(TextureInfo { format: lease.texture.format, width: lease.texture.width, height: lease.texture.height })
    }

    /// Bounds must describe an unflipped integral pixel rectangle. The host
    /// verifies format, destination layer/device, colorspace and GPU completion.
    pub fn copy(&self, handle: *mut c_void, destination: *mut c_void, eye: u32, color_space: u32, bounds: [f32; 4], expected: Option<TextureInfo>) -> Result<(u32, u32), Error> {
        if destination.is_null() || eye > 1 { return Err(Error::InvalidTexture); }
        if color_space > 2 { return Err(Error::Unsupported); }
        let [u0, v0, u1, v1] = bounds;
        if !bounds.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)) || u0 >= u1 || v0 >= v1 {
            return Err(Error::InvalidBounds);
        }
        let lease = self.acquire(handle)?;
        let [x0, y0, x1, y1] = [pixel_coordinate(u0, lease.texture.width), pixel_coordinate(v0, lease.texture.height), pixel_coordinate(u1, lease.texture.width), pixel_coordinate(v1, lease.texture.height)];
        let (x, y, right, bottom) = match (x0, y0, x1, y1) {
            (Some(x), Some(y), Some(right), Some(bottom)) if right > x && bottom > y => (x, y, right, bottom),
            _ => return Err(Error::InvalidBounds),
        };
        if let Some(info) = expected {
            if lease.texture.format != info.format || lease.texture.width != info.width || lease.texture.height != info.height {
                return Err(Error::InvalidTexture);
            }
        }
        let request = CopyRequest { source: &lease.texture, destination, eye, x, y, width: right - x, height: bottom - y, color_space };
        if unsafe { (self.host.copy_complete.unwrap())(self.host.context, &request) } != 0 { return Err(Error::CopyFailed); }
        Ok((request.width, request.height))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[derive(Default)]
    struct State { acquired: u32, released: u32, copied: u32, mode: u32 }
    fn pointer(n: usize) -> *mut c_void { n as *mut c_void }
    unsafe extern "C" fn acquire(context: *mut c_void, handle: *mut c_void, out: *mut Texture) -> i32 {
        let state = unsafe { &mut *(context as *mut State) };
        state.acquired += 1;
        if handle != pointer(10) { return -1; }
        unsafe { *out = Texture { texture: if state.mode == 1 { ptr::null_mut() } else { pointer(11) }, device: if state.mode == 2 { pointer(99) } else { pointer(12) }, lease: pointer(13), format: 80, width: 64, height: 32, sample_count: if state.mode == 3 { 4 } else { 1 } }; }
        0
    }
    unsafe extern "C" fn copy(context: *mut c_void, request: *const CopyRequest) -> i32 {
        let state = unsafe { &mut *(context as *mut State) };
        state.copied += 1;
        let request = unsafe { &*request };
        assert_eq!((request.eye, request.x, request.y, request.width, request.height, request.color_space), (1, 16, 0, 32, 32, 1));
        assert_eq!(request.destination, pointer(14));
        assert_eq!(unsafe { (*request.source).texture }, pointer(11));
        if state.mode == 4 { -1 } else { 0 }
    }
    unsafe extern "C" fn release(context: *mut c_void, lease: *mut c_void) {
        assert_eq!(lease, pointer(13));
        unsafe { (*(context as *mut State)).released += 1; }
    }
    fn host(state: &mut State) -> Host {
        Host { abi_version: 1, struct_size: size_of::<Host>() as u32, context: state as *mut _ as *mut _, device: pointer(12), command_queue: pointer(15), acquire: Some(acquire), copy_complete: Some(copy), release: Some(release) }
    }
    #[test]
    fn pixel_edges_tolerate_f32_rounding_without_cropping_fractional_pixels() {
        assert_eq!(pixel_coordinate(0.1, 1000), Some(100));
        assert_eq!(pixel_coordinate(0.25, 64), Some(16));
        assert_eq!(pixel_coordinate(0.01, 64), None);
        assert_eq!(pixel_coordinate(f32::NAN, 64), None);
    }
    #[test]
    fn host_layout_and_configuration() {
        let short_header = [1u32, 8];
        assert_eq!(unsafe { xrizer_configure_metal_host(short_header.as_ptr().cast()) }, -1);
        assert_eq!((size_of::<Texture>(), offset_of!(Texture, format), offset_of!(Texture, width)), (48, 24, 32));
        assert_eq!((size_of::<CopyRequest>(), offset_of!(CopyRequest, eye), size_of::<Host>()), (40, 16, 56));
        let mut state = State::default();
        let mut config = host(&mut state);
        config.acquire = None;
        assert!(matches!(unsafe { Bridge::new(&config) }, Err(Error::InvalidHost)));
        config.acquire = Some(acquire);
        config.struct_size = 1;
        assert!(matches!(unsafe { Bridge::new(&config) }, Err(Error::InvalidHost)));
        config.struct_size = size_of::<Host>() as u32;
        config.abi_version = 2;
        assert!(matches!(unsafe { Bridge::new(&config) }, Err(Error::InvalidHost)));
    }
    #[test]
    fn copy_validates_and_releases_every_acquired_lease() {
        let mut state = State::default();
        let config = host(&mut state);
        let bridge = unsafe { Bridge::new(&config).unwrap() };
        let good = [0.25, 0.0, 0.75, 1.0];
        let call = |h, c, b| bridge.copy(h, pointer(14), 1, c, b, None);
        assert_eq!(bridge.copy(pointer(10), pointer(14), 1, 1, good, Some(TextureInfo { format: 81, width: 64, height: 32 })), Err(Error::InvalidTexture));
        assert_eq!(bridge.copy(pointer(10), pointer(14), 1, 1, good, Some(TextureInfo { format: 80, width: 128, height: 32 })), Err(Error::InvalidTexture));
        assert_eq!(call(ptr::null_mut(), 1, good), Err(Error::InvalidTexture));
        assert_eq!(call(pointer(9), 1, good), Err(Error::InvalidTexture));
        assert_eq!(call(pointer(10), 3, good), Err(Error::Unsupported));
        assert_eq!(call(pointer(10), 1, [f32::NAN, 0.0, 1.0, 1.0]), Err(Error::InvalidBounds));
        assert_eq!(call(pointer(10), 1, [1.0, 0.0, 0.0, 1.0]), Err(Error::InvalidBounds));
        assert_eq!(call(pointer(10), 1, [0.01, 0.0, 1.0, 1.0]), Err(Error::InvalidBounds));
        assert_eq!(call(pointer(10), 1, good), Ok((32, 32)));
        assert_eq!((state.acquired, state.released, state.copied), (5, 4, 1));
        for (mode, expected) in [(1, Error::InvalidTexture), (2, Error::InvalidTexture), (3, Error::Unsupported), (4, Error::CopyFailed)] {
            state.mode = mode;
            assert_eq!(call(pointer(10), 1, good), Err(expected));
        }
        assert_eq!((state.acquired, state.released, state.copied), (9, 8, 2));
    }
}
