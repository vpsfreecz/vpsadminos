// SPDX-License-Identifier: GPL-2.0
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
    drops: AtomicU64,
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
        if slot.model.replace(m.clone()).is_some() {
            self.shared.drops.fetch_add(1, Ordering::Relaxed);
        }
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
            if slot.event.replace(b).is_some() {
                self.shared.drops.fetch_add(1, Ordering::Relaxed);
            }
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
                .metrics(
                    shared.drops.load(Ordering::Relaxed),
                    shared.failures.load(Ordering::Relaxed),
                )
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
            model.history.buckets[7] = i;
            o.submit(&model);
        }
        let slot = shared.slot.lock().unwrap();
        let last = slot.model.as_ref().unwrap();
        assert_eq!(last.sequence, 100);
        assert_eq!(last.history.responses, 100);
        assert_eq!(last.history.buckets[7], 100);
        assert_eq!(shared.drops.load(Ordering::Relaxed), 99);
    }
}
