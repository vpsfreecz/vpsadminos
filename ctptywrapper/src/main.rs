use std::env;
use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::Value;

const READ_SIZE: usize = 4096;
const MAX_COMMAND_BUFFER: usize = 64 * 1024;
const CHILD_WAIT_TIMEOUT: Duration = Duration::from_secs(3);

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, PartialEq, Eq)]
struct ConsoleCommand {
    keys: Option<String>,
    rows: Option<u16>,
    cols: Option<u16>,
}

#[derive(Default)]
struct LineBuffer {
    buf: Vec<u8>,
}

impl LineBuffer {
    fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        if self.buf.len().saturating_add(data.len()) > MAX_COMMAND_BUFFER {
            self.buf.clear();
        }

        self.buf.extend_from_slice(data);

        let mut lines = Vec::new();

        while let Some(i) = self.buf.iter().position(|&v| v == b'\n') {
            let line: Vec<u8> = self.buf.drain(..=i).collect();

            if line.len() <= MAX_COMMAND_BUFFER {
                lines.push(line);
            }
        }

        if self.buf.len() > MAX_COMMAND_BUFFER {
            self.buf.clear();
        }

        lines
    }
}

fn main() {
    if let Err(e) = run() {
        eprintln!("osctld-ct-wrapper: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() < 4 {
        return Err(format!(
            "usage: {} <title> <socket> <command> [args...]",
            args.first()
                .map(String::as_str)
                .unwrap_or("osctld-ct-wrapper")
        )
        .into());
    }

    set_process_name(&format!("osctld: CT {}", args[1]));

    let socket_path = Path::new(&args[2]);
    let listener = UnixListener::bind(socket_path)?;

    let (pty, child_pid) = match spawn_pty(&args[3..]) {
        Ok(v) => v,
        Err(e) => {
            let _ = fs::remove_file(socket_path);
            return Err(e);
        }
    };

    let loop_result = event_loop(&listener, pty, child_pid);

    drop(listener);
    let _ = fs::remove_file(socket_path);

    terminate_child(child_pid);

    loop_result.map_err(Into::into)
}

fn set_process_name(name: &str) {
    let mut bytes = name.as_bytes().to_vec();
    bytes.truncate(15);
    bytes.push(0);

    unsafe {
        libc::prctl(libc::PR_SET_NAME, bytes.as_ptr() as libc::c_ulong, 0, 0, 0);
    }
}

fn spawn_pty(cmd: &[String]) -> Result<(File, libc::pid_t)> {
    let cstrings = cmd
        .iter()
        .map(|v| CString::new(v.as_str()))
        .collect::<std::result::Result<Vec<_>, _>>()?;

    let mut argv = cstrings
        .iter()
        .map(|v| v.as_ptr())
        .collect::<Vec<*const libc::c_char>>();
    argv.push(ptr::null());

    let mut master_fd: libc::c_int = -1;
    let pid = unsafe { libc::forkpty(&mut master_fd, ptr::null_mut(), ptr::null(), ptr::null()) };

    if pid < 0 {
        return Err(io::Error::last_os_error().into());
    }

    if pid == 0 {
        unsafe {
            libc::execvp(argv[0], argv.as_ptr());
            libc::_exit(127);
        }
    }

    let pty = unsafe { File::from_raw_fd(master_fd) };
    Ok((pty, pid))
}

fn event_loop(listener: &UnixListener, mut pty: File, child_pid: libc::pid_t) -> io::Result<()> {
    let mut client: Option<UnixStream> = None;
    let mut cmd_buf = LineBuffer::default();
    let mut current_rows = 25;
    let mut current_cols = 80;
    let mut read_buf = [0_u8; READ_SIZE];

    loop {
        let mut fds = vec![
            libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: pty.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];

        if let Some(c) = client.as_ref() {
            fds.push(libc::pollfd {
                fd: c.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
        }

        let ret = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, -1) };

        if ret < 0 {
            let err = io::Error::last_os_error();

            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }

            return Err(err);
        }

        if fds[0].revents & libc::POLLIN != 0 {
            accept_client(listener, &mut client);
        }

        if fds.len() > 2 && fds[2].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            let mut close_client = false;

            if let Some(c) = client.as_mut() {
                match c.read(&mut read_buf) {
                    Ok(0) => close_client = true,
                    Ok(n) => process_client_data(
                        &read_buf[..n],
                        &mut cmd_buf,
                        &mut pty,
                        child_pid,
                        &mut current_rows,
                        &mut current_cols,
                    )?,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                    Err(_) => close_client = true,
                }
            }

            if close_client {
                client = None;
            }
        }

        if fds[1].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            match pty.read(&mut read_buf) {
                Ok(0) => return Ok(()),
                Ok(n) => {
                    if let Some(c) = client.as_mut() {
                        if c.write_all(&read_buf[..n]).is_err() {
                            client = None;
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.raw_os_error() == Some(libc::EIO) => return Ok(()),
                Err(e) => return Err(e),
            }
        }
    }
}

fn accept_client(listener: &UnixListener, client: &mut Option<UnixStream>) {
    let Ok((c, _)) = listener.accept() else {
        return;
    };

    if client_uid(c.as_raw_fd()) == Some(0) {
        *client = Some(c);
    }
}

fn client_uid(fd: RawFd) -> Option<u32> {
    let mut cred = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;

    let ret = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut cred as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };

    if ret == 0 {
        Some(cred.uid)
    } else {
        None
    }
}

