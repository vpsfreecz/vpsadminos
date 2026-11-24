// SPDX-License-Identifier: MIT
use crate::{
    config::Config,
    files::{self, Identity},
    invalid,
    state::{reason, Model},
    sys,
};
use std::{
    collections::VecDeque,
    io,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    thread::{self, JoinHandle},
    time::Duration,
};
pub const LINE_LIMIT: usize = 3072;
const RECORD_LIMIT: usize = 256;
const BYTE_LIMIT: usize = 1024 * 1024;
const PROBE_RESERVE: usize = 4;
const CONTROL_RESERVE: usize = 8;
#[derive(Clone, Copy, PartialEq)]
pub enum Pool {
    Probe,
    Control,
}
struct Record {
    bytes: Vec<u8>,
    offset: usize,
    pool: Pool,
}
impl Record {
    fn write_with(
        &mut self,
        mut write: impl FnMut(&[u8]) -> io::Result<usize>,
    ) -> io::Result<bool> {
        match write(&self.bytes[self.offset..]) {
            Ok(0) => Err(io::Error::from(io::ErrorKind::WriteZero)),
            Ok(n) if n <= self.bytes.len() - self.offset => {
                self.offset += n;
                Ok(self.offset == self.bytes.len())
            }
            Ok(_) => Err(invalid("invalid sink count")),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) =>
            {
                Ok(false)
            }
            Err(e) => Err(e),
        }
    }
}
struct Slot {
    model: Option<Model>,
    events: VecDeque<Record>,
    stop: bool,
    records: usize,
    bytes: usize,
    probe: usize,
    control: usize,
    sequence: u64,
    process_epoch: String,
}
impl Default for Slot {
    fn default() -> Self {
        Self {
            model: None,
            events: VecDeque::new(),
            stop: false,
            records: 0,
            bytes: 0,
            probe: 0,
            control: CONTROL_RESERVE,
            sequence: 0,
            process_epoch: String::new(),
        }
    }
}
impl Slot {
    fn reserve_probe(&mut self, resuming: bool) -> bool {
        let extra = PROBE_RESERVE - self.probe;
        if self.control < if resuming { 8 } else { 7 }
            || self.records + self.probe + self.control + extra > RECORD_LIMIT
            || self.bytes + (self.probe + self.control + extra) * LINE_LIMIT > BYTE_LIMIT
        {
            return false;
        }
        self.probe += extra;
        true
    }
    fn complete(&mut self, record: &Record) {
        self.records -= 1;
        self.bytes -= record.bytes.len();
        if record.pool == Pool::Control {
            self.control += 1;
        }
    }
}
#[derive(Default)]
struct Shared {
    slot: Mutex<Slot>,
    changed: Condvar,
    failures: AtomicU64,
}
pub struct Output {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}
impl Output {
    pub fn start(c: &Config) -> io::Result<Self> {
        sys::nonblocking(1)?;
        let shared = Arc::new(Shared::default());
        let own = Arc::clone(&shared);
        let c = c.clone();
        let worker = thread::Builder::new()
            .name("watchdog-output".into())
            .spawn(move || writer(own, c))?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }
    pub fn ready(&self, resuming: bool) -> bool {
        self.shared.slot.lock().unwrap().reserve_probe(resuming)
    }
    pub fn finish_probe(&self) {
        self.shared.slot.lock().unwrap().probe = 0;
    }
    pub fn submit(&self, m: &Model) {
        let mut slot = self.shared.slot.lock().unwrap();
        let mut model = m.clone();
        model.evidence_records = slot.records;
        model.evidence_bytes = slot.bytes;
        model.evidence_reserved = slot.probe + slot.control;
        model.evidence_failures = self.shared.failures.load(Ordering::Relaxed);
        slot.model = Some(model);
        self.shared.changed.notify_one();
    }
    pub fn event(
        &self,
        event: &'static str,
        m: &Model,
        helper: u32,
        now: u64,
        pool: Pool,
    ) -> io::Result<()> {
        let mut slot = self.shared.slot.lock().unwrap();
        if (if pool == Pool::Probe {
            slot.probe
        } else {
            slot.control
        }) == 0
        {
            return Err(invalid("evidence reservation missing"));
        }
        if slot.process_epoch.is_empty() {
            slot.process_epoch = m.epoch.clone();
        }
        let sequence = slot
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("evidence sequence overflow"))?;
        let mut bytes = serde_json::to_vec(&serde_json::json!({
            "evidence_schema":1,"type":"probe_evidence","event":event,"event_sequence":sequence,
            "process_epoch":slot.process_epoch,"boot_id":m.boot,"epoch":m.epoch,
            "observer_pid":std::process::id(),"helper_pid":helper,"probe":m.probe,
            "dispatch_ns":m.dispatch,"started_ns":m.start,"completed_ns":m.end,
            "duration_ns":if m.end >= m.start && m.start != 0 { Some(m.end-m.start) } else { None },
            "received_monotonic_ns":now,"error_code":m.error,"reason":reason(m.error),
            "state":m.state.name(),"coverage_started_ns":m.latency_run.coverage_started_ns,
            "coverage_valid":m.latency_run.valid,"paused":m.evidence_paused
        }))?;
        bytes.push(b'\n');
        if bytes.len() > LINE_LIMIT {
            return Err(invalid("evidence record too large"));
        }
        if pool == Pool::Probe {
            slot.probe -= 1;
        } else {
            slot.control -= 1;
        }
        slot.sequence = sequence;
        slot.records += 1;
        slot.bytes += bytes.len();
        slot.events.push_back(Record {
            bytes,
            offset: 0,
            pool,
        });
        self.shared.changed.notify_one();
        Ok(())
    }
    pub fn stop(mut self) -> io::Result<()> {
        {
            let mut slot = self.shared.slot.lock().unwrap();
            slot.stop = true;
            slot.probe = 0;
            self.shared.changed.notify_one();
        }
        // A blocked local sink deliberately keeps graceful shutdown pending.
        self.worker
            .take()
            .unwrap()
            .join()
            .map_err(|_| invalid("output worker failed"))
    }
}
fn writer(shared: Arc<Shared>, c: Config) {
    let mut state: Option<Identity> = None;
    let mut metrics: Option<Identity> = None;
    let mut pending: Option<Record> = None;
    loop {
        let (model, done) = {
            let mut slot = shared.slot.lock().unwrap();
            if pending.is_none() && slot.events.is_empty() && slot.model.is_none() && !slot.stop {
                slot = shared.changed.wait(slot).unwrap();
            }
            if pending.is_none() {
                pending = slot.events.pop_front();
            }
            (
                slot.model.take(),
                slot.stop && pending.is_none() && slot.events.is_empty(),
            )
        }; // No stdout/filesystem I/O under the publication mutex.
        if let Some(m) = model {
            match m
                .json()
                .and_then(|b| files::write(&c.state_file, &b, 0o600, 0))
            {
                Ok(id) => state = Some(id),
                Err(_) => {
                    shared.failures.fetch_add(1, Ordering::Relaxed);
                }
            }
            match m
                .metrics(shared.failures.load(Ordering::Relaxed))
                .and_then(|b| files::write(&c.metrics_file, &b, 0o644, 0))
            {
                Ok(id) => metrics = Some(id),
                Err(_) => {
                    shared.failures.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        if done {
            break;
        }
        if let Some(record) = pending.as_mut() {
            match record.write_with(sys::write_status) {
                Ok(true) => {
                    let mut slot = shared.slot.lock().unwrap();
                    slot.complete(record);
                    pending = None;
                    shared.changed.notify_all();
                }
                Ok(false) => (),
                Err(_) => {
                    shared.failures.fetch_add(1, Ordering::Relaxed);
                }
            }
            if pending.is_some() {
                let slot = shared.slot.lock().unwrap();
                let _ = shared
                    .changed
                    .wait_timeout(slot, Duration::from_millis(10))
                    .unwrap();
            }
        }
    }
    files::remove(&c.state_file, state, 0);
    files::remove(&c.metrics_file, metrics, 0);
}
#[cfg(test)]
mod tests {
    use super::*;
    fn output() -> Output {
        Output {
            shared: Arc::new(Shared::default()),
            worker: None,
        }
    }
    fn model() -> Model {
        Model::new("01234567-89ab-cdef-0123-456789abcdef", "output").unwrap()
    }
    #[test]
    fn fifo_retains_every_fast_slow_completion_and_bounded_reservations() {
        let o = output();
        let mut m = model();
        for i in 1..=100 {
            assert!(o.ready(false));
            m.probe = i;
            m.start = i;
            m.end = i + if i % 2 == 0 { 2_000_000_000 } else { 1 };
            o.event("completed", &m, 1, i, Pool::Probe).unwrap();
            o.finish_probe();
            o.submit(&m);
        }
        let s = o.shared.slot.lock().unwrap();
        assert_eq!(s.events.len(), 100);
        assert_eq!(s.records, 100);
        for (i, r) in s.events.iter().enumerate() {
            let v: serde_json::Value = serde_json::from_slice(&r.bytes).unwrap();
            assert_eq!(v["probe"], i + 1);
            assert_eq!(v["event_sequence"], i + 1);
            assert!(r.bytes.len() <= LINE_LIMIT);
        }
        assert_eq!(s.model.as_ref().unwrap().probe, 100);
    }
    #[test]
    fn full_queue_stops_probe_admission_but_preserves_control_and_terminal_capacity() {
        let o = output();
        let m = model();
        let mut count = 0;
        while o.ready(false) {
            o.event("started", &m, 1, 1, Pool::Probe).unwrap();
            count += 1;
        }
        assert!(count > 200);
        o.event("paused", &m, 1, 1, Pool::Control).unwrap();
        o.event("completed", &m, 1, 1, Pool::Probe).unwrap();
        o.event("shutdown", &m, 1, 1, Pool::Control).unwrap();
        let s = o.shared.slot.lock().unwrap();
        assert!(s.records + s.probe + s.control <= RECORD_LIMIT);
        assert!(s.bytes + (s.probe + s.control) * LINE_LIMIT <= BYTE_LIMIT);
    }
    #[test]
    fn partial_eagain_error_and_retry_preserve_exact_offset_and_bytes() {
        let mut r = Record {
            bytes: b"ordered record\n".to_vec(),
            offset: 0,
            pool: Pool::Probe,
        };
        let mut got = Vec::new();
        assert!(!r
            .write_with(|b| {
                got.extend_from_slice(&b[..3]);
                Ok(3)
            })
            .unwrap());
        assert_eq!(r.offset, 3);
        assert!(!r
            .write_with(|_| Err(io::ErrorKind::WouldBlock.into()))
            .unwrap());
        assert!(!r
            .write_with(|_| Err(io::ErrorKind::Interrupted.into()))
            .unwrap());
        assert!(r
            .write_with(|_| Err(io::ErrorKind::BrokenPipe.into()))
            .is_err());
        assert_eq!(r.offset, 3);
        assert!(r
            .write_with(|b| {
                got.extend_from_slice(b);
                Ok(b.len())
            })
            .unwrap());
        assert_eq!(got, b"ordered record\n");
    }
    #[test]
    fn real_blocked_nonblocking_pipe_retains_head_until_sink_accepts() {
        use std::io::{Read, Write};
        let (mut read, mut write) = sys::test_pipe();
        let filler = [b'x'; 4096];
        loop {
            match write.write(&filler) {
                Ok(_) => (),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("{e}"),
            }
        }
        let mut record = Record {
            bytes: b"exact completion\n".to_vec(),
            offset: 0,
            pool: Pool::Probe,
        };
        assert!(!record.write_with(|b| write.write(b)).unwrap());
        assert_eq!(record.offset, 0);
        let mut scratch = [0; 8192];
        loop {
            match read.read(&mut scratch) {
                Ok(0) => panic!("unexpected EOF"),
                Ok(_) => (),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("{e}"),
            }
        }
        assert!(record.write_with(|b| write.write(b)).unwrap());
        let n = read.read(&mut scratch).unwrap();
        assert_eq!(&scratch[..n], b"exact completion\n");
    }
    #[test]
    fn widest_fixed_record_fits_and_control_reserve_survives_pause_terminal_shutdown() {
        let o = output();
        let mut m = Model::new("01234567-89ab-cdef-0123-456789abcdef", &"e".repeat(95)).unwrap();
        m.probe = u64::MAX;
        m.dispatch = u64::MAX;
        m.start = 1;
        m.end = u64::MAX;
        m.latency_run.coverage_started_ns = u64::MAX;
        assert!(o.ready(false));
        o.event("completed", &m, u32::MAX, u64::MAX, Pool::Probe)
            .unwrap();
        for event in [
            "observer_started",
            "coverage_lost",
            "helper_reaped",
            "helper_started",
            "evidence_paused",
            "helper_uncertain",
            "helper_reaped",
            "observer_stopping",
        ] {
            o.event(event, &m, u32::MAX, u64::MAX, Pool::Control)
                .unwrap();
        }
        let s = o.shared.slot.lock().unwrap();
        for r in &s.events {
            assert!(r.bytes.len() <= LINE_LIMIT);
        }
        assert!(!s.events.is_empty());
        assert_eq!(s.control, 0);
    }
    #[test]
    fn writer_owned_payload_remains_counted_until_complete() {
        let o = output();
        let m = model();
        assert!(o.ready(false));
        o.event("completed", &m, 1, 1, Pool::Probe).unwrap();
        let mut s = o.shared.slot.lock().unwrap();
        let r = s.events.pop_front().unwrap();
        assert_eq!(s.records, 1);
        assert_eq!(s.bytes, r.bytes.len());
        s.complete(&r);
        assert_eq!(s.records, 0);
        assert_eq!(s.bytes, 0);
    }
}
