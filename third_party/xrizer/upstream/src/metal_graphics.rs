//! OpenXR Metal graphics binding. The provider owns the device, queue and images;
//! this module neither retains them nor makes GPU work complete.
use std::{ffi::c_void, ptr};
use openxr::{self as xr, sys};
use sys::Handle as _;

pub enum Metal {}

#[derive(Copy, Clone)]
pub struct SessionCreateInfo {
    pub command_queue: *mut c_void,
}
// The native host retains the queue for process lifetime and serializes access.
unsafe impl Send for SessionCreateInfo {}
unsafe impl Sync for SessionCreateInfo {}

fn result(value: sys::Result) -> xr::Result<()> {
    if value.into_raw() < 0 { Err(value) } else { Ok(()) }
}

unsafe fn requirements_raw(
    fp: sys::pfn::GetMetalGraphicsRequirementsKHR,
    instance: sys::Instance,
    system: sys::SystemId,
) -> xr::Result<*mut c_void> {
    let mut out = sys::GraphicsRequirementsMetalKHR::out(ptr::null_mut());
    result(unsafe { fp(instance, system, out.as_mut_ptr()) })?;
    Ok(unsafe { out.assume_init() }.metal_device)
}

unsafe fn create_session_raw(
    fp: sys::pfn::CreateSession,
    instance: sys::Instance,
    system: sys::SystemId,
    queue: *mut c_void,
) -> xr::Result<sys::Session> {
    let binding = sys::GraphicsBindingMetalKHR {
        ty: sys::GraphicsBindingMetalKHR::TYPE, next: ptr::null(), command_queue: queue,
    };
    let info = sys::SessionCreateInfo {
        ty: sys::SessionCreateInfo::TYPE, next: &binding as *const _ as *const _,
        create_flags: Default::default(), system_id: system,
    };
    let mut session = sys::Session::NULL;
    result(unsafe { fp(instance, &info, &mut session) })?;
    Ok(session)
}

unsafe fn enumerate_raw(
    fp: sys::pfn::EnumerateSwapchainImages,
    swapchain: sys::Swapchain,
) -> xr::Result<Vec<*mut c_void>> {
    let mut count = 0;
    result(unsafe { fp(swapchain, 0, &mut count, ptr::null_mut()) })?;
    let mut images = vec![sys::SwapchainImageMetalKHR {
        ty: sys::SwapchainImageMetalKHR::TYPE, next: ptr::null_mut(), texture: ptr::null_mut(),
    }; count as usize];
    if count != 0 {
        let capacity = count;
        result(unsafe { fp(swapchain, capacity, &mut count, images.as_mut_ptr() as *mut _) })?;
        if count > capacity { return Err(sys::Result::ERROR_SIZE_INSUFFICIENT); }
        images.truncate(count as usize);
    }
    Ok(images.into_iter().map(|image| image.texture).collect())
}

impl xr::Graphics for Metal {
    type Requirements = *mut c_void;
    type SessionCreateInfo = SessionCreateInfo;
    type Format = i64;
    type SwapchainImage = *mut c_void;

    fn raise_format(x: i64) -> i64 { x }
    fn lower_format(x: i64) -> i64 { x }
    fn requirements(instance: &xr::Instance, system: xr::SystemId) -> xr::Result<Self::Requirements> {
        let ext = instance.exts().khr_metal_enable.as_ref().ok_or(sys::Result::ERROR_FUNCTION_UNSUPPORTED)?;
        unsafe { requirements_raw(ext.get_metal_graphics_requirements, instance.as_raw(), system) }
    }
    unsafe fn create_session(instance: &xr::Instance, system: xr::SystemId, info: &SessionCreateInfo) -> xr::Result<sys::Session> {
        unsafe { create_session_raw(instance.fp().create_session, instance.as_raw(), system, info.command_queue) }
    }
    fn enumerate_swapchain_images(swapchain: &xr::Swapchain<Self>) -> xr::Result<Vec<Self::SwapchainImage>> {
        unsafe { enumerate_raw(swapchain.instance().fp().enumerate_swapchain_images, swapchain.as_raw()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openxr::Graphics;

    unsafe extern "system" fn requirements(_: sys::Instance, _: sys::SystemId, out: *mut sys::GraphicsRequirementsMetalKHR) -> sys::Result {
        unsafe {
            assert_eq!((*out).ty, sys::GraphicsRequirementsMetalKHR::TYPE);
            assert!((*out).next.is_null());
            (*out).metal_device = 0x1234usize as *mut c_void;
        }
        sys::Result::SUCCESS
    }
    unsafe extern "system" fn session(_: sys::Instance, info: *const sys::SessionCreateInfo, out: *mut sys::Session) -> sys::Result {
        unsafe {
            assert_eq!((*info).ty, sys::SessionCreateInfo::TYPE);
            let binding = &*((*info).next as *const sys::GraphicsBindingMetalKHR);
            assert_eq!(binding.ty, sys::GraphicsBindingMetalKHR::TYPE);
            assert!(binding.next.is_null());
            assert_eq!(binding.command_queue as usize, 0x5678);
            *out = sys::Session::from_raw(9);
        }
        sys::Result::SUCCESS
    }
    unsafe extern "system" fn images(_: sys::Swapchain, capacity: u32, count: *mut u32, out: *mut sys::SwapchainImageBaseHeader) -> sys::Result {
        unsafe {
            *count = 2;
            if capacity > 0 {
                assert_eq!(capacity, 2);
                let images = std::slice::from_raw_parts_mut(out as *mut sys::SwapchainImageMetalKHR, 2);
                for (i, image) in images.iter_mut().enumerate() {
                    assert_eq!(image.ty, sys::SwapchainImageMetalKHR::TYPE);
                    assert!(image.next.is_null());
                    image.texture = (0x1000 + i) as *mut c_void;
                }
            }
        }
        sys::Result::SUCCESS
    }
    unsafe extern "system" fn fail(_: sys::Swapchain, _: u32, _: *mut u32, _: *mut sys::SwapchainImageBaseHeader) -> sys::Result {
        sys::Result::ERROR_RUNTIME_FAILURE
    }
    #[test]
    fn dispatches_binding_and_images_and_propagates_errors() {
        unsafe {
            assert_eq!(requirements_raw(requirements, sys::Instance::NULL, sys::SystemId::NULL).unwrap() as usize, 0x1234);
            assert_eq!(create_session_raw(session, sys::Instance::NULL, sys::SystemId::NULL, 0x5678usize as *mut c_void).unwrap().into_raw(), 9);
            assert_eq!(enumerate_raw(images, sys::Swapchain::NULL).unwrap().iter().map(|p| *p as usize).collect::<Vec<_>>(), vec![0x1000, 0x1001]);
            assert_eq!(enumerate_raw(fail, sys::Swapchain::NULL), Err(sys::Result::ERROR_RUNTIME_FAILURE));
            assert_eq!(Metal::lower_format(Metal::raise_format(115)), 115);
        }
    }
}