fn process_client_data(
    data: &[u8],
    cmd_buf: &mut LineBuffer,
    pty: &mut File,
    child_pid: libc::pid_t,
    current_rows: &mut u16,
    current_cols: &mut u16,
) -> io::Result<()> {
    for line in cmd_buf.push(data) {
        let Some(cmd) = parse_command(&line) else {
            continue;
        };

        if let Some(keys) = cmd.keys {
            let Ok(decoded) = STANDARD.decode(keys.as_bytes()) else {
                continue;
            };

            pty.write_all(&decoded)?;
            pty.flush()?;
        }

        let (Some(rows), Some(cols)) = (cmd.rows, cmd.cols) else {
            continue;
        };

        if rows == 0 || cols == 0 || (rows == *current_rows && cols == *current_cols) {
            continue;
        }

        *current_rows = rows;
        *current_cols = cols;
        resize_pty(pty.as_raw_fd(), child_pid, rows, cols);
    }

    Ok(())
}

fn parse_command(line: &[u8]) -> Option<ConsoleCommand> {
    let value = serde_json::from_slice::<Value>(line).ok()?;
    let obj = value.as_object()?;

    let keys = match obj.get("keys") {
        Some(Value::String(v)) => Some(v.clone()),
        Some(_) => return None,
        None => None,
    };

    Some(ConsoleCommand {
        keys,
        rows: obj.get("rows").and_then(parse_u16),
        cols: obj.get("cols").and_then(parse_u16),
    })
}

fn parse_u16(value: &Value) -> Option<u16> {
    match value {
        Value::Number(v) => {
            let n = v.as_u64()?;

            if n <= u16::MAX as u64 {
                Some(n as u16)
            } else {
                None
            }
        }
        Value::String(v) => v.parse::<u16>().ok(),
        _ => None,
    }
}

fn resize_pty(fd: RawFd, child_pid: libc::pid_t, rows: u16, cols: u16) {
    let winsize = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    unsafe {
        libc::ioctl(fd, libc::TIOCSWINSZ, &winsize);
        libc::kill(child_pid, libc::SIGWINCH);
    }
}

fn terminate_child(pid: libc::pid_t) {
    let start = Instant::now();

    loop {
        match wait_child(pid, libc::WNOHANG) {
            WaitResult::Exited | WaitResult::NoChild => return,
            WaitResult::Running => {}
            WaitResult::Interrupted => continue,
        }

        if start.elapsed() >= CHILD_WAIT_TIMEOUT {
            break;
        }

        thread::sleep(Duration::from_millis(100));
    }

    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }

    loop {
        match wait_child(pid, 0) {
            WaitResult::Exited | WaitResult::NoChild => return,
            WaitResult::Running | WaitResult::Interrupted => continue,
        }
    }
}

enum WaitResult {
    Exited,
    Running,
    Interrupted,
    NoChild,
}

