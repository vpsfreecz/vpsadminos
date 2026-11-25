// SPDX-License-Identifier: MIT
use crate::{
    config::Config,
    invalid,
    ipc::{Kind, Message},
};
use serde_json::json;
use std::{collections::VecDeque, fmt::Write, io};
pub const LIMIT: usize = 4096;
pub const EXPOSURE_LIMIT: usize = 32768;
type Terminal = (u64, u64, Option<u64>, u64, u32, Option<u64>, bool);
pub const BOUNDS: [u64; 28] = [
    1_000_000,
    10_000_000,
    100_000_000,
    250_000_000,
    500_000_000,
    750_000_000,
    1_000_000_000,
    2_000_000_000,
    3_000_000_000,
    4_000_000_000,
    5_000_000_000,
    6_000_000_000,
    7_000_000_000,
    8_000_000_000,
    9_000_000_000,
    10_000_000_000,
    15_000_000_000,
    20_000_000_000,
    25_000_000_000,
    30_000_000_000,
    40_000_000_000,
    50_000_000_000,
    60_000_000_000,
    90_000_000_000,
    120_000_000_000,
    300_000_000_000,
    600_000_000_000,
    u64::MAX,
];
pub const LABELS: [&str; BOUNDS.len()] = [
    "0.001", "0.01", "0.1", "0.25", "0.5", "0.75", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "10", "15", "20", "25", "30", "40", "50", "60", "90", "120", "300", "600", "+Inf",
];
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
    pub buckets: [u64; BOUNDS.len()],
    pub responses: u64,
    pub sum_ns: u64,
    pub overdue: u64,
}
// Control evidence only. Histogram/distress accounting retains its own cutoff.
#[derive(Clone, Debug)]
pub struct LatencyRun {
    pub cutoff_ns: u64,
    pub interval_ns: u64,
    pub tick_ns: u64,
    pub coverage_started_ns: u64,
    pub valid: bool,
    pub first_probe: Option<u64>,
    pub last_probe: Option<u64>,
    pub first_started_ns: Option<u64>,
    pub last_completed_ns: Option<u64>,
    pub slow_count: u64,
}
impl LatencyRun {
    fn new(c: &Config) -> Self {
        Self {
            cutoff_ns: c.latency_threshold_ms * 1_000_000,
            interval_ns: c.interval_ms * 1_000_000,
            tick_ns: c.tick_ms * 1_000_000,
            coverage_started_ns: 0,
            valid: false,
            first_probe: None,
            last_probe: None,
            first_started_ns: None,
            last_completed_ns: None,
            slow_count: 0,
        }
    }
    fn clear(&mut self) {
        self.first_probe = None;
        self.last_probe = None;
        self.first_started_ns = None;
        self.last_completed_ns = None;
        self.slow_count = 0;
    }
    fn reset(&mut self, now: u64) {
        self.clear();
        self.valid = false;
        self.coverage_started_ns = now;
    }
    fn completed(&mut self, probe: u64, start: u64, end: u64) {
        if !self.valid || start < self.coverage_started_ns || end - start <= self.cutoff_ns {
            self.clear();
            return;
        }
        if self.last_probe.and_then(|p| p.checked_add(1)) != Some(probe) {
            self.clear();
        }
        if self.first_probe.is_none() {
            self.first_probe = Some(probe);
            self.first_started_ns = Some(start);
        }
        self.last_probe = Some(probe);
        self.last_completed_ns = Some(end);
        self.slow_count += 1;
    }
}
#[derive(Clone, Debug)]
pub struct Model {
    pub boot: String,
    pub epoch: String,
    pub state: State,
    pub error: u32,
    pub errors: [u64; 8],
    pub history: History,
    pub latency_run: LatencyRun,
    pub evidence_paused: bool,
    pub evidence_draining: bool,
    pub evidence_records: usize,
    pub evidence_bytes: usize,
    pub evidence_reserved: usize,
    pub evidence_failures: u64,
    coverage_seen_ns: u64,
    coverage_clean: bool,
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
    terminals: VecDeque<Terminal>,
    terminal_sequence: u64,
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
            latency_run: LatencyRun::new(&Config::default()),
            evidence_paused: false,
            evidence_draining: false,
            evidence_records: 0,
            evidence_bytes: 0,
            evidence_reserved: 0,
            evidence_failures: 0,
            coverage_seen_ns: 0,
            coverage_clean: false,
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
            terminals: VecDeque::new(),
            terminal_sequence: 0,
        })
    }
    pub fn rebind(&mut self, epoch: &str) -> io::Result<()> {
        let mut fresh = Self::new(&self.boot, epoch)?;
        fresh.history = self.history.clone();
        fresh.errors = self.errors;
        fresh.latency_run = self.latency_run.clone();
        fresh.latency_run.reset(0);
        *self = fresh;
        Ok(())
    }
    pub fn configure(&mut self, c: &Config) {
        self.latency_run = LatencyRun::new(c);
    }
    // Called before draining queued IPC, so a delayed completion cannot fill a
    // coverage gap retrospectively. Restoring pending validity happens only in
    // observe(), after that drain, and never repairs an IPC/error state.
    pub fn pause_evidence(&mut self, paused: bool, now: u64) {
        if self.evidence_paused != paused {
            self.evidence_paused = paused;
            self.latency_run.reset(now);
            self.coverage_clean = false;
            self.coverage_seen_ns = 0;
        }
    }
    pub fn check_coverage(&mut self, now: u64) {
        self.coverage_clean = !self.coverage_lost(now);
        if !self.coverage_clean {
            self.latency_run.reset(now);
        }
        self.coverage_seen_ns = now;
    }
    fn coverage_lost(&self, now: u64) -> bool {
        const GRACE: u64 = 1_000_000_000;
        let gap = self.coverage_seen_ns == 0 || now.saturating_sub(self.coverage_seen_ns) > GRACE;
        let dispatch_late = !self.inflight
            && self.end != 0
            && now
                > self
                    .end
                    .saturating_add(self.latency_run.interval_ns)
                    .saturating_add(GRACE);
        let start_late =
            self.inflight && self.start == 0 && now > self.dispatch.saturating_add(GRACE);
        self.evidence_paused || gap || dispatch_late || start_late
    }
    pub fn fail(&mut self, error: u32) {
        self.error = if (1..8).contains(&error) { error } else { 6 };
        self.errors[self.error as usize] += 1;
        self.state = State::Error;
        self.latency_run.reset(self.coverage_seen_ns);
    }
    pub fn dispatch(&mut self, now: u64) -> io::Result<()> {
        if self.inflight || now == 0 {
            return Err(invalid("pending request"));
        }
        // A scheduling gap since the loop check must be seen before end/start
        // are replaced. This check only invalidates; it cannot rewarm coverage.
        if self.coverage_lost(now) {
            self.check_coverage(now);
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
            if self.coverage_clean && self.start >= self.latency_run.coverage_started_ns {
                self.latency_run.valid = true;
            }
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
        let Some(sequence) = self.terminal_sequence.checked_add(1) else {
            self.fail(6);
            return;
        };
        self.terminal_sequence = sequence;
        self.terminals.push_back((
            self.terminal_sequence,
            self.probe,
            (self.start != 0).then_some(self.start),
            self.end,
            self.error,
            (self.latency_run.coverage_started_ns != 0)
                .then_some(self.latency_run.coverage_started_ns),
            self.latency_run.valid && self.error == 0 && !self.evidence_paused,
        ));
        if self.terminals.len() > 128 {
            self.terminals.pop_front();
        }
        if self.start == 0 || self.end < self.start {
            return;
        }
        let duration = self.end - self.start;
        self.overdue(duration, c);
        if self.state != State::Healthy || self.error != 0 {
            return;
        }
        self.latency_run.completed(self.probe, self.start, self.end);
        self.history.responses += 1;
        self.history.sum_ns += duration;
        for (i, b) in BOUNDS.iter().enumerate() {
            if duration <= *b {
                self.history.buckets[i] += 1;
            }
        }
    }
    pub fn observe(&mut self, now: u64, wall: f64, c: &Config) -> io::Result<()> {
        // Publication may resume long after the loop/IPC check. Never refresh
        // the frame timestamp while retaining proof from before that gap.
        // Do not turn an earlier failed check into a rewarm in this same drain.
        if self.coverage_lost(now) {
            self.check_coverage(now);
        }
        if self.coverage_clean && self.start != 0 && self.error == 0 {
            self.latency_run.valid = true;
        }
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
            "expected_errno":22,"error_code":self.error,
            "log_evidence":{"version":1,"state":if self.evidence_draining { "draining" } else if self.evidence_paused { "backpressured" } else { "ready" }},
            "evidence":{"version":1,"paused":self.evidence_paused,"records":self.evidence_records,
                "bytes":self.evidence_bytes,"reserved_records":self.evidence_reserved,"failures":self.evidence_failures},
            "latency_run": {
                "version":1,"cutoff_ns":self.latency_run.cutoff_ns,
                "interval_ns":self.latency_run.interval_ns,"tick_ns":self.latency_run.tick_ns,
                "coverage_started_ns":optional(self.latency_run.coverage_started_ns),
                "valid":self.latency_run.valid,"first_probe":self.latency_run.first_probe,
                "last_probe":self.latency_run.last_probe,"first_started_ns":self.latency_run.first_started_ns,
                "last_completed_ns":self.latency_run.last_completed_ns,"slow_count":self.latency_run.slow_count
            }
        }))?;
        b.push(b'\n');
        if b.len() > LIMIT {
            return Err(invalid("state too large"));
        }
        Ok(b)
    }
    pub fn exposure_json(&self) -> io::Result<Vec<u8>> {
        let coverage = (self.latency_run.coverage_started_ns != 0)
            .then_some(self.latency_run.coverage_started_ns);
        let valid = self.latency_run.valid
            && self.error == 0
            && !self.evidence_paused
            && !self.evidence_draining;
        let mut bytes = serde_json::to_vec(&json!({
            "schema":1,"boot_id":self.boot,"epoch":self.epoch,"observed_monotonic_ns":self.observed,
            "cutoff_ns":self.latency_run.cutoff_ns,"interval_ns":self.latency_run.interval_ns,
            "coverage_started_ns":coverage,"coverage_valid":valid,
            "paused":self.evidence_paused || self.evidence_draining,
            "first_sequence":self.terminals.front().map_or(0, |r| r.0),
            "last_sequence":self.terminals.back().map_or(0, |r| r.0),"records":self.terminals,
            "pending":if self.inflight { Some(json!({"probe":self.probe,
                "started_ns_or_null":(self.start != 0).then_some(self.start),
                "coverage_started_ns_or_null":coverage,"coverage_valid":valid})) } else { None }
        }))?;
        bytes.push(b'\n');
        if bytes.len() > EXPOSURE_LIMIT {
            return Err(invalid("exposure cache too large"));
        }
        Ok(bytes)
    }
    pub fn metrics(&self, failures: u64) -> io::Result<Vec<u8>> {
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
        writeln!(s,"rtnl_watchdog_available {}\nrtnl_watchdog_snapshot_timestamp_seconds {:.9}\nrtnl_watchdog_output_errors_total {}",u8::from(available),self.wall,failures).unwrap();
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
    fn covered_until(m: &mut Model, end: u64, c: &Config) {
        while m.coverage_seen_ns < end {
            let now = (m.coverage_seen_ns + 250_000_000).min(end);
            m.check_coverage(now);
            m.observe(now, 1., c).unwrap();
        }
    }
    fn response(m: &mut Model, start: u64, duration: u64, c: &Config) {
        covered_until(m, start, c);
        m.dispatch(start).unwrap();
        m.apply(started(m, start), start, 1.).unwrap();
        covered_until(m, start + duration, c);
        m.apply(done(m, start + duration, 0), start + duration, 1.)
            .unwrap();
        m.completed(c);
    }
    #[test]
    fn consecutive_latency_run_is_completion_driven_and_fast_resets_are_not_hidden() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "latency").unwrap();
        m.check_coverage(1);
        response(&mut m, 1_000_000_000, 15_000_000_000, &c);
        assert_eq!(m.latency_run.slow_count, 1);
        response(&mut m, 17_000_000_000, 14_999_000_000, &c);
        let run = &m.latency_run;
        assert_eq!(
            run.last_completed_ns.unwrap() - run.first_started_ns.unwrap(),
            30_999_000_000
        );
        assert_eq!(run.slow_count, 2);
        let first = run.first_probe;
        // Equality is fast, including when both it and another slow result
        // occur before any consumer/output submission.
        response(
            &mut m,
            32_999_000_000,
            c.latency_threshold_ms * 1_000_000,
            &c,
        );
        assert_eq!(m.latency_run.slow_count, 0);
        response(&mut m, 34_999_000_000, 2_000_000_000, &c);
        assert_ne!(m.latency_run.first_probe, first);
        assert_eq!(m.latency_run.slow_count, 1);
        let end = m.latency_run.last_completed_ns;
        covered_until(&mut m, 37_999_000_000, &c);
        m.dispatch(37_999_000_000).unwrap();
        m.apply(started(&m, 37_999_000_000), 37_999_000_000, 1.)
            .unwrap();
        covered_until(&mut m, 70_000_000_000, &c);
        assert_eq!(m.latency_run.last_completed_ns, end);
        assert!(m.latency_run.valid);
        assert!(m
            .apply(done(&m, 70_000_000_000, 0), 70_000_000_000, 1.)
            .is_ok());
        m.completed(&c);
        let count = m.latency_run.slow_count;
        m.completed(&c);
        assert_eq!(m.latency_run.slow_count, count);
    }
    #[test]
    fn latency_span_reaches_thirty_only_on_the_boundary_completion() {
        let c = Config::default();
        for (duration, span) in [
            (14_999_000_000, 29_999_000_000),
            (15_000_000_000, 30_000_000_000),
        ] {
            let mut m = Model::new(BOOT, "span").unwrap();
            m.check_coverage(1);
            response(&mut m, 1_000_000_000, 14_000_000_000, &c);
            response(&mut m, 16_000_000_000, duration, &c);
            assert_eq!(
                m.latency_run.last_completed_ns.unwrap() - m.latency_run.first_started_ns.unwrap(),
                span
            );
            let json: serde_json::Value = serde_json::from_slice(&m.json().unwrap()).unwrap();
            assert_eq!(json["latency_run"]["slow_count"], 2);
        }
    }
    #[test]
    fn coverage_gap_invalidates_queued_completion_and_rewarms_announced_pending() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "coverage").unwrap();
        m.check_coverage(1);
        response(&mut m, 1_000_000_000, 2_000_000_000, &c);
        m.check_coverage(5_000_000_001); // Missed dispatch/loop deadline.
        assert!(!m.latency_run.valid);
        assert_eq!(m.latency_run.slow_count, 0);
        m.dispatch(5_000_000_001).unwrap();
        m.check_coverage(5_250_000_001);
        m.apply(started(&m, 5_000_000_001), 5_250_000_001, 1.)
            .unwrap();
        m.check_coverage(40_000_000_000); // Observer stalled before queued IPC.
        assert!(!m.latency_run.valid);
        m.observe(40_000_000_000, 1., &c).unwrap();
        assert!(!m.latency_run.valid);
        covered_until(&mut m, 40_250_000_000, &c);
        assert!(m.latency_run.valid);
        assert_eq!(m.latency_run.coverage_started_ns, 40_000_000_000);
        assert!(m
            .apply(done(&m, 40_250_000_000, 0), 40_250_000_000, 1.)
            .is_ok());
        m.completed(&c); // Its pre-boundary start cannot seed a slow run.
        assert_eq!(m.latency_run.slow_count, 0);
        m.fail(6);
        covered_until(&mut m, 40_500_000_000, &c);
        assert!(!m.latency_run.valid); // Heartbeats cannot repair IPC error.
        m.rebind("next-helper").unwrap();
        assert!(!m.latency_run.valid);
        assert_eq!(m.latency_run.slow_count, 0);
    }
    #[test]
    fn scheduling_and_start_grace_are_bounded_separately_from_latency_cutoff() {
        let c = Config {
            latency_threshold_ms: 1,
            ..Config::default()
        };
        let mut m = Model::new(BOOT, "deadlines").unwrap();
        m.configure(&c);
        m.check_coverage(1);
        response(&mut m, 1_000_000_000, 2_000_000, &c);
        covered_until(&mut m, 3_002_000_000, &c); // Exactly 1s grace is allowed.
        assert!(m.latency_run.valid);
        m.check_coverage(3_002_000_001);
        assert!(!m.latency_run.valid);
        m.dispatch(3_002_000_001).unwrap();
        covered_until(&mut m, 4_002_000_002, &c);
        assert!(!m.latency_run.valid); // Missing Started is never pending proof.
        assert!(m.latency_run.first_probe.is_none());
    }
    #[test]
    fn publication_rechecks_intra_iteration_gaps_without_immediate_rewarm() {
        let c = Config::default();
        for over in [0, 1] {
            let mut m = Model::new(BOOT, "publication-gap").unwrap();
            m.check_coverage(1);
            response(&mut m, 1_000_000_000, 2_000_000_000, &c);
            covered_until(&mut m, 4_000_000_000, &c);
            m.dispatch(4_000_000_000).unwrap();
            m.apply(started(&m, 4_000_000_000), 4_000_000_000, 1.)
                .unwrap();
            m.check_coverage(4_250_000_000);
            let published = 5_250_000_000 + over;
            m.observe(published, 1., &c).unwrap();
            assert_eq!(m.observed, published);
            assert_eq!(m.latency_run.valid, over == 0);
            if over == 0 {
                assert_eq!(m.latency_run.slow_count, 1);
            } else {
                assert_eq!(m.latency_run.slow_count, 0);
                assert_eq!(m.latency_run.coverage_started_ns, published);
                m.observe(published, 1., &c).unwrap();
                assert!(!m.latency_run.valid);
                m.check_coverage(published + 250_000_000);
                m.observe(published + 250_000_000, 1., &c).unwrap();
                assert!(m.latency_run.valid);
                assert_eq!(m.latency_run.coverage_started_ns, published);
            }
        }
    }
    #[test]
    fn dispatch_rechecks_gap_before_replacing_the_completed_request() {
        let c = Config::default();
        for over in [0, 1] {
            let mut m = Model::new(BOOT, "dispatch-gap").unwrap();
            m.check_coverage(1);
            response(&mut m, 1_000_000_000, 2_000_000_000, &c);
            m.check_coverage(4_000_000_000);
            let dispatched = 5_000_000_000 + over;
            m.dispatch(dispatched).unwrap();
            m.observe(dispatched, 1., &c).unwrap();
            assert_eq!(m.latency_run.valid, over == 0);
            assert_eq!(m.latency_run.slow_count, if over == 0 { 1 } else { 0 });
            if over != 0 {
                assert_eq!(m.latency_run.coverage_started_ns, dispatched);
                m.check_coverage(dispatched + 250_000_000);
                m.observe(dispatched + 250_000_000, 1., &c).unwrap();
                assert!(!m.latency_run.valid); // No Started, no pending proof.
            }
        }
    }
    #[test]
    fn first_pending_unknown_distress_and_recovery() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "one").unwrap();
        m.dispatch(1_000_000_000).unwrap();
        m.observe(9_000_000_000, 9., &c).unwrap();
        assert_eq!(m.state, State::Pending);
        assert!(!String::from_utf8(m.metrics(0).unwrap())
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
        let finite = BOUNDS.len() - 1;
        for (i, b) in BOUNDS[..finite].iter().enumerate() {
            m.dispatch(now).unwrap();
            m.apply(started(&m, now), now, 1.).unwrap();
            m.apply(done(&m, now + b, 0), now + b, 20.).unwrap();
            m.completed(&c);
            m.completed(&c);
            sum += b;
            assert_eq!(m.history.responses, i as u64 + 1);
            assert_eq!(m.history.sum_ns, sum);
            for (j, count) in m.history.buckets.iter().enumerate() {
                assert_eq!(*count, (j.min(i) + 1) as u64);
            }
            now += b + 1;
        }
        // A response just beyond the largest finite bound only adds to +Inf.
        let duration = BOUNDS[finite - 1] + 1;
        m.dispatch(now).unwrap();
        m.apply(started(&m, now), now, 1.).unwrap();
        m.apply(done(&m, now + duration, 0), now + duration, 20.)
            .unwrap();
        m.completed(&c);
        sum += duration;
        assert_eq!(m.history.sum_ns, sum);
        assert_eq!(m.history.responses, BOUNDS.len() as u64);
        for (i, count) in m.history.buckets.iter().enumerate() {
            assert_eq!(*count, i as u64 + 1);
        }
        now += duration + 1;
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
        let metrics = String::from_utf8(m.metrics(5).unwrap()).unwrap();
        assert!(metrics.contains("rtnl_watchdog_output_errors_total 5\n"));
        assert!(metrics.contains(&format!(
            "rtnl_watchdog_response_duration_seconds_count {responses}\n"
        )));
        for (label, count) in LABELS.iter().zip(m.history.buckets) {
            assert!(metrics.contains(&format!(
                "rtnl_watchdog_response_duration_seconds_bucket{{le=\"{label}\"}} {count}\n"
            )));
        }
        assert!(!metrics.contains("\nrtnl_watchdog_last_probe_duration_seconds "));
        assert!(m.json().unwrap().len() < LIMIT);
    }
    #[test]
    fn evidence_pause_invalidates_pending_and_retains_completion_without_repairing_errors() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "pressure").unwrap();
        m.check_coverage(1);
        m.dispatch(2).unwrap();
        m.check_coverage(3);
        m.apply(started(&m, 3), 3, 1.).unwrap();
        assert!(m.latency_run.valid);
        m.pause_evidence(true, 4);
        m.check_coverage(5);
        m.observe(5, 1., &c).unwrap();
        assert!(!m.latency_run.valid);
        assert!(m.inflight);
        assert!(m.apply(done(&m, 6, 0), 6, 1.).unwrap());
        m.completed(&c);
        assert_eq!(m.history.responses, 1);
        assert!(!m.latency_run.valid);
        m.pause_evidence(false, 7);
        m.check_coverage(7);
        m.observe(7, 1., &c).unwrap();
        assert!(!m.latency_run.valid); // First resumed tick seeds only.
        m.fail(6);
        m.check_coverage(8);
        m.observe(8, 1., &c).unwrap();
        assert!(!m.latency_run.valid);
        assert_eq!(m.error, 6);
        let mut missing = Model::new(BOOT, "missing").unwrap();
        missing.check_coverage(1);
        missing.dispatch(2).unwrap();
        missing.pause_evidence(true, 3);
        missing.pause_evidence(false, 4);
        missing.check_coverage(4);
        missing.observe(4, 1., &c).unwrap();
        missing.check_coverage(5);
        missing.observe(5, 1., &c).unwrap();
        assert!(!missing.latency_run.valid);
        assert_eq!(missing.start, 0);
    }
    #[test]
    fn ordered_log_capability_is_additive_and_reports_actual_pipeline_state() {
        let mut m = Model::new(BOOT, "logging").unwrap();
        for (paused, draining, state) in [
            (false, false, "ready"),
            (true, false, "backpressured"),
            (true, true, "draining"),
        ] {
            m.evidence_paused = paused;
            m.evidence_draining = draining;
            let value: serde_json::Value = serde_json::from_slice(&m.json().unwrap()).unwrap();
            assert_eq!(value["schema"], 1);
            assert_eq!(value["latency_run"]["version"], 1);
            assert_eq!(value["log_evidence"], json!({"version":1,"state":state}));
        }
    }
    #[test]
    fn exposure_retains_every_terminal_once_and_resets_on_rebind() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "terminals").unwrap();
        for probe in 1..=130u64 {
            let start = probe * 1_000_000_000;
            m.check_coverage(start);
            m.dispatch(start).unwrap();
            m.apply(started(&m, start), start, 1.).unwrap();
            m.apply(
                done(&m, start + 1, if probe == 129 { 5 } else { 0 }),
                start + 1,
                1.,
            )
            .unwrap();
            m.completed(&c);
            m.completed(&c);
        }
        let j: serde_json::Value = serde_json::from_slice(&m.exposure_json().unwrap()).unwrap();
        assert_eq!(j["records"].as_array().unwrap().len(), 128);
        assert_eq!(j["first_sequence"], 3);
        assert_eq!(j["last_sequence"], 130);
        assert_eq!(j["records"][126][4], 5); // Error is ordered between fast responses.
        assert_eq!(j["records"][126][6], false);
        assert_eq!(j["records"][127][1], 130);
        m.rebind("next").unwrap();
        assert!(m.terminals.is_empty());
        assert_eq!(m.terminal_sequence, 0);
        assert!(m.exposure_json().unwrap().len() <= EXPOSURE_LIMIT);
    }
    #[test]
    fn exposure_pending_reports_only_the_observed_coverage_suffix() {
        let c = Config::default();
        let mut m = Model::new(BOOT, "suffix").unwrap();
        m.check_coverage(1);
        m.dispatch(2).unwrap();
        m.apply(started(&m, 3), 3, 1.).unwrap();
        m.check_coverage(4_000_000_000);
        m.observe(4_000_000_000, 4., &c).unwrap();
        assert!(!m.latency_run.valid);
        m.check_coverage(4_250_000_000);
        m.observe(4_250_000_000, 4.25, &c).unwrap();
        let j: serde_json::Value = serde_json::from_slice(&m.exposure_json().unwrap()).unwrap();
        assert_eq!(j["pending"]["started_ns_or_null"], 3);
        assert_eq!(
            j["pending"]["coverage_started_ns_or_null"],
            4_000_000_000u64
        );
        assert_eq!(j["pending"]["coverage_valid"], true);
        m.pause_evidence(true, 4_250_000_001);
        let j: serde_json::Value = serde_json::from_slice(&m.exposure_json().unwrap()).unwrap();
        assert_eq!(j["coverage_valid"], false);
        assert_eq!(j["paused"], true);
    }
    #[test]
    fn maximum_exposure_cache_fits_with_128_widest_terminal_tuples() {
        let mut m = Model::new(BOOT, &"e".repeat(95)).unwrap();
        m.observed = u64::MAX;
        m.probe = u64::MAX;
        m.start = u64::MAX;
        m.inflight = true;
        m.latency_run.cutoff_ns = u64::MAX;
        m.latency_run.interval_ns = u64::MAX;
        m.latency_run.coverage_started_ns = u64::MAX;
        for _ in 0..128 {
            m.terminals.push_back((
                u64::MAX,
                u64::MAX,
                Some(u64::MAX),
                u64::MAX,
                7,
                Some(u64::MAX),
                false,
            ));
        }
        let bytes = m.exposure_json().unwrap();
        assert!(bytes.len() <= EXPOSURE_LIMIT);
        assert_eq!(bytes.last(), Some(&b'\n'));
        assert!(m.json().unwrap().len() <= LIMIT);
    }
    #[test]
    fn maximum_metrics_frame_fits_limit() {
        let mut m = Model::new(BOOT, &"e".repeat(95)).unwrap();
        m.state = State::Distressed;
        m.inflight = true;
        m.sequence = u64::MAX;
        m.probe = u64::MAX;
        m.dispatch = u64::MAX;
        m.start = 1;
        m.end = u64::MAX;
        m.observed = u64::MAX;
        m.wall = f64::MAX;
        m.duration = Some(u64::MAX);
        m.success = Some(f64::MAX);
        m.errors[1] = u64::MAX;
        m.history.buckets.fill(u64::MAX);
        m.history.responses = u64::MAX;
        m.history.sum_ns = u64::MAX;
        m.history.overdue = u64::MAX;
        m.latency_run.coverage_started_ns = u64::MAX;
        m.latency_run.first_probe = Some(u64::MAX);
        m.latency_run.last_probe = Some(u64::MAX);
        m.latency_run.first_started_ns = Some(u64::MAX);
        m.latency_run.last_completed_ns = Some(u64::MAX);
        m.latency_run.slow_count = u64::MAX;
        m.latency_run.valid = true;
        m.evidence_paused = true;
        m.evidence_records = usize::MAX;
        m.evidence_bytes = usize::MAX;
        m.evidence_reserved = usize::MAX;
        m.evidence_failures = u64::MAX;
        assert!(m.metrics(u64::MAX).unwrap().len() <= LIMIT);
        assert!(m.json().unwrap().len() <= LIMIT);
    }
}
