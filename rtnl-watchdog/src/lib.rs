// SPDX-License-Identifier: GPL-2.0
#![deny(unsafe_code)]
pub mod config;
pub mod files;
pub mod ipc;
pub mod observer;
pub mod output;
pub mod probe;
pub mod state;
#[allow(unsafe_code)]
pub mod sys;
pub mod wire;

pub fn invalid(message: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message)
}
