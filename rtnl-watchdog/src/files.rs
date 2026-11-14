// SPDX-License-Identifier: GPL-2.0
use crate::{invalid, sys};
use std::{
    fs::{self, File, Metadata, OpenOptions, Permissions},
    io::{self, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};
#[derive(Clone, Copy)]
pub struct Identity {
    pub dev: u64,
    pub ino: u64,
}
impl Identity {
    fn from(m: &Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
        }
    }
}
fn parent(path: &Path, owner: u32) -> io::Result<(File, PathBuf)> {
    let dir = path.parent().ok_or_else(|| invalid("missing directory"))?;
    let name = path
        .file_name()
        .ok_or_else(|| invalid("missing filename"))?;
    let fd = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(dir)?;
    let st = fd.metadata()?;
    if st.uid() != owner || st.mode() & 0o022 != 0 {
        return Err(invalid("untrusted directory"));
    }
    let anchored = PathBuf::from(format!("/proc/self/fd/{}", fd.as_raw_fd())).join(name);
    Ok((fd, anchored))
}
pub fn lock(path: &Path, owner: u32) -> io::Result<File> {
    let (_dir, anchored) = parent(path, owner)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(anchored)?;
    let st = file.metadata()?;
    if !st.is_file() || st.uid() != owner || st.mode() & 0o777 != 0o600 || st.nlink() != 1 {
        return Err(invalid("untrusted lock"));
    }
    sys::flock(&file)?;
    Ok(file) // Drop closes this reference; never LOCK_UN or unlink.
}
pub fn write(path: &Path, data: &[u8], mode: u32, owner: u32) -> io::Result<Identity> {
    if data.len() > 4096 {
        return Err(invalid("output too large"));
    }
    let (_dir, anchored) = parent(path, owner)?;
    match fs::symlink_metadata(&anchored) {
        Ok(st)
            if !st.is_file()
                || st.uid() != owner
                || st.nlink() != 1
                || st.mode() & 0o777 != mode =>
        {
            return Err(invalid("untrusted output"))
        }
        Ok(_) => (),
        Err(e) if e.kind() == io::ErrorKind::NotFound => (),
        Err(e) => return Err(e),
    }
    let temporary = anchored.with_file_name(format!(
        ".{}.tmp.{}",
        path.file_name().unwrap().to_string_lossy(),
        std::process::id()
    ));
    let mut created = None;
    let result = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        created = Some(Identity::from(&f.metadata()?));
        f.write_all(data)?;
        f.set_permissions(Permissions::from_mode(mode))?;
        let id = Identity::from(&f.metadata()?);
        sys::close_file(f)?;
        fs::rename(&temporary, &anchored)?;
        Ok(id)
    })();
    if result.is_err() {
        if let (Some(id), Ok(st)) = (created, fs::symlink_metadata(&temporary)) {
            if st.dev() == id.dev && st.ino() == id.ino {
                let _ = fs::remove_file(&temporary);
            }
        }
    }
    result
}
pub fn remove(path: &Path, identity: Option<Identity>, owner: u32) {
    if let (Some(id), Ok((_dir, anchored))) = (identity, parent(path, owner)) {
        if let Ok(st) = fs::symlink_metadata(&anchored) {
            if st.dev() == id.dev && st.ino() == id.ino {
                let _ = fs::remove_file(&anchored);
            }
        }
    }
}
