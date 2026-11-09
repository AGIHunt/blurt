//! Windows backend (owned by the Windows port): see host.rs for the contract.
use crate::host::Backend;

pub fn backend() -> Box<dyn Backend> {
    Box::new(crate::host::NoBackend::default())
}
