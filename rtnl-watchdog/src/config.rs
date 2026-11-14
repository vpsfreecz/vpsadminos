// SPDX-License-Identifier: GPL-2.0
use crate::invalid;
use std::{io, path::PathBuf};

pub const HELP: &str = "Usage: rtnl-watchdog [OPTIONS]
Measure RTNL-path request responsiveness without taking container actions.
  --state-file PATH          Write root-owned state JSON atomically
  --metrics-file PATH        Write Prometheus metrics atomically
  --lock-file PATH           Lock shared with the probe helper
  --interval-ms N            Spacing after completion, 100..60000 (1000)
  --threshold-ms N           Distress age, 100..60000 (1000)
  --tick-ms N                State update interval, 50..1000 (250)
  --error-backoff-ms N       Delay after completed errors, 100..3600000 (5000)
The distress threshold must be at least the state update interval.
  --help                     Show help without probing
  --version                  Show version without probing
";

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub state_file: PathBuf,
    pub metrics_file: PathBuf,
    pub lock_file: PathBuf,
    pub interval_ms: u64,
    pub threshold_ms: u64,
    pub tick_ms: u64,
    pub error_backoff_ms: u64,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            state_file: "/run/rtnl-watchdog.json".into(),
            metrics_file: "/run/metrics/rtnl-watchdog.prom".into(),
            lock_file: "/run/rtnl-watchdog.lock".into(),
            interval_ms: 1000,
            threshold_ms: 1000,
            tick_ms: 250,
            error_backoff_ms: 5000,
        }
    }
}
#[derive(Debug)]
pub enum Action {
    Run(Config),
    Help,
    Version,
}

fn clean_path(s: &str) -> bool {
    s.len() < 4096
        && s.starts_with('/')
        && s.len() > 1
        && s[1..]
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
        && !s.as_bytes().contains(&0)
}
pub fn parse(args: &[String]) -> io::Result<Action> {
    let mut c = Config::default();
    let mut i = 0;
    while i < args.len() {
        let (name, inline) = args[i]
            .split_once('=')
            .map_or((args[i].as_str(), None), |(n, v)| (n, Some(v)));
        if inline.is_none() && name == "--help" {
            return Ok(Action::Help);
        }
        if inline.is_none() && name == "--version" {
            return Ok(Action::Version);
        }
        if !matches!(
            name,
            "--state-file"
                | "--metrics-file"
                | "--lock-file"
                | "--interval-ms"
                | "--threshold-ms"
                | "--tick-ms"
                | "--error-backoff-ms"
        ) {
            return Err(invalid("unknown option"));
        }
        let value = if let Some(v) = inline {
            v
        } else {
            i += 1;
            args.get(i).ok_or_else(|| invalid("missing option value"))?
        };
        match name {
            "--state-file" | "--metrics-file" | "--lock-file" => {
                if !clean_path(value) {
                    return Err(invalid("invalid path"));
                }
                let target = match name {
                    "--state-file" => &mut c.state_file,
                    "--metrics-file" => &mut c.metrics_file,
                    _ => &mut c.lock_file,
                };
                *target = value.into();
            }
            _ => {
                if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(invalid("invalid number"));
                }
                let n: u64 = value.parse().map_err(|_| invalid("number overflow"))?;
                let (min, max, target) = match name {
                    "--interval-ms" => (100, 60000, &mut c.interval_ms),
                    "--threshold-ms" => (100, 60000, &mut c.threshold_ms),
                    "--tick-ms" => (50, 1000, &mut c.tick_ms),
                    _ => (100, 3600000, &mut c.error_backoff_ms),
                };
                if n < min || n > max {
                    return Err(invalid("number out of range"));
                }
                *target = n;
            }
        }
        i += 1;
    }
    if c.threshold_ms < c.tick_ms
        || c.state_file == c.metrics_file
        || c.state_file == c.lock_file
        || c.metrics_file == c.lock_file
    {
        return Err(invalid("conflicting options"));
    }
    Ok(Action::Run(c))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_validation() {
        let Action::Run(c) = parse(&[]).unwrap() else {
            panic!()
        };
        assert_eq!(c, Config::default());
        assert_eq!(c.lock_file.to_str().unwrap(), "/run/rtnl-watchdog.lock");
        assert_eq!(c.state_file.to_str().unwrap(), "/run/rtnl-watchdog.json");
        assert_eq!(
            c.metrics_file.to_str().unwrap(),
            "/run/metrics/rtnl-watchdog.prom"
        );
        assert_eq!(
            (c.interval_ms, c.threshold_ms, c.tick_ms, c.error_backoff_ms),
            (1000, 1000, 250, 5000)
        );
        for bad in ["-1", "0", "nan", "60001", "9999999999999999999999"] {
            assert!(parse(&["--threshold-ms".into(), bad.into()]).is_err());
        }
        for path in ["/run/./x", "/run//x", "/run/../x", "relative", "/run/"] {
            assert!(parse(&["--state-file".into(), path.into()]).is_err());
        }
        assert!(parse(&["--state-file=/run/rtnl-watchdog.lock".into()]).is_err());
        assert!(parse(&["--threshold-ms=100".into(), "--tick-ms=250".into()]).is_err());
        assert!(matches!(parse(&["--help".into()]).unwrap(), Action::Help));
    }
}
