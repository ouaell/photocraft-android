//! Last-resort crash guard (AGENTS.md, Never crash): a panic during file
//! import/export becomes an `Err` the UI shows, and the open documents stay
//! in place. Same contract as the desktop shell's `crash_guard`.

use std::panic::AssertUnwindSafe;
use std::panic::catch_unwind;

/// Run `f`; a panic inside it becomes an `Err` naming `what`. The panic hook
/// already logged the details.
pub fn guard<T>(what: &str, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|_| Err(format!("{what} failed with an internal error (logged); your open documents are unchanged")))
}

#[cfg(test)]
#[allow(clippy::panic)]
mod tests {
    use super::guard;

    #[test]
    fn guard_turns_a_panic_into_an_error() {
        let r: Result<(), String> = guard("Open", || panic!("boom"));
        assert!(r.err().is_some_and(|e| e.contains("Open failed")));
        assert_eq!(guard::<()>("Open", || Err("bad file".into())), Err("bad file".into()));
        assert_eq!(guard("Open", || Ok(3)), Ok(3));
    }
}
