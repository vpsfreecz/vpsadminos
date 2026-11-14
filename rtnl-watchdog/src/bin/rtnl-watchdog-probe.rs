// SPDX-License-Identifier: GPL-2.0
// FD1 owns the lifetime lock. Never print from this executable.
fn main() {
    if rtnl_watchdog::probe::run().is_err() {
        std::process::exit(1);
    }
}
