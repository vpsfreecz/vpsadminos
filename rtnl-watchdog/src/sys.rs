// SPDX-License-Identifier: GPL-2.0
// Audited Linux boundary. Buffers remain owned/alive for every synchronous call.
use crate::{invalid, wire};
use std::{
    fs::{File, OpenOptions},
    io, mem,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
        unix::{fs::MetadataExt, net::UnixStream},
    },
    sync::atomic::{AtomicBool, Ordering},
};
pub static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}
pub fn signals() -> io::Result<()> {
    // SAFETY: zeroed sigaction is initialized below; handlers only set an atomic or ignore.
    let mut action: libc::sigaction = unsafe { mem::zeroed() };
    action.sa_sigaction = stop as *const () as usize;
    // SAFETY: valid initialized action/mask pointers; no handler captures Rust state.
    unsafe {
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGINT, libc::SIGTERM] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        action.sa_sigaction = libc::SIG_IGN;
        if libc::sigaction(libc::SIGPIPE, &action, std::ptr::null_mut()) < 0 {
            return Err(io::Error::last_os_error());
        }
        action.sa_sigaction = libc::SIG_DFL;
        if libc::sigaction(libc::SIGCHLD, &action, std::ptr::null_mut()) < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
pub fn euid() -> u32 {
    // SAFETY: geteuid has no memory arguments.
    unsafe { libc::geteuid() }
}
pub fn monotonic() -> io::Result<u64> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: writable initialized timespec with correct size.
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } < 0 {
        return Err(io::Error::last_os_error());
    }
    if time.tv_sec < 0 || !(0..1_000_000_000).contains(&time.tv_nsec) {
        return Err(invalid("invalid clock"));
    }
    (time.tv_sec as u64)
        .checked_mul(1_000_000_000)
        .and_then(|s| s.checked_add(time.tv_nsec as u64))
        .ok_or_else(|| invalid("clock overflow"))
}
pub fn cloexec_policy() -> io::Result<()> {
    // SAFETY: Linux scalar-only syscall; marks 3+ CLOEXEC, never closes live descriptors.
    if unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        )
    } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn standard_fds() -> io::Result<()> {
    use std::os::fd::IntoRawFd;
    for fd in 0..3 {
        // SAFETY: borrowed scalar descriptor query; startup has no worker threads.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0 {
            continue;
        }
        if io::Error::last_os_error().raw_os_error() != Some(libc::EBADF) {
            return Err(io::Error::last_os_error());
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/null")?;
        let raw = file.into_raw_fd(); // Transfer this reference to the process's fixed stdio slot.
        if raw != fd {
            // SAFETY: valid owned raw fd, fixed unoccupied stdio destination, before threads.
            let result = unsafe { libc::dup2(raw, fd) };
            let error = io::Error::last_os_error();
            // SAFETY: close the consumed source exactly once, never retry Linux close.
            unsafe {
                libc::close(raw);
            }
            if result < 0 {
                return Err(error);
            }
        }
    }
    Ok(())
}
pub fn nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl operates on a borrowed descriptor and does not take ownership.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn flock(file: &File) -> io::Result<()> {
    // SAFETY: descriptor is borrowed from a live File; never LOCK_UN.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn close_file(file: File) -> io::Result<()> {
    use std::os::fd::IntoRawFd;
    let fd = file.into_raw_fd();
    // SAFETY: consume exactly this owning File; Linux close must never be retried,
    // including EINTR, because the descriptor number may already have been freed.
    if unsafe { libc::close(fd) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn wait_read(fd: RawFd, millis: i32) -> io::Result<()> {
    let mut poll = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one initialized pollfd, live for the call, count exactly one.
    if unsafe { libc::poll(&mut poll, 1, millis) } < 0 {
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
    Ok(())
}
pub fn write_status(bytes: &[u8]) -> io::Result<()> {
    write_bounded(1, bytes)
}
pub fn write_bounded(fd: RawFd, bytes: &[u8]) -> io::Result<()> {
    if bytes.len() > 512 {
        return Err(invalid("status too large"));
    }
    // SAFETY: byte slice is valid for its length. FD1 is observer-only here, nonblocking.
    let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
    if n != bytes.len() as isize {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
pub fn inherited() -> io::Result<(UnixStream, File)> {
    inherited_for_owner(0)
}
// Owner parameter also permits no-probe FD tests under an unprivileged Nix builder.
// The installed helper always calls inherited(), which requires root.
pub fn inherited_for_owner(owner: u32) -> io::Result<(UnixStream, File)> {
    if euid() != owner {
        return Err(invalid("private helper owner"));
    }
    let mut kind: libc::c_int = 0;
    let mut domain: libc::c_int = 0;
    let mut len = mem::size_of_val(&kind) as libc::socklen_t;
    // SAFETY: initialized scalar output, correct byte capacity, borrowed FD0.
    if unsafe {
        libc::getsockopt(
            0,
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            (&mut kind as *mut libc::c_int).cast(),
            &mut len,
        )
    } < 0
        || len as usize != mem::size_of_val(&kind)
        || kind != libc::SOCK_STREAM
    {
        return Err(invalid("private IPC type"));
    }
    len = mem::size_of_val(&domain) as libc::socklen_t;
    // SAFETY: same initialized scalar output contract as above.
    if unsafe {
        libc::getsockopt(
            0,
            libc::SOL_SOCKET,
            libc::SO_DOMAIN,
            (&mut domain as *mut libc::c_int).cast(),
            &mut len,
        )
    } < 0
        || len as usize != mem::size_of_val(&domain)
        || domain != libc::AF_UNIX
    {
        return Err(invalid("private IPC domain"));
    }
    let mut peer = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    len = mem::size_of_val(&peer) as libc::socklen_t;
    // SAFETY: initialized ucred of exactly advertised capacity, scalar getppid.
    if unsafe {
        libc::getsockopt(
            0,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut peer as *mut libc::ucred).cast(),
            &mut len,
        )
    } < 0
        || len as usize != mem::size_of_val(&peer)
        || peer.uid != owner
        || peer.pid != unsafe { libc::getppid() }
    {
        return Err(invalid("private IPC peer"));
    }
    // SAFETY: FD1 validity is established by fcntl before exactly one owning File is made.
    if unsafe { libc::fcntl(1, libc::F_GETFD) } < 0 {
        return Err(invalid("private lock absent"));
    }
    let lock = unsafe { File::from_raw_fd(1) };
    let st = lock.metadata()?;
    if !st.is_file() || st.uid() != owner || st.mode() & 0o777 != 0o600 || st.nlink() != 1 {
        return Err(invalid("private lock identity"));
    }
    let other = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/proc/self/fd/1")?;
    match flock(&other) {
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => (),
        _ => return Err(invalid("private lock not inherited")),
    }
    flock(&lock)?;
    // SAFETY: FD0 is a validated connected AF_UNIX stream, transferred exactly once;
    // no stdin handle is created anywhere in the helper.
    let ipc = unsafe { UnixStream::from_raw_fd(0) };
    Ok((ipc, lock))
}
pub fn host_namespace() -> io::Result<()> {
    let own = std::fs::metadata("/proc/self/ns/net")?;
    let init = std::fs::metadata("/proc/1/ns/net")?;
    if own.dev() != init.dev() || own.ino() != init.ino() {
        return Err(invalid("wrong network namespace"));
    }
    Ok(())
}
pub struct Netlink {
    fd: OwnedFd,
    port: u32,
}
impl Netlink {
    pub fn open() -> io::Result<Self> {
        // SAFETY: scalar socket arguments; only a nonnegative new fd becomes owned.
        let raw = unsafe {
            libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC,
                libc::NETLINK_ROUTE,
            )
        };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: zero is a valid initial sockaddr_nl, including padding.
        let mut local: libc::sockaddr_nl = unsafe { mem::zeroed() };
        local.nl_family = libc::AF_NETLINK as u16;
        let mut len = mem::size_of_val(&local) as libc::socklen_t;
        // SAFETY: valid sockaddr with length exactly its allocation; output len initialized.
        if unsafe {
            libc::bind(
                fd.as_raw_fd(),
                (&local as *const libc::sockaddr_nl).cast(),
                len,
            )
        } < 0
            || unsafe {
                libc::getsockname(
                    fd.as_raw_fd(),
                    (&mut local as *mut libc::sockaddr_nl).cast(),
                    &mut len,
                )
            } < 0
        {
            return Err(io::Error::last_os_error());
        }
        if len as usize != mem::size_of_val(&local)
            || local.nl_family != libc::AF_NETLINK as u16
            || local.nl_pid == 0
            || local.nl_groups != 0
        {
            return Err(invalid("netlink local address"));
        }
        Ok(Self {
            fd,
            port: local.nl_pid,
        })
    }
    pub fn exchange(&self, sequence: u32) -> Result<(), u32> {
        let request = wire::request(sequence, self.port);
        // SAFETY: sockaddr_nl/msghdr are POD, fully zero initialized and fields set below.
        let mut address: libc::sockaddr_nl = unsafe { mem::zeroed() };
        address.nl_family = libc::AF_NETLINK as u16;
        let mut iov = libc::iovec {
            iov_base: request.as_ptr().cast_mut().cast(),
            iov_len: request.len(),
        };
        let mut msg: libc::msghdr = unsafe { mem::zeroed() };
        msg.msg_name = (&mut address as *mut libc::sockaddr_nl).cast();
        msg.msg_namelen = mem::size_of_val(&address) as libc::socklen_t;
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        // SAFETY: live request/iovec/address; sendmsg reads exactly the immutable slice.
        // Deliberately synchronous: .117 caller-context RTNL wait remains observable.
        if unsafe { libc::sendmsg(self.fd.as_raw_fd(), &msg, 0) } != request.len() as isize {
            return Err(3);
        }
        let mut buffer = [0u8; wire::REPLY_LIMIT];
        let mut receive_iov = libc::iovec {
            iov_base: buffer.as_mut_ptr().cast(),
            iov_len: buffer.len(),
        };
        msg.msg_iov = &mut receive_iov;
        // SAFETY: all msghdr pointers still reference live initialized writable buffers.
        let n = unsafe { libc::recvmsg(self.fd.as_raw_fd(), &mut msg, 0) };
        if n < 0 {
            return Err(4);
        }
        if n as usize > buffer.len() {
            return Err(5);
        }
        wire::reply(
            &buffer[..n as usize],
            address.nl_family,
            address.nl_pid,
            address.nl_groups,
            msg.msg_namelen as usize,
            msg.msg_flags,
            &request,
        )
        .map_err(|_| 5)
    }
}
