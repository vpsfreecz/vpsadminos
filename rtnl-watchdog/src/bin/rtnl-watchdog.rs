// SPDX-License-Identifier: MIT
fn main() {
    if rtnl_watchdog::observer::run().is_err() {
        std::process::exit(1);
    }
}
