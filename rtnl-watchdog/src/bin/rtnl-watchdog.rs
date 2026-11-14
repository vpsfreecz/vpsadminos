// SPDX-License-Identifier: GPL-2.0
fn main() {
    if rtnl_watchdog::observer::run().is_err() {
        std::process::exit(1);
    }
}