fn wait_child(pid: libc::pid_t, flags: libc::c_int) -> WaitResult {
    let mut status = 0;
    let ret = unsafe { libc::waitpid(pid, &mut status, flags) };

    if ret == pid {
        WaitResult::Exited
    } else if ret == 0 {
        WaitResult::Running
    } else {
        match io::Error::last_os_error().raw_os_error() {
            Some(libc::EINTR) => WaitResult::Interrupted,
            Some(libc::ECHILD) => WaitResult::NoChild,
            _ => WaitResult::NoChild,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem;
    use std::sync::atomic::{AtomicI32, Ordering};

    static SIGWINCH_PIPE: AtomicI32 = AtomicI32::new(-1);

    extern "C" fn record_sigwinch(_signum: libc::c_int) {
        let fd = SIGWINCH_PIPE.load(Ordering::Relaxed);

        if fd >= 0 {
            let byte = [b'w'];

            unsafe {
                libc::write(fd, byte.as_ptr().cast(), byte.len());
            }
        }
    }

    struct ChildGuard(libc::pid_t);

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            unsafe {
                libc::kill(self.0, libc::SIGKILL);
            }

            loop {
                match wait_child(self.0, 0) {
                    WaitResult::Exited | WaitResult::NoChild => return,
                    WaitResult::Running | WaitResult::Interrupted => continue,
                }
            }
        }
    }

    fn spawn_sigwinch_child() -> io::Result<(File, libc::pid_t, File)> {
        let mut pipe_fds = [-1, -1];

        if unsafe { libc::pipe(pipe_fds.as_mut_ptr()) } < 0 {
            return Err(io::Error::last_os_error());
        }

        let mut master_fd: libc::c_int = -1;
        let pid = unsafe {
            libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };

        if pid < 0 {
            let err = io::Error::last_os_error();

            unsafe {
                libc::close(pipe_fds[0]);
                libc::close(pipe_fds[1]);
            }

            return Err(err);
        }

        if pid == 0 {
            unsafe {
                libc::close(pipe_fds[0]);
                SIGWINCH_PIPE.store(pipe_fds[1], Ordering::Relaxed);

                let mut action: libc::sigaction = mem::zeroed();
                action.sa_sigaction = record_sigwinch as usize;
                action.sa_flags = 0;
                libc::sigemptyset(&mut action.sa_mask);

                if libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut()) < 0 {
                    libc::_exit(1);
                }

                let ready = [b'r'];
                libc::write(pipe_fds[1], ready.as_ptr().cast(), ready.len());

                loop {
                    libc::pause();
                }
            }
        }

        unsafe {
            libc::close(pipe_fds[1]);
        }

        let pty = unsafe { File::from_raw_fd(master_fd) };
        let signal_pipe = unsafe { File::from_raw_fd(pipe_fds[0]) };

        Ok((pty, pid, signal_pipe))
    }

    fn wait_for_pipe_byte(reader: &mut File, expected: u8) -> io::Result<()> {
        let start = Instant::now();

        loop {
            let elapsed = start.elapsed();

            if elapsed >= Duration::from_secs(2) {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("timed out waiting for byte {expected}"),
                ));
            }

            let timeout = (Duration::from_secs(2) - elapsed).as_millis() as libc::c_int;
            let mut fds = [libc::pollfd {
                fd: reader.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }];
            let ret = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };

            if ret < 0 {
                let err = io::Error::last_os_error();

                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }

                return Err(err);
            } else if ret == 0 {
                continue;
            }

            let mut buf = [0_u8];

            match reader.read(&mut buf) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "signal pipe closed",
                    ));
                }
                Ok(_) if buf[0] == expected => return Ok(()),
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }

    fn pty_winsize(fd: RawFd) -> io::Result<(u16, u16)> {
        let mut winsize: libc::winsize = unsafe { mem::zeroed() };
        let ret = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut winsize) };

        if ret < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok((winsize.ws_row, winsize.ws_col))
        }
    }

    #[test]
    fn parses_keys_and_size() {
        let cmd = parse_command(br#"{"keys":"aGk=","rows":30,"cols":100}"#).unwrap();

        assert_eq!(
            cmd,
            ConsoleCommand {
                keys: Some("aGk=".to_string()),
                rows: Some(30),
                cols: Some(100),
            }
        );
    }

    #[test]
    fn parses_string_size_values() {
        let cmd = parse_command(br#"{"rows":"25","cols":"80"}"#).unwrap();

        assert_eq!(cmd.rows, Some(25));
        assert_eq!(cmd.cols, Some(80));
    }

    #[test]
    fn ignores_invalid_commands() {
        assert_eq!(parse_command(b"not json\n"), None);
        assert_eq!(parse_command(br#"{"keys":true}"#), None);
        assert_eq!(
            parse_command(br#"{"rows":70000,"cols":80}"#).unwrap().rows,
            None
        );
    }

    #[test]
    fn buffers_split_lines() {
        let mut buf = LineBuffer::default();

        assert!(buf.push(br#"{"keys":"a"#).is_empty());

        let lines = buf.push(b"ops\"}\n{\"rows\":25,\"cols\":80}\n");

        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0], b"{\"keys\":\"aops\"}\n");
        assert_eq!(lines[1], b"{\"rows\":25,\"cols\":80}\n");
    }

    #[test]
    fn clears_overlarge_buffer() {
        let mut buf = LineBuffer::default();
        let large = vec![b'a'; MAX_COMMAND_BUFFER + 1];

        assert!(buf.push(&large).is_empty());
        assert!(buf.buf.is_empty());
    }

    #[test]
    fn resizing_client_command_updates_pty_and_signals_child() {
        let (mut pty, child_pid, mut signal_pipe) = spawn_sigwinch_child().unwrap();
        let _guard = ChildGuard(child_pid);

        wait_for_pipe_byte(&mut signal_pipe, b'r').unwrap();

        let mut cmd_buf = LineBuffer::default();
        let mut current_rows = 25;
        let mut current_cols = 80;

        process_client_data(
            br#"{"rows":37,"cols":132}"#,
            &mut cmd_buf,
            &mut pty,
            child_pid,
            &mut current_rows,
            &mut current_cols,
        )
        .unwrap();

        assert_eq!((current_rows, current_cols), (25, 80));

        process_client_data(
            b"\n",
            &mut cmd_buf,
            &mut pty,
            child_pid,
            &mut current_rows,
            &mut current_cols,
        )
        .unwrap();

        wait_for_pipe_byte(&mut signal_pipe, b'w').unwrap();

        assert_eq!((current_rows, current_cols), (37, 132));
        assert_eq!(pty_winsize(pty.as_raw_fd()).unwrap(), (37, 132));
    }
}
