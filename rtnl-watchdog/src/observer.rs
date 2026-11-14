// SPDX-License-Identifier: GPL-2.0
use crate::{
    config::{self, Action},
    files, invalid,
    ipc::{self, Endpoint, Kind, Message},
    output::Output,
    state::{Model, State},
    sys,
};
use std::{
    io::{self, Write},
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    process::Child,
    sync::atomic::Ordering,
    time::{SystemTime, UNIX_EPOCH},
};
fn wall() -> io::Result<f64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| invalid("wall clock"))?
        .as_secs_f64())
}
pub fn helper_path(exe: &Path) -> io::Result<PathBuf> {
    Ok(exe
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| invalid("package path"))?
        .join("libexec/rtnl-watchdog-probe"))
}
fn epoch(child: u32) -> io::Result<String> {
    Ok(format!(
        "{}-{}-{}",
        std::process::id(),
        child,
        sys::monotonic()?
    ))
}
fn failure(event: &str, error: u32) {
    let _ = sys::nonblocking(2);
    let bytes = serde_json::to_vec(
        &serde_json::json!({"schema":1,"type":"status","event":event,"error_code":error}),
    )
    .unwrap_or_default();
    let mut bytes = bytes;
    bytes.push(b'\n');
    let _ = sys::write_bounded(2, &bytes);
}
pub fn run() -> io::Result<()> {
    let args = std::env::args_os()
        .skip(1)
        .map(|a| {
            a.into_string()
                .map_err(|_| invalid("invalid option encoding"))
        })
        .collect::<io::Result<Vec<_>>>()?;
    let action = config::parse(&args).map_err(|e| {
        failure("invalid_options", 6);
        e
    })?;
    let c = match action {
        Action::Help => {
            io::stdout().write_all(config::HELP.as_bytes())?;
            return Ok(());
        }
        Action::Version => {
            writeln!(io::stdout(), "{}", env!("CARGO_PKG_VERSION"))?;
            return Ok(());
        }
        Action::Run(c) => c,
    };
    if sys::euid() != 0 {
        failure("root_required", 6);
        return Err(invalid("root required"));
    }
    sys::standard_fds()?;
    sys::cloexec_policy().map_err(|e| {
        failure("descriptor_policy_failed", 7);
        e
    })?; // Before any worker thread.
    let lock = files::lock(&c.lock_file, 0).map_err(|e| {
        failure("lifetime_lock_unavailable", 7);
        e
    })?;
    let helper = helper_path(&std::env::current_exe()?)?;
    let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let mut m = Model::new(boot.trim_end_matches('\n'), &epoch(0)?)?;
    sys::signals()?;
    let output = Output::start(&c)?;
    let mut child: Option<Child> = None;
    let mut endpoint: Option<Endpoint> = None;
    let interval = c.interval_ms * 1_000_000;
    let backoff = c.error_backoff_ms.max(c.interval_ms) * 1_000_000;
    let mut next_probe = sys::monotonic()?;
    let mut next_frame = next_probe;
    let mut previous = State::Starting;
    while !sys::STOP.load(Ordering::Relaxed) {
        let now = sys::monotonic()?;
        if let Some(own) = child.as_mut() {
            match own.try_wait() {
                Ok(Some(_)) => {
                    output.event("helper_reaped", &m, own.id());
                    endpoint = None;
                    child = None;
                    m.inflight = false;
                    m.fail(7);
                    next_probe = now + backoff;
                }
                Err(_) if m.error != 7 => {
                    endpoint = None;
                    m.fail(7);
                } // Retain Child on uncertainty.
                _ => (),
            }
        }
        let mut broken = false;
        if let Some(ipc) = endpoint.as_mut() {
            if ipc.flush().is_err() {
                m.fail(6);
                broken = true;
            } else {
                for _ in 0..4 {
                    match ipc.receive() {
                        Ok(None) => break,
                        Ok(Some(message)) => {
                            let now = sys::monotonic()?;
                            match m.apply(message, now, wall()?) {
                                Ok(true) => {
                                    m.completed(&c);
                                    next_probe =
                                        now + if m.error != 0 { backoff } else { interval };
                                }
                                Ok(false) => (),
                                Err(_) => {
                                    broken = true;
                                    break;
                                }
                            }
                        }
                        Err(_) => {
                            m.fail(6);
                            broken = true;
                            break;
                        }
                    }
                }
            }
        }
        if broken {
            endpoint = None;
        } // EOF is unknown, never a reaping/cancellation signal.
        let now = sys::monotonic()?;
        if child.is_none() && now >= next_probe {
            match ipc::spawn(&helper, &lock) {
                Ok((own, ipc)) => {
                    m.rebind(&epoch(own.id())?)?;
                    previous = State::Starting;
                    output.event("helper_started", &m, own.id());
                    child = Some(own);
                    endpoint = Some(ipc);
                    next_probe = now;
                }
                Err(_) => {
                    m.fail(7);
                    next_probe = now + backoff;
                }
            }
        }
        if let Some(ipc) = endpoint.as_mut() {
            if child.is_some() && !m.inflight && now >= next_probe {
                m.dispatch(now)?;
                if ipc
                    .queue(Message {
                        kind: Kind::Request,
                        error: 0,
                        sequence: m.probe,
                        start: 0,
                        end: 0,
                    })
                    .and_then(|_| ipc.flush())
                    .is_err()
                {
                    m.fail(6);
                    endpoint = None;
                }
            }
        }
        let now = sys::monotonic()?;
        if now >= next_frame || m.state != previous {
            m.observe(now, wall()?, &c)?;
            if m.state != previous {
                output.event(m.state.name(), &m, child.as_ref().map_or(0, Child::id));
            }
            previous = m.state;
            output.submit(&m);
            next_frame = now + c.tick_ms * 1_000_000;
        }
        let mut due = next_frame;
        if (child.is_none() || (endpoint.is_some() && !m.inflight)) && next_probe < due {
            due = next_probe;
        }
        let delay = due
            .saturating_sub(sys::monotonic()?)
            .div_ceil(1_000_000)
            .min(i32::MAX as u64) as i32;
        sys::wait_read(
            endpoint.as_ref().map_or(-1, |p| p.stream.as_raw_fd()),
            delay,
        )?;
    }
    drop(endpoint); // No kernel cancellation; helper retains its own lock reference.
    output.event("observer_stopping", &m, child.as_ref().map_or(0, Child::id));
    let drained = output.stop();
    if let Some(mut child) = child {
        if !matches!(child.try_wait(), Ok(Some(_))) {
            failure("helper_outstanding_lock_retained", 7);
        }
    }
    drop(lock); // Never explicit unlock/unlink.
    drained
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn package_coupled_helper() {
        assert_eq!(
            helper_path(Path::new("/nix/store/pkg/bin/rtnl-watchdog")).unwrap(),
            Path::new("/nix/store/pkg/libexec/rtnl-watchdog-probe")
        );
    }
}
