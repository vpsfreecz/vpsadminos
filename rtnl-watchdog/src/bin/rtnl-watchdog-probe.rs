// SPDX-License-Identifier: MIT
// FD1 owns the lifetime lock. Never print from this executable.
fn main() {
    if rtnl_watchdog::probe::run().is_err() {
        std::process::exit(1);
    }
}
