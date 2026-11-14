// SPDX-License-Identifier: GPL-2.0
// Linux native-endian netlink fields; no casts of untrusted packet bytes.
use crate::invalid;
use std::io;
pub const REQUEST_LEN: usize = 32;
pub const REPLY_LIMIT: usize = 256;
fn u16_at(b: &[u8], n: usize) -> u16 {
    u16::from_ne_bytes(b[n..n + 2].try_into().unwrap())
}
fn u32_at(b: &[u8], n: usize) -> u32 {
    u32::from_ne_bytes(b[n..n + 4].try_into().unwrap())
}
pub fn request(sequence: u32, port: u32) -> [u8; REQUEST_LEN] {
    let mut b = [0; REQUEST_LEN];
    b[0..4].copy_from_slice(&(REQUEST_LEN as u32).to_ne_bytes());
    b[4..6].copy_from_slice(&18u16.to_ne_bytes()); // RTM_GETLINK
    b[6..8].copy_from_slice(&1u16.to_ne_bytes()); // NLM_F_REQUEST, no dump
    b[8..12].copy_from_slice(&sequence.to_ne_bytes());
    b[12..16].copy_from_slice(&port.to_ne_bytes());
    b // full zeroed ifinfomsg, AF_UNSPEC/index0, no attributes
}
pub fn reply(
    b: &[u8],
    family: u16,
    port: u32,
    groups: u32,
    address_len: usize,
    flags: i32,
    request: &[u8; REQUEST_LEN],
) -> io::Result<()> {
    if family != libc::AF_NETLINK as u16
        || port != 0
        || groups != 0
        || address_len != std::mem::size_of::<libc::sockaddr_nl>()
        || flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0
        || b.len() < 36
        || b.len() > REPLY_LIMIT
    {
        return Err(invalid("invalid netlink envelope"));
    }
    let len = u32_at(b, 0) as usize;
    if len < 36
        || len > b.len()
        || (len + 3) & !3 != b.len()
        || u16_at(b, 4) != 2
        || u32_at(b, 8) != u32_at(request, 8)
        || u16_at(b, 6) & !(0x100 | 0x200) != 0
        || i32::from_ne_bytes(b[16..20].try_into().unwrap()) != -libc::EINVAL
        || b[20..36] != request[..16]
    {
        return Err(invalid("unexpected netlink response"));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn ack(req: &[u8; 32]) -> Vec<u8> {
        let mut b = vec![0; 52];
        b[..4].copy_from_slice(&52u32.to_ne_bytes());
        b[4..6].copy_from_slice(&2u16.to_ne_bytes());
        b[8..12].copy_from_slice(&req[8..12]);
        b[16..20].copy_from_slice(&(-libc::EINVAL).to_ne_bytes());
        b[20..36].copy_from_slice(&req[..16]);
        b
    }
    #[test]
    fn exact_request_and_strict_reply() {
        let req = request(123, 456);
        assert_eq!(&req[16..], &[0; 16]);
        assert_eq!(u32_at(&req, 0), 32);
        assert_eq!(u16_at(&req, 4), 18);
        assert_eq!(u16_at(&req, 6), 1);
        let b = ack(&req);
        let check = |b: &[u8], port, groups, len, flags| {
            reply(b, libc::AF_NETLINK as u16, port, groups, len, flags, &req)
        };
        let len = std::mem::size_of::<libc::sockaddr_nl>();
        check(&b, 0, 0, len, 0).unwrap();
        let mut unaligned = vec![0];
        unaligned.extend(&b);
        check(&unaligned[1..], 0, 0, len, 0).unwrap();
        for n in 0..b.len() {
            assert!(check(&b[..n], 0, 0, len, 0).is_err());
        }
        for offset in [0, 4, 6, 8, 16, 20, 24, 26, 28, 32] {
            let mut bad = b.clone();
            bad[offset] ^= 0x40;
            assert!(check(&bad, 0, 0, len, 0).is_err(), "{offset}");
        }
        assert!(check(&b, 1, 0, len, 0).is_err());
        assert!(check(&b, 0, 1, len, 0).is_err());
        assert!(check(&b, 0, 0, 0, 0).is_err());
        assert!(check(&b, 0, 0, len, libc::MSG_TRUNC).is_err());
    }
}
