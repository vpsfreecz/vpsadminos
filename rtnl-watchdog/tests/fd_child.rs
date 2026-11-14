// SPDX-License-Identifier: GPL-2.0
// Test-only harness-free exec target. No netlink or fake healthy-response backend.
use rtnl_watchdog::{
    ipc::{self, Kind, Message},
    sys,
};
use std::{fs::File, io, os::fd::AsRawFd, time::Duration};
fn run() -> io::Result<()> {
    if std::env::var_os("RW1_STDIO_TEST").is_some() {
        use std::os::unix::fs::FileTypeExt;
        // SAFETY: isolated test executable closes only its own three /dev/null stdio FDs.
        for fd in 0..3 {
            unsafe {
                libc::close(fd);
            }
        }
        sys::standard_fds()?;
        for fd in 0..3 {
            if !std::fs::metadata(format!("/proc/self/fd/{fd}"))?
                .file_type()
                .is_char_device()
            {
                return Err(io::Error::other("stdio not reserved"));
            }
        }
        if File::open("/dev/null")?.as_raw_fd() < 3 {
            return Err(io::Error::other("stdio reused"));
        }
        return Ok(());
    }
    if std::env::var_os("RW1_FD_TEST").is_none() {
        return Ok(());
    } // Cargo's ordinary test invocation.
    let owner = std::env::var_os("RW1_FD_OWNER").is_some();
    let (mut stream, lock) = sys::inherited_for_owner(sys::euid())?;
    if owner {
        // Single-threaded test process only.
        std::env::remove_var("RW1_FD_OWNER");
        // SAFETY: this isolated test owner has no threads or pending children yet.
        // Production signal setup must restore reapable children even if SIGCHLD was ignored.
        unsafe {
            libc::signal(libc::SIGCHLD, libc::SIG_IGN);
        }
        sys::signals()?;
        // SAFETY: initialized output structure of exactly the sigaction ABI size.
        let mut disposition: libc::sigaction = unsafe { std::mem::zeroed() };
        if unsafe { libc::sigaction(libc::SIGCHLD, std::ptr::null(), &mut disposition) } < 0
            || disposition.sa_sigaction != libc::SIG_DFL
        {
            return Err(io::Error::other("SIGCHLD not reapable"));
        }
        let unrelated = File::open("/dev/null")?;
        // SAFETY: test-only scalar fcntl on a live file, intentionally makes fd99 inheritable.
        if unsafe { libc::dup2(unrelated.as_raw_fd(), 99) } != 99 {
            return Err(io::Error::last_os_error());
        }
        sys::cloexec_policy()?;
        let (mut child, mut endpoint) = ipc::spawn(&std::env::current_exe()?, &lock)?;
        endpoint.queue(Message {
            kind: Kind::Request,
            error: 0,
            sequence: 1,
            start: 0,
            end: 0,
        })?;
        endpoint.flush()?;
        loop {
            if endpoint.receive()?.is_some() {
                break;
            }
            sys::wait_read(endpoint.stream.as_raw_fd(), 100)?;
        }
        ipc::blocking_write(
            &mut stream,
            Message {
                kind: Kind::Started,
                error: 0,
                sequence: child.id() as u64,
                start: 0,
                end: 0,
            },
        )?;
        let _ = child.try_wait()?;
        std::process::exit(0); // Real owner death; exec child still holds the same OFD.
    }
    // SAFETY: borrowed scalar descriptor query only; fd99 must be gone after exec.
    if unsafe { libc::fcntl(99, libc::F_GETFD) } >= 0 {
        return Err(io::Error::other("unrelated descriptor leaked"));
    }
    let request = ipc::blocking_read(&mut stream)?;
    ipc::blocking_write(
        &mut stream,
        Message {
            kind: Kind::Started,
            ..request
        },
    )?;
    std::thread::sleep(Duration::from_millis(600)); // Bounded synthetic outstanding call.
    Ok(())
}
fn main() {
    if run().is_err() {
        std::process::exit(1);
    }
}
