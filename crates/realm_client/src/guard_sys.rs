//! The two operating-system calls the watch thread (`guard`) needs: keep this
//! library mapped for the life of the process, and end the process at once.

use std::ffi::c_void;
use std::time::Duration;

/// Ends the process now with `code`: no static destructors, no library
/// unloading, and, being an ordinary exit, no crash dialog or crash report.
pub fn exit_now(code: i32) -> ! {
    imp::exit_now(code);
    // Only a refused call gets here; the process must not go on either way.
    loop {
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Keeps this library loaded until the process ends: Godot unloads extensions
/// late in its shutdown, and the watch thread's code must still be there. False
/// when that cannot be promised (then the thread must not be started).
pub fn pin_this_library() -> bool {
    imp::pin(pin_this_library as *const () as *const c_void)
}

#[cfg(windows)]
mod imp {
    use std::ffi::c_void;

    const GET_MODULE_HANDLE_EX_FLAG_PIN: u32 = 0x1;
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn TerminateProcess(process: *mut c_void, code: u32) -> i32;
        fn GetModuleHandleExW(flags: u32, name: *const c_void, module: *mut *mut c_void) -> i32;
    }

    pub fn exit_now(code: i32) {
        // SAFETY: the pseudo handle of this process is always valid here.
        unsafe {
            TerminateProcess(GetCurrentProcess(), code as u32);
        }
    }

    pub fn pin(address: *const c_void) -> bool {
        let mut module = std::ptr::null_mut();
        let flags = GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS;
        // SAFETY: `address` lies in this library and `module` outlives the call.
        unsafe { GetModuleHandleExW(flags, address, &raw mut module) != 0 }
    }
}

#[cfg(unix)]
mod imp {
    use std::ffi::{c_char, c_int, c_void};

    const RTLD_NOW: c_int = 2;
    #[cfg(target_vendor = "apple")]
    const RTLD_NOLOAD: c_int = 0x10;
    #[cfg(target_vendor = "apple")]
    const RTLD_NODELETE: c_int = 0x80;
    #[cfg(not(target_vendor = "apple"))]
    const RTLD_NOLOAD: c_int = 0x4;
    #[cfg(not(target_vendor = "apple"))]
    const RTLD_NODELETE: c_int = 0x1000;

    #[repr(C)]
    struct DlInfo {
        fname: *const c_char,
        fbase: *mut c_void,
        sname: *const c_char,
        saddr: *mut c_void,
    }

    unsafe extern "C" {
        fn _exit(code: c_int) -> !;
        fn dladdr(address: *const c_void, info: *mut DlInfo) -> c_int;
        fn dlopen(path: *const c_char, flags: c_int) -> *mut c_void;
    }

    pub fn exit_now(code: i32) {
        // SAFETY: `_exit` takes any status and runs no handlers.
        unsafe { _exit(code) }
    }

    pub fn pin(address: *const c_void) -> bool {
        let mut info = DlInfo {
            fname: std::ptr::null(),
            fbase: std::ptr::null_mut(),
            sname: std::ptr::null(),
            saddr: std::ptr::null_mut(),
        };
        // SAFETY: `address` lies in this library; `fname` is read only when set,
        // and dlopen with RTLD_NOLOAD only adds a flag to the loaded library.
        unsafe {
            dladdr(address, &raw mut info) != 0
                && !info.fname.is_null()
                && !dlopen(info.fname, RTLD_NOW | RTLD_NOLOAD | RTLD_NODELETE).is_null()
        }
    }
}
