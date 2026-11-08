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
