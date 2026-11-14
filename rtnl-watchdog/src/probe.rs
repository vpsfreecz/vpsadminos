// SPDX-License-Identifier: GPL-2.0
// This binary owns fd1 as a lock file, never as stdout.
use crate::{
    invalid,
    ipc::{self, Kind, Message},
    sys,
};
use std::io;
pub fn run() -> io::Result<()> {
    if std::env::args_os().count() != 1 {
        return Err(invalid("private helper arguments"));
    }
    let (mut ipc, _lock) = sys::inherited()?;
    let mut route = None;
    loop {
        let request = match ipc::blocking_read(&mut ipc) {
            Ok(m) => m,
            Err(_) => return Ok(()),
        };
        if request.kind != Kind::Request
            || request.sequence == 0
            || request.error != 0
            || request.start != 0
            || request.end != 0
        {
            return Err(invalid("private request"));
        }
        let mut result = Message {
            kind: Kind::Completed,
            error: 0,
            sequence: request.sequence,
            start: 0,
            end: 0,
        };
        if sys::host_namespace().is_err() {
            result.error = 1;
        } else {
            if route.is_none() {
                match sys::Netlink::open() {
                    Ok(r) => route = Some(r),
                    Err(_) => result.error = 2,
                }
            }
            if let Some(route) = route.as_ref() {
                result.start = sys::monotonic()?;
                ipc::blocking_write(
                    &mut ipc,
                    Message {
                        kind: Kind::Started,
                        end: 0,
                        ..result
                    },
                )?;
                let mut sequence = request.sequence as u32;
                if sequence == 0 {
                    sequence = 1;
                }
                if let Err(error) = route.exchange(sequence) {
                    result.error = error;
                }
            }
        }
        result.end = sys::monotonic()?;
        if result.error != 0 {
            route = None;
        }
        ipc::blocking_write(&mut ipc, result)?; // Closed parent does not cancel prior sendmsg.
    }
}
