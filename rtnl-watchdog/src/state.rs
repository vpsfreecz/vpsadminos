// SPDX-License-Identifier: GPL-2.0
use crate::{
    config::Config,
    invalid,
    ipc::{Kind, Message},
};
use serde_json::json;
use std::{fmt::Write, io};
pub const LIMIT: usize = 4096;
pub const BOUNDS: [u64; 8] = [
    1_000_000,
    10_000_000,
    100_000_000,
    500_000_000,
    1_000_000_000,
    5_000_000_000,
    10_000_000_000,
    u64::MAX,
];
pub const LABELS: [&str; 8] = ["0.001", "0.01", "0.1", "0.5", "1", "5", "10", "+Inf"];
pub fn reason(error: u32) -> &'static str {
    [
        "none",
        "namespace",
        "socket",
        "send",
        "receive",
        "reply",
        "ipc",
        "child",
    ]
    .get(error as usize)
    .copied()
    .unwrap_or("ipc")
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum State {
    Starting,
    Pending,
    Distressed,
    Healthy,
    Error,
}
impl State {
    pub fn name(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Pending => "pending",
            Self::Distressed => "distressed",
            Self::Healthy => "healthy",
            Self::Error => "error",
        }
    }
}
#[derive(Clone, Default, Debug)]
pub struct History {
    pub buckets: [u64; 8],
    pub responses: u64,
    pub sum_ns: u64,
    pub overdue: u64,
}
#[derive(Clone, Debug)]
pub struct Model {
    pub boot: String,
    pub epoch: String,
    pub state: State,
    pub error: u32,
    pub errors: [u64; 8],
    pub history: History,
    pub sequence: u64,
    pub observed: u64,
    pub wall: f64,
    pub probe: u64,
    pub dispatch: u64,
    pub start: u64,
    pub end: u64,
    pub inflight: bool,
    pub duration: Option<u64>,
    pub success: Option<f64>,
    overdue_counted: bool,
    completion_counted: bool,
}
impl Model {
    pub fn new(boot: &str, epoch: &str) -> io::Result<Self> {
        if boot.len() != 36
            || !boot.bytes().enumerate().all(|(i, b)| {
                if [8, 13, 18, 23].contains(&i) {
                    b == b'-'
                } else {
                    b.is_ascii_hexdigit()
                }
            })
            || epoch.is_empty()
            || epoch.len() >= 96
            || !epoch
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(invalid("invalid epoch/boot"));
        }
        Ok(Self {
            boot: boot.into(),
            epoch: epoch.into(),
            state: State::Starting,
            error: 0,
            errors: [0; 8],
            history: History::default(),
            sequence: 0,
            observed: 0,
            wall: 0.,
            probe: 0,
            dispatch: 0,
            start: 0,
            end: 0,
            inflight: false,
            duration: None,
            success: None,
            overdue_counted: false,
            completion_counted: false,
        })
    }
    pub fn rebind(&mut self, epoch: &str) -> io::Result<()> {
        let mut fresh = Self::new(&self.boot, epoch)?;
        fresh.history = self.history.clone();
        fresh.errors = self.errors;
        *self = fresh;
        Ok(())
    }
    pub fn fail(&mut self, error: u32) {
        self.error = if (1..8).contains(&error) { error } else { 6 };
        self.errors[self.error as usize] += 1;
        self.state = State::Error;
    }
    pub fn dispatch(&mut self, now: u64) -> io::Result<()> {
        if self.inflight || now == 0 {
            return Err(invalid("pending request"));
        }
        self.probe = self
            .probe
            .checked_add(1)
            .ok_or_else(|| invalid("sequence overflow"))?;
        self.inflight = true;
        self.dispatch = now;
        self.start = 0;
        self.end = 0;
        self.error = 0;
        self.state = State::Pending;
        self.overdue_counted = false;
        self.completion_counted = false;
        Ok(())
    }
    pub fn apply(&mut self, m: Message, now: u64, wall: f64) -> io::Result<bool> {
        let valid =
            self.inflight && self.state != State::Error && m.sequence == self.probe && m.error < 8;
        if valid
            && m.kind == Kind::Started
            && self.start == 0
            && m.error == 0
            && m.end == 0
            && m.start >= self.dispatch
            && m.start <= now
        {
            self.start = m.start;
            return Ok(false);
        }
        if valid
            && m.kind == Kind::Completed
            && m.end >= self.dispatch
            && m.end <= now
            && m.start == self.start
            && (self.start != 0 || m.error == 1 || m.error == 2)
            && (self.start == 0 || m.end >= self.start)
        {
            self.inflight = false;
            self.end = m.end;
            if m.error != 0 {
                self.fail(m.error);
            } else {
                self.duration = Some(m.end - self.start);
                self.success = Some(wall - (now - m.end) as f64 / 1e9);
                self.state = State::Healthy;
                self.error = 0;
            }
            return Ok(true);
        }
        self.fail(6);
        Err(invalid("invalid IPC transition")) // Unknown effects keep inflight reserved.
    }
    fn overdue(&mut self, age: u64, c: &Config) {
        if !self.overdue_counted && age >= c.threshold_ms * 1_000_000 {
            self.history.overdue += 1;
            self.overdue_counted = true;
        }
    }
    pub fn completed(&mut self, c: &Config) {
        if self.completion_counted || self.inflight || self.end == 0 {
            return;
        }
        self.completion_counted = true;
        if self.start == 0 || self.end < self.start {
            return;
        }
        let duration = self.end - self.start;
        self.overdue(duration, c);
        if self.state != State::Healthy || self.error != 0 {
            return;
        }
        self.history.responses += 1;
        self.history.sum_ns += duration;
        for (i, b) in BOUNDS.iter().enumerate() {
            if duration <= *b {
                self.history.buckets[i] += 1;
            }
        }
    }
    pub fn observe(&mut self, now: u64, wall: f64, c: &Config) -> io::Result<()> {
        self.observed = now;
        self.wall = wall;
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("frame sequence overflow"))?;
        if self.inflight && self.state != State::Error {
            if self.start != 0 && now >= self.start {
                self.overdue(now - self.start, c);
            }
            self.state = if self.start != 0
                && now >= self.start
                && now - self.start >= c.threshold_ms * 1_000_000
            {
                State::Distressed
            } else {
                State::Pending
            };
        }
        Ok(())
    }
    pub fn json(&self) -> io::Result<Vec<u8>> {
        let optional = |v| if v == 0 { None } else { Some(v) };
        let mut b = serde_json::to_vec(&json!({
            "schema":1,"boot_id":self.boot,"epoch":self.epoch,"sequence":self.sequence,
            "observed_monotonic_ns":self.observed,"probe_sequence":self.probe,"state":self.state.name(),
            "dispatch_monotonic_ns":optional(self.dispatch),"started_monotonic_ns":optional(self.start),
            "completed_monotonic_ns":optional(self.end),"last_duration_ns":self.duration,
            "expected_errno":22,"error_code":self.error
        }))?;
        b.push(b'\n');
        if b.len() > LIMIT {
            return Err(invalid("state too large"));
        }
        Ok(b)
    }
    pub fn metrics(&self, drops: u64, failures: u64) -> io::Result<Vec<u8>> {
        let available = self.state == State::Healthy
            || (self.inflight && self.start != 0 && self.state != State::Error);
        let mut s = String::new();
        for n in [
            "available",
            "distress",
            "pending_age_seconds",
            "last_probe_duration_seconds",
            "last_success_timestamp_seconds",
            "snapshot_timestamp_seconds",
        ] {
            writeln!(s, "# TYPE rtnl_watchdog_{n} gauge").unwrap();
        }
        for n in [
            "errors_total",
            "output_errors_total",
            "overdue_probes_total",
        ] {
            writeln!(s, "# TYPE rtnl_watchdog_{n} counter").unwrap();
        }
        writeln!(s,"rtnl_watchdog_available {}\nrtnl_watchdog_snapshot_timestamp_seconds {:.9}\nrtnl_watchdog_output_errors_total {}",u8::from(available),self.wall,drops+failures).unwrap();
        if available {
            writeln!(
                s,
                "rtnl_watchdog_distress {}",
                u8::from(self.state == State::Distressed)
            )
            .unwrap();
        }
        if !self.inflight || self.start != 0 {
            let age = if self.inflight {
                self.observed.saturating_sub(self.start)
            } else {
                0
            };
            writeln!(
                s,
                "rtnl_watchdog_pending_age_seconds {:.9}",
                age as f64 / 1e9
            )
            .unwrap();
        }
        if let Some(d) = self.duration {
            writeln!(
                s,
                "rtnl_watchdog_last_probe_duration_seconds {:.9}",
                d as f64 / 1e9
            )
            .unwrap();
        }
        if let Some(t) = self.success {
            writeln!(s, "rtnl_watchdog_last_success_timestamp_seconds {t:.9}").unwrap();
        }
        writeln!(s,"rtnl_watchdog_errors_total {}\nrtnl_watchdog_overdue_probes_total {}\n# TYPE rtnl_watchdog_response_duration_seconds histogram",self.errors.iter().sum::<u64>(),self.history.overdue).unwrap();
        for (i, label) in LABELS.iter().enumerate() {
            writeln!(
                s,
                "rtnl_watchdog_response_duration_seconds_bucket{{le=\"{label}\"}} {}",
                self.history.buckets[i]
            )
            .unwrap();
        }
        writeln!(s,"rtnl_watchdog_response_duration_seconds_sum {:.9}\nrtnl_watchdog_response_duration_seconds_count {}",self.history.sum_ns as f64/1e9,self.history.responses).unwrap();
        if s.len() > LIMIT {
            return Err(invalid("metrics too large"));
        }
        Ok(s.into_bytes())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    const BOOT: &str = "01234567-89ab-cdef-0123-456789abcdef";
    fn started(m: &Model, t: u64) -> Message {
        Message {
            kind: Kind::Started,
            error: 0,
            sequence: m.probe,
            start: t,
            end: 0,
        }
    }
    fn done(m: &Model, t: u64, error: u32) -> Message {
        Message {
            kind: Kind::Completed,
            error,
            sequence: m.probe,
            start: m.start,
            end: t,
        }
    }
    #[test]
    fn first_pending_unknown_distress_and_recovery() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "one").unwrap();
        m.dispatch(1_000_000_000).unwrap();
        m.observe(9_000_000_000, 9., &c).unwrap();
        assert_eq!(m.state, State::Pending);
        assert!(!String::from_utf8(m.metrics(0, 0).unwrap())
            .unwrap()
            .contains("\nrtnl_watchdog_distress "));
        m.apply(started(&m, 9_000_000_000), 9_000_000_000, 9.)
            .unwrap();
        for t in [10_000_000_000, 11_000_000_000, 12_000_000_000] {
            m.observe(t, 12., &c).unwrap();
            assert_eq!(m.state, State::Distressed);
            assert!(m.dispatch(t).is_err());
        }
        assert_eq!(m.history.overdue, 1);
        assert!(m.success.is_none());
        m.apply(done(&m, 12_000_000_000, 0), 12_000_000_000, 12.)
            .unwrap();
        m.completed(&c);
        m.completed(&c);
        assert_eq!(m.state, State::Healthy);
        assert_eq!(m.duration, Some(3_000_000_000));
        assert_eq!(m.history.responses, 1);
        m.dispatch(13_000_000_000).unwrap();
        let j: serde_json::Value = serde_json::from_slice(&m.json().unwrap()).unwrap();
        assert_eq!(j["last_duration_ns"], 3_000_000_000u64);
        assert!(j["started_monotonic_ns"].is_null());
        let bad = Message {
            sequence: 999,
            ..started(&m, 14_000_000_000)
        };
        assert!(m.apply(bad, 14_000_000_000, 14.).is_err());
        assert!(m.inflight);
        assert!(m.dispatch(15_000_000_000).is_err());
    }
    #[test]
    fn boundaries_late_errors_missing_start_and_rebind() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "metrics").unwrap();
        let mut now = 1_000_000_000;
        let mut sum = 0;
        for (i, b) in BOUNDS[..7].iter().enumerate() {
            m.dispatch(now).unwrap();
            m.apply(started(&m, now), now, 1.).unwrap();
            m.apply(done(&m, now + b, 0), now + b, 20.).unwrap();
            m.completed(&c);
            m.completed(&c);
            sum += b;
            assert_eq!(m.history.responses, i as u64 + 1);
            assert_eq!(m.history.sum_ns, sum);
            for j in 0..8 {
                assert_eq!(m.history.buckets[j], (j.min(i) + 1) as u64);
            }
            now += b + 1;
        }
        let responses = m.history.responses;
        let overdue = m.history.overdue;
        m.dispatch(now).unwrap();
        m.apply(started(&m, now), now, 20.).unwrap();
        m.apply(done(&m, now + 2_000_000_000, 5), now + 2_000_000_000, 22.)
            .unwrap();
        m.completed(&c);
        assert_eq!(m.history.overdue, overdue + 1);
        assert_eq!(m.history.responses, responses);
        m.dispatch(now + 3_000_000_000).unwrap();
        m.apply(done(&m, now + 4_000_000_000, 1), now + 4_000_000_000, 24.)
            .unwrap();
        m.completed(&c);
        assert_eq!(m.history.overdue, overdue + 1);
        m.rebind("second-helper").unwrap();
        assert_eq!(m.history.responses, responses);
        assert!(m.duration.is_none());
        let metrics = String::from_utf8(m.metrics(2, 3).unwrap()).unwrap();
        assert!(metrics.contains("rtnl_watchdog_output_errors_total 5\n"));
        assert!(metrics.contains("rtnl_watchdog_response_duration_seconds_count 7\n"));
        assert!(!metrics.contains("\nrtnl_watchdog_last_probe_duration_seconds "));
        assert!(m.json().unwrap().len() < LIMIT);
    }
}
