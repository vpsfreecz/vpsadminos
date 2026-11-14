// SPDX-License-Identifier: GPL-2.0
use crate::invalid;
use std::{
    fs::File,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    process::{Child, Command, Stdio},
};
pub const SIZE: usize = 32;
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Request = 1,
    Started = 2,
    Completed = 3,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Message {
    pub kind: Kind,
    pub error: u32,
    pub sequence: u64,
    pub start: u64,
    pub end: u64,
}
impl Message {
    pub fn encode(self) -> [u8; SIZE] {
        let mut b = [0; SIZE];
        b[..4].copy_from_slice(&(self.kind as u32).to_le_bytes());
        b[4..8].copy_from_slice(&self.error.to_le_bytes());
        for (range, n) in [
            (8..16, self.sequence),
            (16..24, self.start),
            (24..32, self.end),
        ] {
            b[range].copy_from_slice(&n.to_le_bytes());
        }
        b
    }
    pub fn decode(b: &[u8; SIZE]) -> io::Result<Self> {
        let kind = match u32::from_le_bytes(b[..4].try_into().unwrap()) {
            1 => Kind::Request,
            2 => Kind::Started,
            3 => Kind::Completed,
            _ => return Err(invalid("IPC kind")),
        };
        let error = u32::from_le_bytes(b[4..8].try_into().unwrap());
        if error >= 8 {
            return Err(invalid("IPC error"));
        }
        Ok(Self {
            kind,
            error,
            sequence: u64::from_le_bytes(b[8..16].try_into().unwrap()),
            start: u64::from_le_bytes(b[16..24].try_into().unwrap()),
            end: u64::from_le_bytes(b[24..32].try_into().unwrap()),
        })
    }
}
pub struct Endpoint {
    pub stream: UnixStream,
    input: [u8; SIZE],
    used: usize,
    output: Option<([u8; SIZE], usize)>,
}
impl Endpoint {
    pub fn new(stream: UnixStream) -> io::Result<Self> {
        stream.set_nonblocking(true)?;
        Ok(Self {
            stream,
            input: [0; SIZE],
            used: 0,
            output: None,
        })
    }
    pub fn queue(&mut self, message: Message) -> io::Result<()> {
        if self.output.is_some() {
            return Err(invalid("IPC output busy"));
        }
        self.output = Some((message.encode(), 0));
        Ok(())
    }
    pub fn flush(&mut self) -> io::Result<()> {
        while let Some((b, n)) = self.output.as_mut() {
            match self.stream.write(&b[*n..]) {
                Ok(0) => return Err(invalid("IPC write closed")),
                Ok(k) => {
                    *n += k;
                    if *n == SIZE {
                        self.output = None;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
    pub fn receive(&mut self) -> io::Result<Option<Message>> {
        loop {
            match self.stream.read(&mut self.input[self.used..]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "IPC closed/partial frame",
                    ))
                }
                Ok(n) => {
                    self.used += n;
                    if self.used == SIZE {
                        self.used = 0;
                        return Message::decode(&self.input).map(Some);
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                Err(e) => return Err(e),
            }
        }
    }
}
pub fn blocking_read(stream: &mut UnixStream) -> io::Result<Message> {
    let mut b = [0; SIZE];
    stream.read_exact(&mut b)?;
    Message::decode(&b)
}
pub fn blocking_write(stream: &mut UnixStream, m: Message) -> io::Result<()> {
    stream.write_all(&m.encode())
}
pub fn spawn(path: &Path, lock: &File) -> io::Result<(Child, Endpoint)> {
    let (parent, child) = UnixStream::pair()?;
    let endpoint = Endpoint::new(parent)?; // Every fallible setup step precedes spawn.
                                           // Command owns both child-side descriptors; its drop closes retained duplicates,
                                           // including on failure. Only fd0/fd1 are mapped, without pre_exec or FD flag changes.
    let mut command = Command::new(path);
    command.stdin(Stdio::from(std::os::fd::OwnedFd::from(child)));
    command.stdout(Stdio::from(lock.try_clone()?));
    command.stderr(Stdio::null());
    let child = command.spawn()?;
    drop(command);
    Ok((child, endpoint))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn message() -> Message {
        Message {
            kind: Kind::Started,
            error: 0,
            sequence: 5,
            start: 100,
            end: 0,
        }
    }
    #[test]
    fn every_split_and_coalesced_frames() {
        for split in 1..SIZE {
            let (a, mut b) = UnixStream::pair().unwrap();
            let mut e = Endpoint::new(a).unwrap();
            let bytes = message().encode();
            b.write_all(&bytes[..split]).unwrap();
            assert_eq!(e.receive().unwrap(), None);
            b.write_all(&bytes[split..]).unwrap();
            b.write_all(&bytes).unwrap();
            assert_eq!(e.receive().unwrap(), Some(message()));
            assert_eq!(e.receive().unwrap(), Some(message()));
        }
    }
    #[test]
    fn partial_eof_and_malformed_are_errors() {
        let (a, mut b) = UnixStream::pair().unwrap();
        let mut e = Endpoint::new(a).unwrap();
        b.write_all(&[0; 12]).unwrap();
        drop(b);
        assert!(e.receive().is_err());
        let mut bad = message().encode();
        bad[0] = 99;
        assert!(Message::decode(&bad).is_err());
    }
    #[test]
    fn bounded_write_slot() {
        let (a, mut b) = UnixStream::pair().unwrap();
        let mut e = Endpoint::new(a).unwrap();
        e.queue(message()).unwrap();
        assert!(e.queue(message()).is_err());
        e.flush().unwrap();
        assert_eq!(blocking_read(&mut b).unwrap(), message());
    }
}
