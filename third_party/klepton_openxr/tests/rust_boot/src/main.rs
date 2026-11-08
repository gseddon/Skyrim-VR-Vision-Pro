use std::{ffi::{c_char, c_void}, mem, ptr};
use openxr::{self as xr, sys};
#[repr(C)]
struct Host {
    version: u32, size: u32, context: *mut c_void,
    available: Option<unsafe extern "C" fn(*mut c_void) -> sys::Result>,
    properties: Option<unsafe extern "C" fn(*mut c_void, *mut c_void) -> sys::Result>,
}
unsafe extern "C" fn available(_: *mut c_void) -> sys::Result { sys::Result::SUCCESS }
unsafe extern "C" {
    fn kl_native_configure(host: *const Host) -> sys::Result;
}
unsafe extern "system" {
    fn kl_native_get_instance_proc_addr(instance: sys::Instance, name: *const c_char, out: *mut Option<unsafe extern "system" fn()>) -> sys::Result;
}
fn main() {
    let host = Host { version: 1, size: mem::size_of::<Host>() as u32, context: ptr::null_mut(), available: Some(available), properties: None };
    assert_eq!(unsafe { kl_native_configure(&host) }, sys::Result::SUCCESS);
    let entry = unsafe { xr::Entry::from_get_instance_proc_addr(kl_native_get_instance_proc_addr) }.unwrap();
    let extensions = entry.enumerate_extensions().unwrap();
    assert!(!extensions.khr_metal_enable);
    let instance = entry.create_instance(&xr::ApplicationInfo { application_name: "owned-boot", ..Default::default() }, &xr::ExtensionSet::default(), &[]).unwrap();
    assert!(instance.system(xr::FormFactor::HEAD_MOUNTED_DISPLAY).is_ok());
    drop(instance);
    println!("openxrs Entry and Instance dispatch: pass; mock host, no session or VR frame");
}
