// SPDX-License-Identifier: MIT
use crate::{
    config::Config,
    files::{self, Identity},
    invalid,
    state::{reason, Model},
    sys,
};
use std::{
    io,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Condvar, Mutex,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
#[derive(Default)]
struct Slot {
    model: Option<Model>,
    event: Option<Vec<u8>>,
    stop: bool,
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
        let config = c.clone();
        let worker = thread::Builder::new()
            .name("watchdog-output".into())
            .spawn(move || writer(own, config))?;
        Ok(Self {
            shared,
            worker: Some(worker),
        })
    }
    pub fn submit(&self, m: &Model) {
        let mut slot = self.shared.slot.lock().unwrap();
        slot.model = Some(m.clone());
        self.shared.changed.notify_one();
    }
    pub fn event(&self, event: &str, m: &Model, helper: u32) {
        let b = serde_json::to_vec(
            &serde_json::json!({"schema":1,"type":"status","event":event,
            "epoch":m.epoch,"observer_pid":std::process::id(),"helper_pid":helper,"error_code":m.error,"reason":reason(m.error)}),
        );
        if let Ok(mut b) = b {
            b.push(b'\n');
            if b.len() > 512 {
                self.shared.failures.fetch_add(1, Ordering::Relaxed);
                return;
            }
            let mut slot = self.shared.slot.lock().unwrap();
            slot.event = Some(b);
            self.shared.changed.notify_one();
        } else {
            self.shared.failures.fetch_add(1, Ordering::Relaxed);
        }
    }
    pub fn stop(mut self) -> io::Result<()> {
        {
            let mut slot = self.shared.slot.lock().unwrap();
            slot.stop = true;
            self.shared.changed.notify_one();
        }
        let deadline = Instant::now() + Duration::from_secs(1);
        let worker = self.worker.take().unwrap();
        while !worker.is_finished() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        if !worker.is_finished() {
            return Err(invalid("output outstanding"));
        } // Drop detaches, never cancels/replaces.
        worker.join().map_err(|_| invalid("output worker failed"))
    }
}
fn writer(shared: Arc<Shared>, c: Config) {
    let mut state: Option<Identity> = None;
    let mut metrics: Option<Identity> = None;
    loop {
        let (model, event) = {
            let mut slot = shared.slot.lock().unwrap();
            while slot.model.is_none() && slot.event.is_none() && !slot.stop {
                slot = shared.changed.wait(slot).unwrap();
            }
            if slot.stop {
                break;
            }
            (slot.model.take(), slot.event.take())
        }; // No output I/O under the publication mutex.
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
        if let Some(b) = event {
            if sys::write_status(&b).is_err() {
                shared.failures.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
    files::remove(&c.state_file, state, 0);
    files::remove(&c.metrics_file, metrics, 0);
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn latest_slot_retains_cumulative_history_when_output_is_delayed() {
        let shared = Arc::new(Shared::default());
        let o = Output {
            shared: shared.clone(),
            worker: None,
        };
        let mut model = Model::new("01234567-89ab-cdef-0123-456789abcdef", "output").unwrap();
        for i in 1..=100 {
            model.sequence = i;
            model.history.responses = i;
            model.history.buckets.fill(i);
            model.history.sum_ns = i * 1_000_000;
            model.history.overdue = i;
            model.errors[5] = i;
            o.submit(&model);
        }
        let slot = shared.slot.lock().unwrap();
        let last = slot.model.as_ref().unwrap();
        assert_eq!(last.sequence, 100);
        assert_eq!(last.history.responses, 100);
        assert!(last.history.buckets.iter().all(|count| *count == 100));
        assert_eq!(last.history.sum_ns, 100_000_000);
        assert_eq!(last.history.overdue, 100);
        assert_eq!(last.errors[5], 100);
        let failures = shared.failures.load(Ordering::Relaxed);
        assert_eq!(failures, 0);
        let metrics = String::from_utf8(last.metrics(failures).unwrap()).unwrap();
        assert!(metrics.contains("rtnl_watchdog_output_errors_total 0\n"));
    }
    #[test]
    fn latest_status_replacement_is_not_an_output_error() {
        let shared = Arc::new(Shared::default());
        let o = Output {
            shared: shared.clone(),
            worker: None,
        };
        let model = Model::new("01234567-89ab-cdef-0123-456789abcdef", "output").unwrap();
        for helper in 1..=100 {
            o.event("pending", &model, helper);
        }
        let slot = shared.slot.lock().unwrap();
        let event: serde_json::Value =
            serde_json::from_slice(slot.event.as_ref().unwrap()).unwrap();
        assert_eq!(event["event"], "pending");
        assert_eq!(event["helper_pid"], 100);
        let failures = shared.failures.load(Ordering::Relaxed);
        assert_eq!(failures, 0);
        let metrics = String::from_utf8(model.metrics(failures).unwrap()).unwrap();
        assert!(metrics.contains("rtnl_watchdog_output_errors_total 0\n"));
    }
    #[test]
    fn oversized_status_counts_and_renders_a_real_output_error() {
        let shared = Arc::new(Shared::default());
        let o = Output {
            shared: shared.clone(),
            worker: None,
        };
        let model = Model::new("01234567-89ab-cdef-0123-456789abcdef", "output").unwrap();
        o.event("pending", &model, 1);
        let pending = shared.slot.lock().unwrap().event.clone();
        o.event(&"x".repeat(512), &model, 1);
        assert_eq!(shared.slot.lock().unwrap().event, pending);
        let failures = shared.failures.load(Ordering::Relaxed);
        assert_eq!(failures, 1);
        let metrics = String::from_utf8(model.metrics(failures).unwrap()).unwrap();
        assert!(metrics.contains("rtnl_watchdog_output_errors_total 1\n"));
    }
}
