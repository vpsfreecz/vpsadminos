// SPDX-License-Identifier: GPL-2.0
use rtnl_watchdog::{
    files,
    ipc::{self, Kind},
    sys,
};
use std::{
    fs,
    os::{
        fd::OwnedFd,
        unix::{
            fs::{MetadataExt, PermissionsExt},
            net::UnixStream,
        },
    },
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
fn fixture() -> PathBuf {
    let root = std::env::var_os("RW1_TEST_DIRECTORY")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let path = root.join(format!(
        "rw1-native-{}-{}",
        std::process::id(),
        sys::monotonic().unwrap()
    ));
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path
}
fn fd_child() -> PathBuf {
    let dir = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();
    let paths = fs::read_dir(dir)
        .unwrap()
        .filter_map(|p| p.ok())
        .map(|p| p.path())
        .filter(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("fd_child-")
                && p.extension().is_none()
        })
        .collect::<Vec<_>>();
    assert_eq!(
        paths.len(),
        1,
        "one exact harness-free native exec target required"
    );
    paths[0].clone()
}
#[test]
fn real_exec_parent_death_flock_and_atomic_files() {
    assert!(Command::new(fd_child())
        .env("RW1_STDIO_TEST", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success());
    let path = fixture();
    let lock_path = path.join("lock");
    let owner = sys::euid();
    let lock = files::lock(&lock_path, owner).unwrap();
    let original = lock.metadata().unwrap();
    assert!(files::lock(&lock_path, owner).is_err());
    // SAFETY: scalar Linux test-subprocess adoption policy; this test owns all its children.
    assert_eq!(
        unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) },
        0
    );
    let (mut parent, child) = UnixStream::pair().unwrap();
    let mut command = Command::new(fd_child());
    command
        .env("RW1_FD_TEST", "1")
        .env("RW1_FD_OWNER", "1")
        .stdin(Stdio::from(OwnedFd::from(child)))
        .stdout(Stdio::from(lock.try_clone().unwrap()))
        .stderr(Stdio::null());
    let mut own = command.spawn().unwrap();
    drop(command);
    drop(lock);
    parent
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let message = ipc::blocking_read(&mut parent).unwrap();
    assert_eq!(message.kind, Kind::Started);
    assert!(own.wait().unwrap().success());
    assert!(
        files::lock(&lock_path, owner).is_err(),
        "orphan helper must still retain flock"
    );
    let pid = message.sequence as libc::pid_t;
    let mut status = 0;
    // SAFETY: reap only the exact adopted test-owned child; bounded synthetic call is600ms.
    assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
    assert!(libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0);
    let lock = files::lock(&lock_path, owner).unwrap();
    let after = lock.metadata().unwrap();
    assert_eq!((after.dev(), after.ino()), (original.dev(), original.ino()));
    drop(lock);
    let state = path.join("state");
    let temporary = path.join(format!(".state.tmp.{}", std::process::id()));
    fs::write(&temporary, b"preexisting").unwrap();
    assert!(files::write(&state, b"new", 0o600, owner).is_err());
    assert_eq!(fs::read(&temporary).unwrap(), b"preexisting");
    fs::remove_file(temporary).unwrap();
    let first = files::write(&state, b"{\"schema\":1}\n", 0o600, owner).unwrap();
    assert_eq!(fs::metadata(&state).unwrap().mode() & 0o777, 0o600);
    let next = files::write(&state, b"{\"schema\":1,\"sequence\":2}\n", 0o600, owner).unwrap();
    files::remove(&state, Some(first), owner);
    assert!(state.exists());
    std::os::unix::fs::symlink(&state, path.join("alias")).unwrap();
    assert!(files::write(&path.join("alias"), b"bad", 0o600, owner).is_err());
    files::remove(&state, Some(next), owner);
    assert!(!state.exists());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(files::lock(&lock_path, owner).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    // The actual helper must reject absent private setup before any networking.
    let status = Command::new(env!("CARGO_BIN_EXE_rtnl-watchdog-probe"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(!status.success());
    let started = Instant::now();
    assert!(ipc::spawn(
        &path.join("missing"),
        &files::lock(&lock_path, owner).unwrap()
    )
    .is_err());
    assert!(started.elapsed() < Duration::from_secs(3));
    fs::remove_dir_all(path).unwrap();
}
#[test]
fn public_help_and_version_do_not_probe() {
    let binary = env!("CARGO_BIN_EXE_rtnl-watchdog");
    let help = Command::new(binary).arg("--help").output().unwrap();
    assert!(help.status.success());
    assert!(String::from_utf8(help.stdout)
        .unwrap()
        .starts_with("Usage: rtnl-watchdog [OPTIONS]"));
    let version = Command::new(binary).arg("--version").output().unwrap();
    assert!(version.status.success());
    assert_eq!(version.stdout, b"1.0.0\n");
}
