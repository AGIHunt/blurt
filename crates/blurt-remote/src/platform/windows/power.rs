//! Keep the PC awake (and with `display`, its screen on) while a phone is connected.
//!
//! A power request (PowerCreateRequest / PowerSetRequest) rather than SetThreadExecutionState: the latter belongs to the thread
//! that called it, and the server may call from any thread; a request is a handle, and `powercfg /requests` names it ("Blurt:
//! a phone is connected"), so a user wondering why the PC stayed up can see why.

use ::windows::core::PWSTR;
use ::windows::Win32::Foundation::{CloseHandle, HANDLE};
use ::windows::Win32::System::Power::{
    PowerClearRequest, PowerCreateRequest, PowerRequestDisplayRequired, PowerRequestSystemRequired, PowerSetRequest,
    SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
};
use ::windows::Win32::System::Threading::{POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0};

#[derive(Default)]
pub struct Power {
    /// the request's HANDLE (as a number: Send)
    request: isize,
    system: bool,
    display: bool,
}

const POWER_REQUEST_CONTEXT_VERSION: u32 = 0;

impl Power {
    fn handle(&mut self) -> Option<HANDLE> {
        if self.request == 0 {
            let mut reason: Vec<u16> = "Blurt: a phone is connected".encode_utf16().chain(std::iter::once(0)).collect();
            let ctx = REASON_CONTEXT {
                Version: POWER_REQUEST_CONTEXT_VERSION,
                Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
                Reason: REASON_CONTEXT_0 { SimpleReasonString: PWSTR(reason.as_mut_ptr()) },
            };
            let h = unsafe { PowerCreateRequest(&ctx) }.ok()?;
            self.request = h.0 as isize;
        }
        Some(HANDLE(self.request as *mut _))
    }

    pub fn set(&mut self, on: bool, display: bool) {
        let display = on && display;
        if on == self.system && display == self.display {
            return;
        }
        let Some(h) = self.handle() else {
            // no power request (shouldn't happen on 10/11): the calling thread's state, the old way
            let mut f = ES_CONTINUOUS;
            if on {
                f |= ES_SYSTEM_REQUIRED;
            }
            if display {
                f |= ES_DISPLAY_REQUIRED;
            }
            unsafe { SetThreadExecutionState(f) };
            self.system = on;
            self.display = display;
            return;
        };
        unsafe {
            if on != self.system {
                let _ = if on { PowerSetRequest(h, PowerRequestSystemRequired) } else { PowerClearRequest(h, PowerRequestSystemRequired) };
            }
            if display != self.display {
                let _ = if display { PowerSetRequest(h, PowerRequestDisplayRequired) } else { PowerClearRequest(h, PowerRequestDisplayRequired) };
            }
        }
        self.system = on;
        self.display = display;
    }
}

impl Drop for Power {
    fn drop(&mut self) {
        self.set(false, false);
        if self.request != 0 {
            unsafe {
                let _ = CloseHandle(HANDLE(self.request as *mut _));
            }
        }
    }
}
