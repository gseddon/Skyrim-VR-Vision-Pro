//! Explicit native provider entry registration; it does not enable Init.
use openxr::{self as xr, sys};
use std::sync::OnceLock;
static PROVIDER: OnceLock<sys::pfn::GetInstanceProcAddr> = OnceLock::new();

/// The native function and its host context must remain live for process life.
/// Configuring an entry is not proof of a usable session, graphics, or input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xrizer_configure_openxr_provider(fp: Option<sys::pfn::GetInstanceProcAddr>) -> i32 {
    let Some(fp) = fp else { return -1; };
    if unsafe { xr::Entry::from_get_instance_proc_addr(fp) }.is_err() { return -1; }
    if PROVIDER.set(fp).is_err() { return -1; }
    0
}

pub fn entry() -> xr::Result<xr::Entry> {
    let fp = *PROVIDER.get().ok_or(sys::Result::ERROR_RUNTIME_UNAVAILABLE)?;
    unsafe { xr::Entry::from_get_instance_proc_addr(fp) }
}

// Local provider private native query, not a standard OpenXR extension. It
// describes only optical eye geometry; it is not a tracked pose or frame.
#[repr(C)]
#[derive(Copy, Clone)]
struct StaticViewGeometry {
    version: u32,
    struct_size: u32,
    geometry_id: u64,
    head_from_eye: [xr::Posef; 2],
    fov: [xr::Fovf; 2],
}
pub fn static_views(instance: &xr::Instance, system: xr::SystemId) -> xr::Result<[xr::View; 2]> {
    type Get = unsafe extern "system" fn(sys::Instance, sys::SystemId, *mut StaticViewGeometry) -> sys::Result;
    let mut raw = None;
    let result = unsafe { (instance.entry().fp().get_instance_proc_addr)(instance.as_raw(), c"xrGetVxStaticViewGeometry".as_ptr(), &mut raw) };
    if result != sys::Result::SUCCESS { return Err(result); }
    let Some(raw) = raw else { return Err(sys::Result::ERROR_FUNCTION_UNSUPPORTED); };
    let get: Get = unsafe { std::mem::transmute(raw) };
    let mut geometry = StaticViewGeometry { version: 1, struct_size: std::mem::size_of::<StaticViewGeometry>() as u32,
        geometry_id: 0, head_from_eye: [xr::Posef::IDENTITY; 2], fov: [xr::Fovf::default(); 2] };
    let result = unsafe { get(instance.as_raw(), system, &mut geometry) };
    if result != sys::Result::SUCCESS { return Err(result); }
    if geometry.version != 1 || geometry.struct_size < std::mem::size_of::<StaticViewGeometry>() as u32 || geometry.geometry_id == 0 {
        return Err(sys::Result::ERROR_RUNTIME_FAILURE);
    }
    for i in 0..2 {
        let p = geometry.head_from_eye[i]; let f = geometry.fov[i];
        let q = [p.orientation.x,p.orientation.y,p.orientation.z,p.orientation.w];
        let norm: f32 = q.iter().map(|v| v*v).sum();
        if !q.iter().all(|v| v.is_finite()) || !norm.is_finite() || (norm-1.0).abs()>0.001 ||
            ![p.position.x,p.position.y,p.position.z,f.angle_left,f.angle_right,f.angle_up,f.angle_down].iter().all(|v| v.is_finite()) ||
            f.angle_left>=f.angle_right || f.angle_down>=f.angle_up ||
            f.angle_left<=-std::f32::consts::FRAC_PI_2 || f.angle_right>=std::f32::consts::FRAC_PI_2 ||
            f.angle_down<=-std::f32::consts::FRAC_PI_2 || f.angle_up>=std::f32::consts::FRAC_PI_2 {
            return Err(sys::Result::ERROR_RUNTIME_FAILURE);
        }
    }
    Ok(std::array::from_fn(|i| xr::View { pose: geometry.head_from_eye[i], fov: geometry.fov[i] }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_registration_loads_entry_only() {
        assert!(entry().is_err());
        assert_eq!(unsafe { xrizer_configure_openxr_provider(None) }, -1);
        assert_eq!(unsafe { xrizer_configure_openxr_provider(Some(fakexr::get_instance_proc_addr)) }, 0);
        assert!(entry().is_ok());
        assert_eq!(unsafe { xrizer_configure_openxr_provider(Some(fakexr::get_instance_proc_addr)) }, -1);
    }
}
