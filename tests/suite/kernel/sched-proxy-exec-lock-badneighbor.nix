import ../../make-test.nix (
  { pkgs }:
  let
    lib = pkgs.lib;
    vmCpusEnv = builtins.getEnv "VPSADMINOS_PROXY_LOCK_VM_CPUS";
    vmCpus = if vmCpusEnv != "" then lib.toInt vmCpusEnv else 4;

    proxyLockSource = pkgs.runCommand "proxy-lock-badneighbor-src" { } ''
      mkdir -p "$out"

      cat >"$out/Kbuild" <<'EOF'
      obj-m += proxy_lock_badneighbor.o
      EOF

      cat >"$out/proxy_lock_badneighbor.c" <<'EOF'
      #include <linux/atomic.h>
      #include <linux/kernel.h>
      #include <linux/ktime.h>
      #include <linux/module.h>
      #include <linux/mutex.h>
      #include <linux/percpu-rwsem.h>
      #include <linux/proc_fs.h>
      #include <linux/rtmutex.h>
      #include <linux/rwsem.h>
      #include <linux/sched.h>
      #include <linux/sched/signal.h>
      #include <linux/seq_file.h>
      #include <linux/slab.h>
      #include <linux/uaccess.h>
      #include <linux/ww_mutex.h>

      enum proxy_lock_class {
        PROXY_LOCK_MUTEX,
        PROXY_LOCK_WW_MUTEX,
        PROXY_LOCK_RTMUTEX,
        PROXY_LOCK_RWSEM_WRITE,
        PROXY_LOCK_RWSEM_READ,
        PROXY_LOCK_PERCPU_RWSEM_WRITE,
        PROXY_LOCK_PERCPU_RWSEM_READ,
        PROXY_LOCK_COUNT,
      };

      static const char * const proxy_lock_names[PROXY_LOCK_COUNT] = {
        [PROXY_LOCK_MUTEX] = "mutex",
        [PROXY_LOCK_WW_MUTEX] = "ww_mutex",
        [PROXY_LOCK_RTMUTEX] = "rtmutex",
        [PROXY_LOCK_RWSEM_WRITE] = "rwsem_write",
        [PROXY_LOCK_RWSEM_READ] = "rwsem_read",
        [PROXY_LOCK_PERCPU_RWSEM_WRITE] = "percpu_rwsem_write",
        [PROXY_LOCK_PERCPU_RWSEM_READ] = "percpu_rwsem_read",
      };

      static DEFINE_MUTEX(proxy_mutex);
      static DEFINE_WW_CLASS(proxy_ww_class);
      static struct ww_mutex proxy_ww_mutex;
      static struct rt_mutex proxy_rtmutex;
      static DECLARE_RWSEM(proxy_rwsem);
      static struct percpu_rw_semaphore proxy_percpu_rwsem;

      static struct proc_dir_entry *proxy_lock_hold_entry;
      static struct proc_dir_entry *proxy_lock_probe_entry;
      static struct proc_dir_entry *proxy_lock_control_entry;
      static atomic_t proxy_lock_active = ATOMIC_INIT(0);
      static atomic_t proxy_lock_active_pid = ATOMIC_INIT(0);
      static atomic_t proxy_lock_active_class = ATOMIC_INIT(-1);
      static atomic_t proxy_lock_stop = ATOMIC_INIT(0);
      static atomic64_t proxy_lock_active_start_us = ATOMIC64_INIT(0);
      static atomic64_t proxy_lock_active_runtime_us = ATOMIC64_INIT(0);
      static atomic64_t proxy_lock_active_offcpu_us = ATOMIC64_INIT(0);
      static atomic_t proxy_lock_active_count[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_runs[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_total_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_max_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_total_runtime_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_max_runtime_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_total_offcpu_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_max_offcpu_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_hold_yields[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_probe_runs[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_probe_total_wait_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_probe_max_wait_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_probe_total_elapsed_us[PROXY_LOCK_COUNT];
      static atomic64_t proxy_lock_probe_max_elapsed_us[PROXY_LOCK_COUNT];

      static void proxy_lock_update_max(atomic64_t *counter, s64 value)
      {
        s64 old;

        do {
          old = atomic64_read(counter);
          if (value <= old)
            return;
        } while (atomic64_cmpxchg(counter, old, value) != old);
      }

      static enum proxy_lock_class proxy_lock_class_from_name(const char *name)
      {
        int i;

        for (i = 0; i < PROXY_LOCK_COUNT; i++) {
          if (!strcmp(name, proxy_lock_names[i]))
            return i;
        }

        return PROXY_LOCK_COUNT;
      }

      static int proxy_lock_take(enum proxy_lock_class cls, bool holder)
      {
        switch (cls) {
        case PROXY_LOCK_MUTEX:
          mutex_lock(&proxy_mutex);
          return 0;
        case PROXY_LOCK_WW_MUTEX:
          return ww_mutex_lock(&proxy_ww_mutex, NULL);
        case PROXY_LOCK_RTMUTEX:
          rt_mutex_lock(&proxy_rtmutex);
          return 0;
        case PROXY_LOCK_RWSEM_WRITE:
          if (holder)
            down_write(&proxy_rwsem);
          else
            down_read(&proxy_rwsem);
          return 0;
        case PROXY_LOCK_RWSEM_READ:
          if (holder)
            down_read(&proxy_rwsem);
          else
            down_write(&proxy_rwsem);
          return 0;
        case PROXY_LOCK_PERCPU_RWSEM_WRITE:
          if (holder)
            percpu_down_write(&proxy_percpu_rwsem);
          else
            percpu_down_read(&proxy_percpu_rwsem);
          return 0;
        case PROXY_LOCK_PERCPU_RWSEM_READ:
          if (holder)
            percpu_down_read(&proxy_percpu_rwsem);
          else
            percpu_down_write(&proxy_percpu_rwsem);
          return 0;
        default:
          return -EINVAL;
        }
      }

      static void proxy_lock_drop(enum proxy_lock_class cls, bool holder)
      {
        switch (cls) {
        case PROXY_LOCK_MUTEX:
          mutex_unlock(&proxy_mutex);
          break;
        case PROXY_LOCK_WW_MUTEX:
          ww_mutex_unlock(&proxy_ww_mutex);
          break;
        case PROXY_LOCK_RTMUTEX:
          rt_mutex_unlock(&proxy_rtmutex);
          break;
        case PROXY_LOCK_RWSEM_WRITE:
          if (holder)
            up_write(&proxy_rwsem);
          else
            up_read(&proxy_rwsem);
          break;
        case PROXY_LOCK_RWSEM_READ:
          if (holder)
            up_read(&proxy_rwsem);
          else
            up_write(&proxy_rwsem);
          break;
        case PROXY_LOCK_PERCPU_RWSEM_WRITE:
          if (holder)
            percpu_up_write(&proxy_percpu_rwsem);
          else
            percpu_up_read(&proxy_percpu_rwsem);
          break;
        case PROXY_LOCK_PERCPU_RWSEM_READ:
          if (holder)
            percpu_up_read(&proxy_percpu_rwsem);
          else
            percpu_up_write(&proxy_percpu_rwsem);
          break;
        default:
          break;
        }
      }

      static int proxy_lock_parse(char *buf, enum proxy_lock_class *cls,
                                  unsigned int *value, unsigned int *reps,
                                  unsigned int *yield_us,
                                  unsigned int default_value)
      {
        char name[40];
        int scanned;

        *value = default_value;
        *reps = 1;
        *yield_us = 0;
        scanned = sscanf(buf, "%39s %u %u %u", name, value, reps, yield_us);
        if (scanned < 1)
          return -EINVAL;

        *cls = proxy_lock_class_from_name(name);
        if (*cls >= PROXY_LOCK_COUNT)
          return -EINVAL;

        *value = clamp(*value, 1U, 5000000U);
        *reps = clamp(*reps, 1U, 10000U);
        *yield_us = clamp(*yield_us, 0U, 1000000U);
        return 0;
      }

      static ssize_t proxy_lock_hold_write(struct file *file,
                                           const char __user *ubuf,
                                           size_t len, loff_t *ppos)
      {
        char buf[96];
        enum proxy_lock_class cls;
        unsigned int hold_us;
        unsigned int reps;
        unsigned int yield_us;
        size_t copy_len;
        unsigned int i;
        int ret;

        copy_len = min(len, sizeof(buf) - 1);
        if (copy_from_user(buf, ubuf, copy_len))
          return -EFAULT;
        buf[copy_len] = '\0';

        ret = proxy_lock_parse(buf, &cls, &hold_us, &reps, &yield_us, 250000);
        if (ret)
          return ret;

        atomic_set(&proxy_lock_stop, 0);

        for (i = 0; i < reps; i++) {
          ktime_t start;
          s64 elapsed_us;
          s64 runtime_us;
          s64 offcpu_us;
          u64 start_runtime_ns;
          u64 runtime_ns = 0;
          u64 offcpu_ns = 0;
          u64 target_ns = (u64)hold_us * 1000ULL;
          u64 yield_ns = (u64)yield_us * 1000ULL;
          u64 last_yield_runtime_ns = 0;
          unsigned long loops = 0;
          bool interrupted = false;

          if (atomic_read(&proxy_lock_stop))
            break;

          ret = proxy_lock_take(cls, true);
          if (ret)
            return ret;

          if (signal_pending(current) || atomic_read(&proxy_lock_stop)) {
            proxy_lock_drop(cls, true);
            break;
          }

          start = ktime_get();
          start_runtime_ns = READ_ONCE(current->se.sum_exec_runtime);
          atomic64_set(&proxy_lock_active_start_us,
                       ktime_to_ns(start) / 1000);
          atomic64_set(&proxy_lock_active_runtime_us, 0);
          atomic64_set(&proxy_lock_active_offcpu_us, 0);
          atomic_inc(&proxy_lock_active_count[cls]);
          atomic_set(&proxy_lock_active_pid, current->pid);
          atomic_set(&proxy_lock_active_class, cls);
          atomic_set(&proxy_lock_active, 1);

          while (runtime_ns < target_ns) {
            ktime_t now = ktime_get();
            u64 elapsed_ns = ktime_to_ns(ktime_sub(now, start));
            u64 now_runtime_ns = READ_ONCE(current->se.sum_exec_runtime);

            runtime_ns = now_runtime_ns >= start_runtime_ns ?
              now_runtime_ns - start_runtime_ns : 0;
            offcpu_ns = elapsed_ns > runtime_ns ? elapsed_ns - runtime_ns : 0;
            atomic64_set(&proxy_lock_active_runtime_us, runtime_ns / 1000);
            atomic64_set(&proxy_lock_active_offcpu_us, offcpu_ns / 1000);
            cpu_relax();

            if (yield_ns > 0 &&
                runtime_ns >= last_yield_runtime_ns + yield_ns) {
              last_yield_runtime_ns = runtime_ns;
              atomic64_inc(&proxy_lock_hold_yields[cls]);
              yield();
            }

            if ((++loops & 0xfff) == 0) {
              if (signal_pending(current) || atomic_read(&proxy_lock_stop)) {
                interrupted = true;
                break;
              }
              cond_resched();
            }
          }

          elapsed_us = ktime_us_delta(ktime_get(), start);
          runtime_us = runtime_ns / 1000;
          offcpu_us = offcpu_ns / 1000;
          if (atomic_dec_return(&proxy_lock_active_count[cls]) <= 0) {
            atomic_set(&proxy_lock_active_count[cls], 0);
            if (atomic_read(&proxy_lock_active_class) == cls) {
              atomic_set(&proxy_lock_active, 0);
              atomic_set(&proxy_lock_active_pid, 0);
              atomic_set(&proxy_lock_active_class, -1);
              atomic64_set(&proxy_lock_active_start_us, 0);
              atomic64_set(&proxy_lock_active_runtime_us, 0);
              atomic64_set(&proxy_lock_active_offcpu_us, 0);
            }
          }
          proxy_lock_drop(cls, true);

          atomic64_inc(&proxy_lock_hold_runs[cls]);
          atomic64_add(elapsed_us, &proxy_lock_hold_total_us[cls]);
          proxy_lock_update_max(&proxy_lock_hold_max_us[cls], elapsed_us);
          atomic64_add(runtime_us, &proxy_lock_hold_total_runtime_us[cls]);
          proxy_lock_update_max(&proxy_lock_hold_max_runtime_us[cls],
                                runtime_us);
          atomic64_add(offcpu_us, &proxy_lock_hold_total_offcpu_us[cls]);
          proxy_lock_update_max(&proxy_lock_hold_max_offcpu_us[cls],
                                offcpu_us);

          if (interrupted)
            break;
        }

        return len;
      }

      static ssize_t proxy_lock_control_write(struct file *file,
                                              const char __user *ubuf,
                                              size_t len, loff_t *ppos)
      {
        char buf[32];
        char cmd[16];
        size_t copy_len;

        copy_len = min(len, sizeof(buf) - 1);
        if (copy_from_user(buf, ubuf, copy_len))
          return -EFAULT;
        buf[copy_len] = '\0';

        if (sscanf(buf, "%15s", cmd) != 1)
          return -EINVAL;

        if (!strcmp(cmd, "stop")) {
          atomic_set(&proxy_lock_stop, 1);
        } else if (!strcmp(cmd, "reset")) {
          atomic_set(&proxy_lock_stop, 0);
        } else {
          return -EINVAL;
        }

        return len;
      }

      static ssize_t proxy_lock_probe_write(struct file *file,
                                            const char __user *ubuf,
                                            size_t len, loff_t *ppos)
      {
        char buf[96];
        enum proxy_lock_class cls;
        unsigned int unused;
        unsigned int reps;
        unsigned int yield_unused;
        size_t copy_len;
        unsigned int i;
        int ret;

        copy_len = min(len, sizeof(buf) - 1);
        if (copy_from_user(buf, ubuf, copy_len))
          return -EFAULT;
        buf[copy_len] = '\0';

        ret = proxy_lock_parse(buf, &cls, &unused, &reps, &yield_unused, 1);
        if (ret)
          return ret;

        for (i = 0; i < reps; i++) {
          ktime_t start;
          ktime_t locked;
          s64 wait_us;
          s64 elapsed_us;

          start = ktime_get();
          ret = proxy_lock_take(cls, false);
          if (ret)
            return ret;
          locked = ktime_get();
          proxy_lock_drop(cls, false);

          wait_us = ktime_us_delta(locked, start);
          elapsed_us = ktime_us_delta(ktime_get(), start);
          atomic64_inc(&proxy_lock_probe_runs[cls]);
          atomic64_add(wait_us, &proxy_lock_probe_total_wait_us[cls]);
          proxy_lock_update_max(&proxy_lock_probe_max_wait_us[cls], wait_us);
          atomic64_add(elapsed_us, &proxy_lock_probe_total_elapsed_us[cls]);
          proxy_lock_update_max(&proxy_lock_probe_max_elapsed_us[cls],
                                elapsed_us);
        }

        return len;
      }

      static int proxy_lock_show(struct seq_file *m, void *v)
      {
        int active_class = atomic_read(&proxy_lock_active_class);
        s64 active_start_us = atomic64_read(&proxy_lock_active_start_us);
        s64 active_elapsed_us = 0;
        s64 active_runtime_us =
          atomic64_read(&proxy_lock_active_runtime_us);
        s64 active_offcpu_us =
          atomic64_read(&proxy_lock_active_offcpu_us);
        int i;

        if (active_start_us > 0)
          active_elapsed_us = ktime_to_ns(ktime_get()) / 1000 - active_start_us;
        if (active_elapsed_us > active_runtime_us &&
            active_elapsed_us - active_runtime_us > active_offcpu_us)
          active_offcpu_us = active_elapsed_us - active_runtime_us;

        seq_printf(m, "active %d\n", atomic_read(&proxy_lock_active));
        seq_printf(m, "active_pid %d\n", atomic_read(&proxy_lock_active_pid));
        seq_printf(m, "active_class %s\n",
                   active_class >= 0 && active_class < PROXY_LOCK_COUNT ?
                   proxy_lock_names[active_class] : "none");
        seq_printf(m, "active_elapsed_us %lld\n", active_elapsed_us);
        seq_printf(m, "active_runtime_us %lld\n", active_runtime_us);
        seq_printf(m, "active_offcpu_us %lld\n", active_offcpu_us);
        seq_printf(m, "stop_requested %d\n", atomic_read(&proxy_lock_stop));

        for (i = 0; i < PROXY_LOCK_COUNT; i++) {
          seq_printf(m, "%s_active_count %d\n", proxy_lock_names[i],
                     atomic_read(&proxy_lock_active_count[i]));
          seq_printf(m, "%s_hold_runs %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_runs[i]));
          seq_printf(m, "%s_hold_total_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_total_us[i]));
          seq_printf(m, "%s_hold_max_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_max_us[i]));
          seq_printf(m, "%s_hold_total_runtime_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_total_runtime_us[i]));
          seq_printf(m, "%s_hold_max_runtime_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_max_runtime_us[i]));
          seq_printf(m, "%s_hold_total_offcpu_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_total_offcpu_us[i]));
          seq_printf(m, "%s_hold_max_offcpu_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_max_offcpu_us[i]));
          seq_printf(m, "%s_hold_yields %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_hold_yields[i]));
          seq_printf(m, "%s_probe_runs %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_probe_runs[i]));
          seq_printf(m, "%s_probe_total_wait_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_probe_total_wait_us[i]));
          seq_printf(m, "%s_probe_max_wait_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_probe_max_wait_us[i]));
          seq_printf(m, "%s_probe_total_elapsed_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_probe_total_elapsed_us[i]));
          seq_printf(m, "%s_probe_max_elapsed_us %lld\n", proxy_lock_names[i],
                     atomic64_read(&proxy_lock_probe_max_elapsed_us[i]));
        }

        return 0;
      }

      static int proxy_lock_open(struct inode *inode, struct file *file)
      {
        return single_open(file, proxy_lock_show, NULL);
      }

      static int proxy_lock_control_show(struct seq_file *m, void *v)
      {
        seq_printf(m, "stop_requested %d\n", atomic_read(&proxy_lock_stop));
        return 0;
      }

      static int proxy_lock_control_open(struct inode *inode, struct file *file)
      {
        return single_open(file, proxy_lock_control_show, NULL);
      }

      static const struct proc_ops proxy_lock_hold_ops = {
        .proc_open = proxy_lock_open,
        .proc_read = seq_read,
        .proc_lseek = seq_lseek,
        .proc_release = single_release,
        .proc_write = proxy_lock_hold_write,
      };

      static const struct proc_ops proxy_lock_probe_ops = {
        .proc_open = proxy_lock_open,
        .proc_read = seq_read,
        .proc_lseek = seq_lseek,
        .proc_release = single_release,
        .proc_write = proxy_lock_probe_write,
      };

      static const struct proc_ops proxy_lock_control_ops = {
        .proc_open = proxy_lock_control_open,
        .proc_read = seq_read,
        .proc_lseek = seq_lseek,
        .proc_release = single_release,
        .proc_write = proxy_lock_control_write,
      };

      static int __init proxy_lock_badneighbor_init(void)
      {
        int i;
        int ret;

        ww_mutex_init(&proxy_ww_mutex, &proxy_ww_class);
        rt_mutex_init(&proxy_rtmutex);
        ret = percpu_init_rwsem(&proxy_percpu_rwsem);
        if (ret)
          return ret;

        for (i = 0; i < PROXY_LOCK_COUNT; i++) {
          atomic_set(&proxy_lock_active_count[i], 0);
          atomic64_set(&proxy_lock_hold_runs[i], 0);
          atomic64_set(&proxy_lock_hold_total_us[i], 0);
          atomic64_set(&proxy_lock_hold_max_us[i], 0);
          atomic64_set(&proxy_lock_hold_total_runtime_us[i], 0);
          atomic64_set(&proxy_lock_hold_max_runtime_us[i], 0);
          atomic64_set(&proxy_lock_hold_total_offcpu_us[i], 0);
          atomic64_set(&proxy_lock_hold_max_offcpu_us[i], 0);
          atomic64_set(&proxy_lock_hold_yields[i], 0);
          atomic64_set(&proxy_lock_probe_runs[i], 0);
          atomic64_set(&proxy_lock_probe_total_wait_us[i], 0);
          atomic64_set(&proxy_lock_probe_max_wait_us[i], 0);
          atomic64_set(&proxy_lock_probe_total_elapsed_us[i], 0);
          atomic64_set(&proxy_lock_probe_max_elapsed_us[i], 0);
        }

        proxy_lock_hold_entry =
          proc_create("proxy_lock_badneighbor_hold", 0666, NULL,
                      &proxy_lock_hold_ops);
        if (!proxy_lock_hold_entry) {
          percpu_free_rwsem(&proxy_percpu_rwsem);
          return -ENOMEM;
        }

        proxy_lock_probe_entry =
          proc_create("proxy_lock_badneighbor_probe", 0666, NULL,
                      &proxy_lock_probe_ops);
        if (!proxy_lock_probe_entry) {
          proc_remove(proxy_lock_hold_entry);
          percpu_free_rwsem(&proxy_percpu_rwsem);
          return -ENOMEM;
        }

        proxy_lock_control_entry =
          proc_create("proxy_lock_badneighbor_control", 0666, NULL,
                      &proxy_lock_control_ops);
        if (!proxy_lock_control_entry) {
          proc_remove(proxy_lock_probe_entry);
          proc_remove(proxy_lock_hold_entry);
          percpu_free_rwsem(&proxy_percpu_rwsem);
          return -ENOMEM;
        }

        return 0;
      }

      static void __exit proxy_lock_badneighbor_exit(void)
      {
        if (proxy_lock_control_entry)
          proc_remove(proxy_lock_control_entry);
        if (proxy_lock_probe_entry)
          proc_remove(proxy_lock_probe_entry);
        if (proxy_lock_hold_entry)
          proc_remove(proxy_lock_hold_entry);
        percpu_free_rwsem(&proxy_percpu_rwsem);
      }

      module_init(proxy_lock_badneighbor_init);
      module_exit(proxy_lock_badneighbor_exit);

      MODULE_DESCRIPTION("Owner-bearing lock bad-neighbor helper for proxy exec tests");
      MODULE_LICENSE("GPL");
      EOF
    '';

    lockControl = pkgs.writeScript "proxy-lock-control.sh" ''
      #!/bin/sh
      set -eu

      state_dir=/var/tmp/proxy-lock
      pid_file="$state_dir/proxy-lock.pid"
      stop_file="$state_dir/proxy-lock.stop"
      log_file="$state_dir/proxy-lock.log"
      mkdir -p "$state_dir"

      stop_workload() {
        if [ ! -f "$pid_file" ]; then
          rm -f "$stop_file"
          return 0
        fi

        pid="$(cat "$pid_file" 2>/dev/null || true)"
        rm -f "$pid_file"
        touch "$stop_file"

        if [ -z "$pid" ]; then
          rm -f "$stop_file"
          return 0
        fi

        kill "$pid" 2>/dev/null || true
        i=0
        while [ "$i" -lt 80 ]; do
          if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$stop_file"
            return 0
          fi
          sleep 0.1
          i=$((i + 1))
        done

        kill -KILL "$pid" 2>/dev/null || true
        rm -f "$stop_file"
      }

      write_worker_script() {
        cat >/run/proxy-lock-worker.sh <<'SH'
      #!/bin/sh
      set -eu

      STATE_DIR=/var/tmp/proxy-lock
      STOP_FILE="$STATE_DIR/proxy-lock.stop"
      PID_FILE="$STATE_DIR/proxy-lock.pid"
      children=""

      mkdir -p "$STATE_DIR"

      cgroup_line() {
        tr '\n' ';' </proc/self/cgroup 2>/dev/null || true
      }

      cpu_worker() {
        echo "cpu-worker pid=$$ cgroup=$(cgroup_line)"
        while [ ! -e "$STOP_FILE" ]; do
          :
        done
      }

      lock_worker() {
        echo "lock-worker class=$LOCK_CLASS pid=$$ cgroup=$(cgroup_line)"
        while [ ! -e "$STOP_FILE" ]; do
          printf '%s %s %s %s\n' \
            "$LOCK_CLASS" \
            "''${LOCK_HOLD_US:-250000}" \
            "''${LOCK_HOLD_REPS:-1}" \
            "''${LOCK_HOLD_YIELD_US:-0}" >/proc/proxy_lock_badneighbor_hold || true
        done
      }

      spawn() {
        "$@" &
        children="$children $!"
      }

      cleanup() {
        for child in $children; do
          kill "$child" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        rm -f "$PID_FILE" "$STOP_FILE"
        exit 0
      }

      trap cleanup TERM INT

      echo "proxy-lock-worker parent_pid=$$ class=$LOCK_CLASS cgroup=$(cgroup_line)"
      echo "$$" >"$PID_FILE"

      i=0
      while [ "$i" -lt "''${CPU_WORKERS:-4}" ]; do
        spawn cpu_worker
        i=$((i + 1))
      done

      i=0
      while [ "$i" -lt "''${LOCK_WORKERS:-1}" ]; do
        spawn lock_worker
        i=$((i + 1))
      done

      echo "proxy-lock-worker children=$children"
      while [ ! -e "$STOP_FILE" ]; do
        sleep 0.5
      done
      cleanup
      SH

        chmod 500 /run/proxy-lock-worker.sh
      }

      mode="''${1:-}"
      if [ "$#" -gt 0 ]; then
        shift
      fi

      for assignment in "$@"; do
        case "$assignment" in
          CPU_WORKERS=*|LOCK_WORKERS=*|LOCK_CLASS=*|LOCK_HOLD_US=*|LOCK_HOLD_REPS=*|LOCK_HOLD_YIELD_US=*)
            export "$assignment"
            ;;
          *)
            echo "unsupported argument: $assignment" >&2
            exit 1
            ;;
        esac
      done

      case "$mode" in
        run)
          test -n "''${LOCK_CLASS:-}"
          rm -f "$pid_file" "$stop_file" "$log_file"
          write_worker_script
          : >"$log_file"
          CPU_WORKERS="''${CPU_WORKERS:-4}" \
            LOCK_WORKERS="''${LOCK_WORKERS:-1}" \
            LOCK_CLASS="$LOCK_CLASS" \
            LOCK_HOLD_US="''${LOCK_HOLD_US:-250000}" \
            LOCK_HOLD_REPS="''${LOCK_HOLD_REPS:-1}" \
            LOCK_HOLD_YIELD_US="''${LOCK_HOLD_YIELD_US:-0}" \
            exec /run/proxy-lock-worker.sh >>"$log_file" 2>&1
          ;;
        stop)
          stop_workload
          ;;
        status)
          pid="$(cat "$pid_file" 2>/dev/null || true)"
          test -n "$pid"
          kill -0 "$pid"
          ;;
        log)
          cat "$log_file" 2>/dev/null || true
          ;;
        *)
          echo "usage: $0 run|stop|status|log" >&2
          exit 2
          ;;
      esac
    '';

    lockMeasure = pkgs.writeScript "proxy-lock-measure.sh" ''
      #!/bin/sh
      set -eu

      lock_class="''${1:?lock class required}"
      count="''${2:-120}"
      sync_active="''${3:-0}"
      active_min_age_ms="''${4:-0}"
      active_min_offcpu_ms="''${5:-0}"
      active_wait_timeout_ms="''${6:-''${VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_TIMEOUT_MS:-5000}}"
      active_wait_error_limit="''${7:-''${VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_ERROR_LIMIT:-20}}"
      active_min_age_us=$((active_min_age_ms * 1000))
      active_min_offcpu_us=$((active_min_offcpu_ms * 1000))
      retries="''${VPSADMINOS_PROXY_LOCK_PROBE_RETRIES:-5}"
      active_poll_ms="''${VPSADMINOS_PROXY_LOCK_ACTIVE_POLL_MS:-5}"
      active_poll_sleep="$(
        awk -v ms="$active_poll_ms" 'BEGIN { printf "%.3f", ms / 1000.0 }'
      )"
      latencies="/run/proxy-lock-latencies.$$"
      sorted="$latencies.sorted"
      errors=0
      retry_total=0
      active_waits=0
      active_wait_errors=0
      timeout_reason=
      clock_source="uptime_ns"

      date_probe="$(date +%s%N 2>/dev/null || true)"
      case "$date_probe" in
        ""|*[!0-9]*) have_date_ns=0 ;;
        *)
          if [ "''${#date_probe}" -ge 18 ]; then
            have_date_ns=1
          else
            have_date_ns=0
          fi
          ;;
      esac

      if [ "$have_date_ns" -eq 1 ]; then
        clock_source="date_ns"
      fi

      cleanup() {
        rm -f "$latencies" "$sorted"
      }
      trap cleanup EXIT

      now_ns() {
        if [ "$have_date_ns" -eq 1 ]; then
          date +%s%N
        else
          awk '{ printf "%.0f\n", $1 * 1000000000.0 }' /proc/uptime
        fi
      }

      wait_active() {
        waited_ms=0

        while [ "$waited_ms" -le "$active_wait_timeout_ms" ]; do
          if awk -v target="$lock_class" \
            -v min_age_us="$active_min_age_us" \
            -v min_offcpu_us="$active_min_offcpu_us" '
            $1 == "active" { active = $2 }
            $1 == "active_class" { active_class = $2 }
            $1 == "active_elapsed_us" { active_elapsed_us = $2 }
            $1 == "active_runtime_us" { active_runtime_us = $2 }
            $1 == "active_offcpu_us" { active_offcpu_us = $2 }
            END {
              live_offcpu_us = active_offcpu_us
              if (active_elapsed_us > active_runtime_us &&
                  active_elapsed_us - active_runtime_us > live_offcpu_us)
                live_offcpu_us = active_elapsed_us - active_runtime_us
              exit !(active == 1 &&
                     active_class == target &&
                     active_elapsed_us >= min_age_us &&
                     live_offcpu_us >= min_offcpu_us)
            }
          ' /proc/proxy_lock_badneighbor_hold; then
            return 0
          fi

          sleep "$active_poll_sleep"
          waited_ms=$((waited_ms + active_poll_ms))
        done

        return 1
      }

      : >"$latencies"
      i=0
      while [ "$i" -lt "$count" ]; do
        attempt=0
        success=0

        if [ "$sync_active" = 1 ]; then
          active_waits=$((active_waits + 1))
          if ! wait_active; then
            active_wait_errors=$((active_wait_errors + 1))
            errors=$((errors + 1))
            if [ "$active_wait_errors" -ge "$active_wait_error_limit" ]; then
              timeout_reason=active_wait
              break
            fi
            i=$((i + 1))
            continue
          fi
        fi

        while [ "$attempt" -le "$retries" ]; do
          start="$(now_ns)"
          if printf '%s 1 1\n' "$lock_class" >/proc/proxy_lock_badneighbor_probe; then
            end="$(now_ns)"
            awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f\n", (end - start) / 1000000.0 }' >>"$latencies"
            retry_total=$((retry_total + attempt))
            success=1
            break
          fi

          attempt=$((attempt + 1))
          sleep 0.01
        done

        if [ "$success" -eq 0 ]; then
          errors=$((errors + 1))
        fi

        i=$((i + 1))
      done

      sort -n "$latencies" >"$sorted"
      awk -v count="$count" -v errors="$errors" \
        -v retry_total="$retry_total" \
        -v active_sync="$sync_active" \
        -v active_min_age_ms="$active_min_age_ms" \
        -v active_min_offcpu_ms="$active_min_offcpu_ms" \
        -v active_waits="$active_waits" \
        -v active_wait_errors="$active_wait_errors" \
        -v timeout_reason="$timeout_reason" \
        -v clock_source="$clock_source" -v operation="$lock_class" '
        function pick(p, idx) {
          idx = int((n - 1) * p + 0.5) + 1
          if (idx < 1) idx = 1
          if (idx > n) idx = n
          return values[idx]
        }

        function count_over(threshold, i, count_over_value) {
          count_over_value = 0
          for (i = 1; i <= n; i += 1) {
            if (values[i] > threshold) count_over_value += 1
          }
          return count_over_value
        }

        function print_top(limit, start, i) {
          start = n - limit + 1
          if (start < 1) start = 1
          printf("[")
          for (i = start; i <= n; i += 1) {
            if (i > start) printf(",")
            printf("%.3f", values[i])
          }
          printf("]")
        }

        {
          n += 1
          values[n] = $1
          sum += $1
        }

        END {
          timeout_json = timeout_reason == "" ? "false" : "true"
          timeout_reason_json = timeout_reason == "" ? "null" : "\"" timeout_reason "\""

          if (n == 0) {
            printf("{\"operation\":\"%s\",\"clock\":\"%s\",\"count\":%d,\"samples\":0,\"errors\":%d,\"retry_total\":%d,\"active_sync\":%s,\"active_min_age_ms\":%d,\"active_min_offcpu_ms\":%d,\"active_waits\":%d,\"active_wait_errors\":%d,\"timeout\":%s,\"timeout_reason\":%s,\"min_ms\":0,\"avg_ms\":0,\"p50_ms\":0,\"p90_ms\":0,\"p95_ms\":0,\"p99_ms\":0,\"p99_5_ms\":0,\"p99_9_ms\":0,\"max_ms\":0,\"over_50_ms\":0,\"over_100_ms\":0,\"over_250_ms\":0,\"over_500_ms\":0,\"over_1000_ms\":0,\"top_ms\":[]}\n", operation, clock_source, count, errors, retry_total, active_sync == "1" ? "true" : "false", active_min_age_ms, active_min_offcpu_ms, active_waits, active_wait_errors, timeout_json, timeout_reason_json)
            exit
          }

          printf("{\"operation\":\"%s\",\"clock\":\"%s\",\"count\":%d,\"samples\":%d,\"errors\":%d,\"retry_total\":%d,\"active_sync\":%s,\"active_min_age_ms\":%d,\"active_min_offcpu_ms\":%d,\"active_waits\":%d,\"active_wait_errors\":%d,\"timeout\":%s,\"timeout_reason\":%s,\"min_ms\":%.3f,\"avg_ms\":%.3f,\"p50_ms\":%.3f,\"p90_ms\":%.3f,\"p95_ms\":%.3f,\"p99_ms\":%.3f,\"p99_5_ms\":%.3f,\"p99_9_ms\":%.3f,\"max_ms\":%.3f,\"over_50_ms\":%d,\"over_100_ms\":%d,\"over_250_ms\":%d,\"over_500_ms\":%d,\"over_1000_ms\":%d,\"top_ms\":",
            operation, clock_source, count, n, errors, retry_total,
            active_sync == "1" ? "true" : "false", active_min_age_ms,
            active_min_offcpu_ms,
            active_waits, active_wait_errors, timeout_json, timeout_reason_json,
            values[1], sum / n,
            pick(0.50), pick(0.90), pick(0.95), pick(0.99),
            pick(0.995), pick(0.999), values[n],
            count_over(50), count_over(100), count_over(250),
            count_over(500), count_over(1000))
          print_top(20)
          printf("}\n")
        }
      ' "$sorted"
    '';
  in
  {
    name = "kernel-sched-proxy-exec-lock-badneighbor";

    description = ''
      Validate proxy execution against CPU-limited bad-neighbor contention for touched lock classes
    '';

    tags = [ "proxy-exec" ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          proxyLockModule =
            let
              kernel = config.boot.kernelPackages.kernel;
            in
            pkgs.stdenv.mkDerivation {
              pname = "proxy-lock-badneighbor";
              version = kernel.modDirVersion;
              src = proxyLockSource;

              nativeBuildInputs = kernel.moduleBuildDependencies or [ ];
              hardeningDisable = [ "pic" ];
              dontStrip = true;

              buildPhase = ''
                runHook preBuild
                make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD modules
                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall
                install -Dm444 proxy_lock_badneighbor.ko \
                  $out/lib/modules/${kernel.modDirVersion}/extra/proxy_lock_badneighbor.ko
                runHook postInstall
              '';
            };
        in
        {
          imports = [
            ../../../os/configs/proxy-exec-qemu.nix
          ];

          boot.enableUnifiedCgroupHierarchy = lib.mkForce true;
          boot.extraModulePackages = [ proxyLockModule ];

          environment.systemPackages = with pkgs; [
            coreutils
            gzip
            gnugrep
            kmod
            procps
          ];

          networking.firewall.enable = lib.mkForce false;

          boot.qemu.memory = lib.mkOverride 0 4096;
          boot.qemu.cpus = lib.mkOverride 0 vmCpus;
          boot.qemu.cpu.cores = lib.mkOverride 0 vmCpus;
          boot.qemu.cpu.threads = lib.mkOverride 0 1;
          boot.qemu.cpu.sockets = lib.mkOverride 0 1;
        };
    };

    testScript = ''
      require 'json'
      require 'shellwords'

      STDOUT.sync = true

      TEST_PREFIX = 'pxl'
      BULLY_CT = "#{TEST_PREFIX}-bully"
      VICTIM_CT = "#{TEST_PREFIX}-victim"
      CLEANUP_CT_IDS = [VICTIM_CT, BULLY_CT]
      FULL_MATRIX =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_FULL_MATRIX', '0') == '1'
      REQUIRE_VALIDATION =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_REQUIRE_VALIDATION', '0') == '1'
      RUN_DISABLED_CONTROL =
        ENV.fetch(
          'VPSADMINOS_PROXY_LOCK_RUN_DISABLED_CONTROL',
          (FULL_MATRIX || REQUIRE_VALIDATION) ? '1' : '0'
        ) == '1'
      REQUIRE_PROXY_SIGNAL =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_REQUIRE_PROXY_SIGNAL', '1') == '1'
      DEFAULT_LOCK_CLASS_NAMES =
        ENV.fetch(
          'VPSADMINOS_PROXY_LOCK_DEFAULT_CLASSES',
          'mutex,rwsem_read_single,percpu_rwsem_read_representative'
        ).split(',').map(&:strip).reject(&:empty?)
      DEFAULT_READER_CONTENDED_COUNT = FULL_MATRIX ? '60' : '32'
      LOCK_CLASSES = [
        { 'name' => 'mutex', 'proxy_scope' => 'plain-mutex' },
        { 'name' => 'ww_mutex', 'proxy_scope' => 'ww-mutex' },
        { 'name' => 'rtmutex', 'proxy_scope' => 'rtmutex-opportunistic' },
        { 'name' => 'rwsem_write', 'proxy_scope' => 'rwsem-writer-owner' },
        {
          'name' => 'rwsem_read_single',
          'operation' => 'rwsem_read',
          'proxy_scope' => 'rwsem-single-reader-owner',
          'lock_workers' => '1',
        },
        {
          'name' => 'rwsem_read_multi',
          'operation' => 'rwsem_read',
          'proxy_scope' => 'rwsem-multi-reader-representative',
          'lock_workers' => ENV.fetch('VPSADMINOS_PROXY_LOCK_READER_WORKERS', '4'),
          'contended_count' => ENV.fetch('VPSADMINOS_PROXY_LOCK_READER_CONTENDED_COUNT', DEFAULT_READER_CONTENDED_COUNT),
        },
        { 'name' => 'percpu_rwsem_write', 'proxy_scope' => 'percpu-rwsem-writer-owner' },
        {
          'name' => 'percpu_rwsem_read_representative',
          'operation' => 'percpu_rwsem_read',
          'proxy_scope' => 'percpu-rwsem-bounded-reader-representative',
          'lock_workers' => ENV.fetch('VPSADMINOS_PROXY_LOCK_READER_WORKERS', '4'),
          'contended_count' => ENV.fetch('VPSADMINOS_PROXY_LOCK_READER_CONTENDED_COUNT', DEFAULT_READER_CONTENDED_COUNT),
        },
      ]
      LOCK_CLASS_FILTER =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_CLASS_FILTER', "")
          .split(',')
          .map(&:strip)
          .reject(&:empty?)
      SELECTED_LOCK_CLASSES =
        if LOCK_CLASS_FILTER.empty?
          if FULL_MATRIX
            LOCK_CLASSES
          else
            selected = LOCK_CLASSES.select do |entry|
              DEFAULT_LOCK_CLASS_NAMES.include?(entry.fetch('name'))
            end
            selected_names = selected.map { |entry| entry.fetch('name') }
            missing = DEFAULT_LOCK_CLASS_NAMES - selected_names
            raise "unknown lock classes in VPSADMINOS_PROXY_LOCK_DEFAULT_CLASSES: #{missing.join(', ')}" unless missing.empty?
            raise 'VPSADMINOS_PROXY_LOCK_DEFAULT_CLASSES selected no lock classes' if selected.empty?

            selected
          end
        else
          selected = LOCK_CLASSES.select do |entry|
            LOCK_CLASS_FILTER.include?(entry.fetch('name'))
          end
          selected_names = selected.map { |entry| entry.fetch('name') }
          missing = LOCK_CLASS_FILTER - selected_names
          raise "unknown lock classes in VPSADMINOS_PROXY_LOCK_CLASS_FILTER: #{missing.join(', ')}" unless missing.empty?
          raise 'VPSADMINOS_PROXY_LOCK_CLASS_FILTER selected no lock classes' if selected.empty?

          selected
        end
      VM_CPUS = '${toString vmCpus}'
      DEFAULT_BULLY_CPU_WORKERS = [(VM_CPUS.to_i * 16), 1].max.to_s
      SUPPORTED_PRESSURE_MODES = %w[quota weight].freeze
      PRESSURE_MODE =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_PRESSURE_MODE', 'weight')
      unless SUPPORTED_PRESSURE_MODES.include?(PRESSURE_MODE)
        raise "unknown VPSADMINOS_PROXY_LOCK_PRESSURE_MODE=#{PRESSURE_MODE.inspect}; " \
              "expected one of #{SUPPORTED_PRESSURE_MODES.join(', ')}"
      end
      BULLY_CPU_LIMIT = ENV.fetch('VPSADMINOS_PROXY_LOCK_CPU_LIMIT', '5')
      BULLY_CPU_WEIGHT = ENV.fetch('VPSADMINOS_PROXY_LOCK_CPU_WEIGHT', '1')
      BULLY_CPU_SHARES = ENV.fetch('VPSADMINOS_PROXY_LOCK_CPU_SHARES', '2')
      BULLY_CPU_WORKERS =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_CPU_WORKERS', DEFAULT_BULLY_CPU_WORKERS)
      BULLY_LOCK_WORKERS = ENV.fetch('VPSADMINOS_PROXY_LOCK_WORKERS', '1')
      BULLY_LOCK_HOLD_US = ENV.fetch('VPSADMINOS_PROXY_LOCK_HOLD_US', '250000')
      BULLY_LOCK_HOLD_REPS = ENV.fetch('VPSADMINOS_PROXY_LOCK_HOLD_REPS', '1000')
      BULLY_LOCK_HOLD_YIELD_US =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_HOLD_YIELD_US', '5000')
      ACTIVE_MIN_AGE_MS =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_AGE_MS',
                  (BULLY_LOCK_HOLD_US.to_i / 2000).to_s).to_i
      ACTIVE_MIN_OFFCPU_MS =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_ACTIVE_MIN_OFFCPU_MS', '0').to_i
      ACTIVE_WAIT_TIMEOUT_MS =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_TIMEOUT_MS', '5000').to_i
      ACTIVE_WAIT_ERROR_LIMIT =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_ACTIVE_WAIT_ERROR_LIMIT', '20').to_i
      BASELINE_COUNT =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_BASELINE_COUNT',
                  FULL_MATRIX ? '80' : '20').to_i
      CONTENDED_COUNT =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_CONTENDED_COUNT',
                  FULL_MATRIX ? '180' : '48').to_i
      VICTIM_MEASURE_TIMEOUT =
        ENV.fetch(
          'VPSADMINOS_PROXY_LOCK_MEASURE_TIMEOUT',
          if RUN_DISABLED_CONTROL && (FULL_MATRIX || REQUIRE_VALIDATION)
            '7200'
          elsif RUN_DISABLED_CONTROL
            '600'
          else
            '180'
          end
        ).to_i
      WARM_THROTTLE_EVENTS_MIN =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_WARM_THROTTLE_EVENTS_MIN',
                  PRESSURE_MODE == 'quota' ? '8' : '0').to_i
      WARM_THROTTLED_USEC_MIN =
        ENV.fetch('VPSADMINOS_PROXY_LOCK_WARM_THROTTLED_USEC_MIN', '0').to_i
      @ct_info_cache = {}

      def self.lock_operation(entry)
        entry.fetch('operation', entry.fetch('name'))
      end

      def self.lock_workers(entry)
        entry.fetch('lock_workers', BULLY_LOCK_WORKERS)
      end

      def self.contended_count(entry)
        entry.fetch('contended_count', CONTENDED_COUNT).to_i
      end

      def self.expect_kernel_config(name, expected)
        expected_line = "#{name}=#{expected}"
        status, output = machine.execute(
          "timeout 30 sh -c " \
          "#{Shellwords.escape("gzip -dc /proc/config.gz | grep -Fx #{Shellwords.escape(expected_line)}")}",
          timeout: 45
        )
        expect(status).to eq(0),
          "#{expected_line} is missing from /proc/config.gz: #{output}"
      end

      def self.expect_clean_kernel_log(log)
        bad = /
          BUG:|
          WARNING:|
          Oops:|
          kernel\s+BUG|
          general\s+protection\s+fault|
          psi:\s+inconsistent\s+task\s+state|
          INFO:\s+task\s+.+\s+blocked\s+for\s+more\s+than|
          rcu:.*stall|
          RCU\s+stall|
          soft\s+lockup|
          hard\s+LOCKUP
        /x

        expect(log).not_to match(bad)
      end

      def self.emit_progress(label, phase, extra = {})
        payload = {
          'label' => label,
          'phase' => phase,
          'time_epoch' => Time.now.to_i,
        }.merge(extra)

        puts "proxy-lock-badneighbor-progress #{JSON.generate(payload)}"
      end

      def self.delete_container(ctid)
        machine.execute(
          "timeout 30 osctl ct stop #{ctid} >/dev/null 2>&1 || true",
          timeout: 45
        )
        machine.execute(
          "timeout 90 osctl ct del -f --prune #{ctid} >/dev/null 2>&1 || true",
          timeout: 105
        )
        @ct_info_cache.delete(ctid)
      end

      def self.cleanup_containers
        CLEANUP_CT_IDS.each { |ctid| delete_container(ctid) }
      end

      def self.container_exists?(ctid)
        status, = machine.execute(
          "osctl ct show #{ctid} >/dev/null 2>&1",
          timeout: 60
        )

        status == 0
      rescue OsVm::TimeoutError
        false
      end

      def self.wait_until_container_exec(ctid, timeout:)
        machine.wait_until_succeeds(
          "osctl ct exec #{ctid} true",
          timeout:
        )
      end

      def self.container_running?(ctid)
        status, output = machine.execute("osctl -j ct show #{ctid}", timeout: 60)
        return false unless status == 0

        JSON.parse(output).fetch('state') == 'running'
      rescue JSON::ParserError, KeyError, OsVm::TimeoutError
        false
      end

      def self.start_container(ctid)
        status, output = machine.execute("osctl ct start #{ctid}", timeout: 120)
        return if status == 0
        return if container_running?(ctid)

        expect(status).to eq(0),
          "osctl ct start #{ctid} failed and container is not running: #{output}"
      end

      def self.setup_container(ctid)
        machine.all_succeed(
          "osctl ct new --distribution alpine #{ctid}",
          "osctl ct unset start-menu #{ctid}",
          "osctl ct netif new bridge --link lxcbr0 #{ctid} eth0"
        )
        start_container(ctid)
        wait_until_container_exec(ctid, timeout: 120)
        ct_info(ctid, true)
      end

      def self.parse_cpu_stat(output)
        output.lines.each_with_object({}) do |line, acc|
          key, value = line.split
          next if key.nil? || value.nil?

          acc[key] = value.to_i
        end
      end

      def self.cpu_stat(ctid)
        group_path = ct_info(ctid).fetch('group_path')
        candidate_paths = [
          group_path.sub(%r{/user-owned\z}, ""),
          group_path,
        ].uniq
        escaped_paths = candidate_paths.map { |path| Shellwords.escape(path) }.join(' ')

        script = <<~SH
          set -eu
          for group_path in #{escaped_paths}; do
            rel_path="''${group_path#/}"
            for base in /run/osctl/cgroup /sys/fs/cgroup; do
              stat_path="$base/$rel_path/cpu.stat"
              if [ -f "$stat_path" ]; then
                cat "$stat_path"
                exit 0
              fi
            done
          done

          fallback="$(find /run/osctl/cgroup /sys/fs/cgroup \\
            \\( -path "*/ct.#{ctid}/cpu.stat" -o -path "*/ct.#{ctid}/user-owned/cpu.stat" \\) \\
            -print -quit 2>/dev/null || true)"

          if [ -n "$fallback" ]; then
            cat "$fallback"
            exit 0
          fi

          echo "cpu.stat not found for #{ctid}: group_path=$group_path" >&2
          exit 1
        SH

        parse_cpu_stat(machine.succeeds(script)[1])
      end

      def self.cgroup_rel_path(cgroup)
        path = cgroup.to_s.split(':', 3).last.to_s
        path.start_with?('/') ? path[1..] : path
      end

      def self.cpu_controller_snapshot(*cgroups)
        paths = cgroups
          .compact
          .map { |cgroup| cgroup_rel_path(cgroup) }
          .reject(&:empty?)
          .uniq
        return [] if paths.empty?

        escaped_paths = paths.map { |path| Shellwords.escape(path) }.join(' ')
        script = <<~SH
          set -eu
          for rel_path in #{escaped_paths}; do
            for base in /run/osctl/cgroup /sys/fs/cgroup; do
              dir="$base/$rel_path"
              [ -d "$dir" ] || continue
              printf 'path=%s\\n' "$rel_path"
              for file in cpu.max cpu.weight cpu.weight.nice cpu.stat cpu.shares cpu.cfs_quota_us cpu.cfs_period_us; do
                [ -e "$dir/$file" ] || continue
                value="$(tr '\\n' ';' <"$dir/$file")"
                printf '%s=%s\\n' "$file" "$value"
              done
              printf '\\n'
              break
            done
          done
        SH

        status, output = machine.execute(script, timeout: 30)
        return [{ 'error' => output.lines.last(20).join }] unless status == 0

        output.split(/\n\n+/).filter_map do |block|
          row = {}
          block.lines.each do |line|
            key, value = line.chomp.split('=', 2)
            next if key.nil? || value.nil?

            row[key] = value
          end
          row.empty? ? nil : row
        end
      rescue OsVm::TimeoutError
        [{ 'error' => 'timeout' }]
      end

      def self.nr_throttled(stat)
        stat.fetch('nr_throttled', 0)
      end

      def self.throttled_usec(stat)
        stat.fetch('throttled_usec', 0)
      end

      def self.usage_usec(stat)
        stat.fetch('usage_usec', 0)
      end

      def self.lock_stats
        status, output = machine.execute(
          'timeout 10 sh -c ' \
            "'test -r /proc/proxy_lock_badneighbor_hold && " \
            "cat /proc/proxy_lock_badneighbor_hold'",
          timeout: 20
        )

        return { 'read_failed' => 1, 'read_status' => status } unless status == 0

        output.lines.each_with_object({}) do |line, acc|
          key, value = line.split
          next if key.nil? || value.nil?

          if value =~ /\A-?\d+\z/
            acc[key] = value.to_i
          else
            acc[key] = value
          end
        end
      rescue OsVm::TimeoutError
        { 'read_timeout' => 1 }
      end

      def self.sched_proxy_exec_diag
        status, output = machine.execute(
          'timeout 10 sh -c ' \
            "'test -r /proc/sched_proxy_exec_diag && " \
            "cat /proc/sched_proxy_exec_diag || true'",
          timeout: 20
        )

        return {} unless status == 0

        output.lines.each_with_object({}) do |line, acc|
          key, value = line.split
          next if key.nil? || value.nil?

          acc[key] = value.to_i
        end
      rescue OsVm::TimeoutError
        { 'read_timeout' => 1 }
      end

      def self.counter_delta(before, after)
        keys = before.keys | after.keys
        keys.each_with_object({}) do |key, acc|
          before_value = before.fetch(key, 0)
          after_value = after.fetch(key, 0)
          next unless before_value.is_a?(Numeric) && after_value.is_a?(Numeric)

          acc[key] = after_value - before_value
        end
      end

      def self.helper_delta_value(delta, operation, suffix)
        delta.fetch("#{operation}_#{suffix}", 0)
      end

      def self.measure_victim(lock_class, count, require_active: false)
        active_arg = require_active ? '1' : '0'
        active_min_age_ms = require_active ? ACTIVE_MIN_AGE_MS : 0
        active_min_offcpu_ms = require_active ? ACTIVE_MIN_OFFCPU_MS : 0
        runscript =
          "osctl ct runscript #{VICTIM_CT} /scripts/proxy-lock-measure.sh " \
          "#{Shellwords.escape(lock_class)} #{count} #{active_arg} " \
          "#{active_min_age_ms} #{active_min_offcpu_ms} " \
          "#{ACTIVE_WAIT_TIMEOUT_MS} #{ACTIVE_WAIT_ERROR_LIMIT}"
        command = <<~SH
          set -u

          out="$(mktemp /tmp/proxy-lock-victim.XXXXXX)"
          pid=
          status=
          timed_out=0

          request_helper_stop() {
            if [ -w /proc/proxy_lock_badneighbor_control ]; then
              printf stop >/proc/proxy_lock_badneighbor_control || true
            fi
          }

          cleanup() {
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              request_helper_stop
              kill "$pid" 2>/dev/null || true
              sleep 1
              kill -KILL "$pid" 2>/dev/null || true
              wait_for_exit "$pid" 2 >/dev/null 2>&1 || true
            fi
            rm -f "$out"
          }

          trap cleanup EXIT
          trap 'cleanup; exit 143' HUP INT TERM

          wait_for_exit() {
            target_pid="$1"
            wait_limit="$2"
            wait_elapsed=0

            while [ "$wait_elapsed" -lt "$wait_limit" ]; do
              if [ ! -e "/proc/$target_pid/stat" ]; then
                wait "$target_pid" 2>/dev/null || true
                return 0
              fi

              target_state="$(awk '{ print $3 }' "/proc/$target_pid/stat" 2>/dev/null || echo gone)"
              if [ "$target_state" = Z ] || [ "$target_state" = gone ]; then
                wait "$target_pid" 2>/dev/null || true
                return 0
              fi

              sleep 1
              wait_elapsed=$((wait_elapsed + 1))
            done

            return 1
          }

          #{runscript} >"$out" 2>&1 &
          pid=$!
          elapsed=0

          while :; do
            if [ ! -e "/proc/$pid/stat" ]; then
              wait "$pid" || status=$?
              pid=
              break
            fi

            state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || echo gone)"
            if [ "$state" = Z ] || [ "$state" = gone ]; then
              wait "$pid" || status=$?
              pid=
              break
            fi

            if [ "$elapsed" -ge #{VICTIM_MEASURE_TIMEOUT} ]; then
              timed_out=1
              echo "victim measurement timeout after #{VICTIM_MEASURE_TIMEOUT}s; requesting helper stop" >&2
              request_helper_stop

              grace=0
              while [ "$grace" -lt 15 ] && [ -e "/proc/$pid/stat" ]; do
                state="$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || echo gone)"
                if [ "$state" = Z ] || [ "$state" = gone ]; then
                  break
                fi
                sleep 1
                grace=$((grace + 1))
              done

              if [ -e "/proc/$pid/stat" ]; then
                kill "$pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$pid" 2>/dev/null || true
              fi
              if ! wait_for_exit "$pid" 3; then
                echo "victim process $pid still present after SIGKILL; leaving it for VM cleanup" >&2
              fi
              pid=
              break
            fi

            sleep 1
            elapsed=$((elapsed + 1))
          done

          cat "$out" || true

          if [ "$timed_out" -eq 1 ]; then
            exit 124
          fi

          if [ -n "$status" ]; then
            exit "$status"
          fi

          exit 0
        SH
        status, output = machine.execute(
          command,
          timeout: VICTIM_MEASURE_TIMEOUT + 75
        )

        if [124, 137].include?(status)
          return {
            'timeout' => true,
            'timeout_reason' => 'runner_timeout',
            'operation' => lock_class,
            'runner_exit_status' => status,
            'runner_output_tail' => output.lines.last(20).join,
          }
        end

        expect(status).to eq(0), output
        JSON.parse(output.lines.last)
      rescue OsVm::TimeoutError
        {
          'timeout' => true,
          'timeout_reason' => 'osvm_timeout',
          'operation' => lock_class,
        }
      end

      def self.holder_cgroup(pid)
        return nil if pid.to_i <= 0

        status, output = machine.execute(
          "cat /proc/#{pid}/cgroup 2>/dev/null || true",
          timeout: 30
        )
        status == 0 ? output.strip : nil
      end

      def self.relocate_bully_attach_processes
        group_path = ct_info(BULLY_CT).fetch('group_path')
        payload_rel =
          File.join(group_path, "lxc.payload.#{BULLY_CT}").sub(%r{\A/}, "")
        attach_rel = File.join(payload_rel, 'osctl.attach')
        escaped_payload_rel = Shellwords.escape(payload_rel)
        escaped_attach_rel = Shellwords.escape(attach_rel)

        status, output = machine.execute(
          <<~SH,
            set -eu
            payload=
            attach=
            for base in /run/osctl/cgroup /sys/fs/cgroup; do
              p="$base/#{escaped_payload_rel}"
              a="$base/#{escaped_attach_rel}"
              if [ -d "$p" ] && [ -d "$a" ]; then
                payload="$p"
                attach="$a"
                break
              fi
            done

            if [ -z "$payload" ] || [ -z "$attach" ]; then
              echo "payload or attach cgroup not found: payload=#{payload_rel} attach=#{attach_rel}" >&2
              exit 1
            fi

            total=0
            remaining=0
            i=0
            while [ "$i" -lt 80 ]; do
              moved=0
              procs_files="$(find "$attach" -maxdepth 3 -type f -name cgroup.procs -print 2>/dev/null || true)"

              for procs in $procs_files; do
                [ -f "$procs" ] || continue
                while read -r pid; do
                  [ -n "$pid" ] || continue
                  if echo "$pid" >"$payload/cgroup.procs" 2>/dev/null; then
                    moved=$((moved + 1))
                  fi
                done <"$procs"
              done

              total=$((total + moved))
              remaining="$(
                for procs in $procs_files; do
                  [ -f "$procs" ] || continue
                  sed '/^$/d' "$procs"
                done | wc -l
              )"
              remaining="''${remaining##* }"

              if [ "$total" -gt 0 ] && [ "$remaining" -eq 0 ]; then
                echo "moved=$total remaining=$remaining payload=$payload attach=$attach"
                exit 0
              fi

              sleep 0.1
              i=$((i + 1))
            done

            echo "attach processes remained after relocation: moved=$total remaining=$remaining payload=$payload attach=$attach" >&2
            find "$attach" -maxdepth 3 -type f -name cgroup.procs -print -exec cat {} \\; >&2 || true
            exit 1
          SH
          timeout: 60
        )

        expect(status).to eq(0), output
        output
      end

      def self.ct_info(ctid, refresh = false)
        if refresh || !@ct_info_cache.key?(ctid)
          @ct_info_cache[ctid] = machine.osctl_json("ct show #{ctid}")
        end

        @ct_info_cache.fetch(ctid)
      end

      def self.ct_rootfs(ctid)
        ct_info(ctid).fetch('rootfs')
      end

      def self.ct_host_path(ctid, path)
        rootfs = ct_rootfs(ctid)
        rel_path = path.start_with?('/') ? path[1..] : path
        File.join(rootfs, rel_path)
      end

      def self.install_ct_file(ctid, source, destination, mode:)
        machine.succeeds(
          "install -D -m #{Shellwords.escape(mode)} " \
          "#{Shellwords.escape(source)} " \
          "#{Shellwords.escape(ct_host_path(ctid, destination))}",
          timeout: 30
        )
      end

      def self.start_ct_runscript_host_job(name, ctid, script_path, args)
        log_path = "/tmp/#{name}-runscript.log"
        pid_path = "/tmp/#{name}-runscript.pid"
        command = "osctl ct runscript #{ctid} " \
                  "#{Shellwords.escape(script_path)} #{args}"
        runner = <<~SH
          set -eu
          rm -f #{Shellwords.escape(log_path)} #{Shellwords.escape(pid_path)}
          nohup sh -c #{Shellwords.escape(command)} \\
            >#{Shellwords.escape(log_path)} 2>&1 </dev/null &
          echo $! >#{Shellwords.escape(pid_path)}
        SH

        status, output = machine.execute(runner, timeout: 30)
        expect(status).to eq(0), output
        {
          'name' => name,
          'log_path' => log_path,
          'pid_path' => pid_path,
          'placement' => "runscript-background command=#{command}",
        }
      end

      def self.wait_for_ct_host_path(ctid, path, timeout:)
        host_path = ct_host_path(ctid, path)
        deadline = Time.now + timeout

        loop do
          status, = machine.execute(
            "test -e #{Shellwords.escape(host_path)}",
            timeout: 5
          )
          return host_path if status == 0

          break if Time.now >= deadline
          sleep 0.1
        end

        status, output = machine.execute(
          "ls -la #{Shellwords.escape(File.dirname(host_path))} 2>&1 || true; " \
          "for f in /tmp/proxy-*-runscript.log /tmp/proxy-*-start.log; do " \
          "[ -f \"$f\" ] || continue; echo FILE:$f; tail -n 80 \"$f\"; done",
          timeout: 10
        )
        fail "timed out waiting for #{path} in #{ctid} " \
             "(host path #{host_path}, status #{status}): #{output}"
      end

      def self.host_touch_ct_file(ctid, path)
        host_path = ct_host_path(ctid, path)
        status, output = machine.execute(
          "touch #{Shellwords.escape(host_path)}",
          timeout: 30
        )

        [status, output, host_path]
      end

      def self.apply_bully_pressure
        case PRESSURE_MODE
        when 'quota'
          machine.succeeds(
            "osctl ct set cpu-limit #{BULLY_CT} #{BULLY_CPU_LIMIT}",
            timeout: 60
          )
          "pressure=quota cpu_limit=#{BULLY_CPU_LIMIT}"
        when 'weight'
          machine.succeeds(
            <<~SH,
              set -eu
              if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
                osctl ct cgparams set -v 2 #{BULLY_CT} cpu.weight #{BULLY_CPU_WEIGHT}
              else
                osctl ct cgparams set -v 1 #{BULLY_CT} cpu.shares #{BULLY_CPU_SHARES}
              fi
            SH
            timeout: 60
          )
          "pressure=weight cpu_weight=#{BULLY_CPU_WEIGHT} cpu_shares=#{BULLY_CPU_SHARES}"
        else
          raise "unsupported pressure mode #{PRESSURE_MODE.inspect}"
        end
      end

      def self.clear_bully_pressure
        case PRESSURE_MODE
        when 'quota'
          machine.succeeds(
            "timeout 30 osctl ct unset cpu-limit #{BULLY_CT}",
            timeout: 60
          )
          {
            'pressure_unset' => true,
            'cpu_limit_unset' => true,
          }
        when 'weight'
          status, output = machine.execute(
            <<~SH,
              set -u
              if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
                timeout 30 osctl ct cgparams unset -v 2 #{BULLY_CT} cpu.weight
              else
                timeout 30 osctl ct cgparams unset -v 1 #{BULLY_CT} cpu.shares
              fi
            SH
            timeout: 60
          )
          {
            'pressure_unset' => status == 0,
            'cpu_weight_unset' => status == 0,
            'pressure_unset_status' => status,
            'pressure_unset_output_tail' => output.lines.last(20).join,
          }
        else
          raise "unsupported pressure mode #{PRESSURE_MODE.inspect}"
        end
      end

      def self.start_bully(entry)
        lock_class = lock_operation(entry)
        workers = lock_workers(entry)
        start_args = [
          'run',
          "CPU_WORKERS=#{BULLY_CPU_WORKERS}",
          "LOCK_WORKERS=#{workers}",
          "LOCK_CLASS=#{lock_class}",
          "LOCK_HOLD_US=#{BULLY_LOCK_HOLD_US}",
          "LOCK_HOLD_REPS=#{BULLY_LOCK_HOLD_REPS}",
          "LOCK_HOLD_YIELD_US=#{BULLY_LOCK_HOLD_YIELD_US}",
        ].map { |arg| Shellwords.escape(arg) }.join(' ')

        start_job = start_ct_runscript_host_job('proxy-lock-start',
                                                BULLY_CT,
                                                '/scripts/proxy-lock-control.sh',
                                                start_args)

        wait_for_ct_host_path(BULLY_CT,
                              '/var/tmp/proxy-lock/proxy-lock.pid',
                              timeout: 30)
        wait_for_ct_host_path(BULLY_CT,
                              '/var/tmp/proxy-lock/proxy-lock.log',
                              timeout: 30)

        relocation = relocate_bully_attach_processes
        pressure = apply_bully_pressure
        "#{start_job.fetch('placement')} #{relocation} #{pressure}"
      end

      def self.stop_bully(assume_exists = false)
        cached = @ct_info_cache.key?(BULLY_CT)
        exists = assume_exists || cached || container_exists?(BULLY_CT)
        info = {
          'container_exists' => exists,
          'stop_method' => 'host-rootfs-sentinel+proc-stop',
          'stop_file_touched' => false,
          'proc_stop_requested' => false,
          'pressure_mode' => PRESSURE_MODE,
          'pressure_unset' => false,
          'cpu_limit_unset' => false,
          'cpu_weight_unset' => false,
          'stop_status' => nil,
        }

        return info unless exists

        begin
          status, output, host_path =
            host_touch_ct_file(BULLY_CT,
                               '/var/tmp/proxy-lock/proxy-lock.stop')
          info['stop_status'] = status
          info['stop_file'] = host_path
          info['stop_output_tail'] = output.lines.last(20).join
          info['stop_file_touched'] = status == 0
        rescue StandardError => e
          info['stop_status'] = 'error'
          info['stop_error'] = e.message
        end

        begin
          status, output = machine.execute(
            'test -w /proc/proxy_lock_badneighbor_control && ' \
            'printf stop >/proc/proxy_lock_badneighbor_control',
            timeout: 30
          )
          info['proc_stop_status'] = status
          info['proc_stop_output_tail'] = output.lines.last(20).join
          info['proc_stop_requested'] = status == 0
        rescue StandardError => e
          info['proc_stop_status'] = 'error'
          info['proc_stop_error'] = e.message
        end

        begin
          info.merge!(clear_bully_pressure)
        rescue StandardError => e
          info['pressure_unset_error'] = e.message
        end

        info
      end

      def self.wait_for_bully_pressure_ready(lock_class, before_stat)
        deadline = Time.now + 120
        last = nil

        loop do
          stats = lock_stats
          if stats.fetch('active') == 1 && stats.fetch('active_class') == lock_class
            cgroup = holder_cgroup(stats.fetch('active_pid'))
            in_bully_cgroup = !cgroup.nil? && cgroup.include?("ct.#{BULLY_CT}")
            in_payload_cgroup = !cgroup.nil? && cgroup.include?("lxc.payload.#{BULLY_CT}")
            in_attach_cgroup = !cgroup.nil? && cgroup.include?('osctl.attach')
            warm_stat = cpu_stat(BULLY_CT)
            user_owned_path = ct_info(BULLY_CT).fetch('group_path')
            ct_path = user_owned_path.sub(%r{/user-owned\z}, "")
            cpu_controller =
              cpu_controller_snapshot(ct_path, user_owned_path, cgroup)
            warm_throttle_delta = nr_throttled(warm_stat) - nr_throttled(before_stat)
            warm_throttled_usec_delta =
              throttled_usec(warm_stat) - throttled_usec(before_stat)
            warm_usage_usec_delta =
              usage_usec(warm_stat) - usage_usec(before_stat)
            last = {
              'stats' => stats,
              'cgroup' => cgroup,
              'warm_cpu_stat' => warm_stat,
              'warm_throttle_delta' => warm_throttle_delta,
              'warm_throttled_usec_delta' => warm_throttled_usec_delta,
              'warm_usage_usec_delta' => warm_usage_usec_delta,
              'pressure_mode' => PRESSURE_MODE,
              'holder_in_bully_cgroup' => in_bully_cgroup,
              'holder_in_payload_cgroup' => in_payload_cgroup,
              'holder_in_attach_cgroup' => in_attach_cgroup,
              'cpu_controller' => cpu_controller,
            }

            expect(in_bully_cgroup).to eq(true),
              "active holder is not in #{BULLY_CT}'s cgroup: #{last.inspect}"
            expect(in_payload_cgroup).to eq(true),
              "active holder is not in #{BULLY_CT}'s payload cgroup: #{last.inspect}"
            expect(in_attach_cgroup).to eq(false),
              "active holder is in osctl.attach instead of payload workload: #{last.inspect}"

            pressure_ready =
              case PRESSURE_MODE
              when 'quota'
                warm_throttle_delta >= WARM_THROTTLE_EVENTS_MIN &&
                  warm_usage_usec_delta > 0 &&
                  (WARM_THROTTLED_USEC_MIN <= 0 ||
                   warm_throttled_usec_delta >= WARM_THROTTLED_USEC_MIN)
              when 'weight'
                warm_usage_usec_delta > 0
              else
                false
              end

            if pressure_ready
              return last
            end
          end

          break if Time.now >= deadline
          sleep 0.05
        end

        fail "holder for #{lock_class} did not become pressure-ready under #{PRESSURE_MODE}: " \
             "last=#{last.inspect} current=#{lock_stats.inspect} before=#{before_stat.inspect}"
      end

      def self.ratio(contended, baseline, key)
        return nil if contended['timeout']

        base = [baseline.fetch(key).to_f, 0.001].max
        contended.fetch(key).to_f / base
      end

      def self.enabled_proxy_activity_observed?(lock_class, result)
        diag = result.fetch('sched_proxy_exec_diag_measure_delta')
        return false unless diag.fetch('attempts', 0) > 0
        return false unless diag.fetch('success', 0) > 0

        case lock_class
        when 'mutex', 'ww_mutex'
          diag.fetch('mutex_donor_selected', 0) > 0 ||
            diag.fetch('mutex_chain_selected', 0) > 0 ||
            diag.fetch('success', 0) > 0
        when 'rtmutex'
          diag.fetch('chain_rtmutex_owner', 0) > 0
        when 'rwsem_write'
          diag.fetch('chain_rwsem_writer', 0) > 0
        when 'rwsem_read_single'
          diag.fetch('chain_rwsem_reader_single', 0) > 0
        when 'rwsem_read_multi'
          diag.fetch('chain_rwsem_reader_representative', 0) > 0
        when 'percpu_rwsem_write'
          diag.fetch('chain_percpu_rwsem_writer', 0) > 0
        when 'percpu_rwsem_read_representative'
          diag.fetch('chain_percpu_rwsem_reader_representative', 0) > 0
        else
          true
        end
      end

      def self.enabled_punishment_observed?(result)
        diag = result.fetch('sched_proxy_exec_diag_measure_delta')
        base =
          result.fetch('measure_usage_usec_delta', 0) > 0 &&
          diag.fetch('donated_runtime_events', 0) > 0 &&
          diag.fetch('donated_runtime_ns', 0) > 0
        return false unless base

        case result.fetch('pressure_mode', 'quota')
        when 'quota'
          result.fetch('measure_throttle_delta', 0) > 0 &&
            (
              diag.fetch('donated_runtime_owner_hierarchy_throttled_ns', 0) > 0 ||
              diag.fetch('success_owner_hierarchy_throttled', 0) > 0
            )
        when 'weight'
          true
        else
          false
        end
      end

      def self.lock_class_summary(enabled_results, disabled_results)
        per_class = {}
        SELECTED_LOCK_CLASSES.each do |entry|
          lock_class = entry.fetch('name')
          enabled = enabled_results.fetch(lock_class)
          disabled = disabled_results[lock_class]
          enabled_contended = enabled.fetch('contended')
          disabled_contended = disabled && disabled.fetch('contended')
          enabled_diag =
            enabled.fetch('sched_proxy_exec_diag_measure_delta')
          enabled_timed_out = enabled_contended['timeout'] == true
          enabled_proxy_activity =
            enabled_proxy_activity_observed?(lock_class, enabled)
          enabled_punishment =
            enabled_punishment_observed?(enabled)
          enabled_proxy_signal =
            !enabled_timed_out &&
              enabled_proxy_activity &&
              enabled_punishment
          disabled_materially_worse =
            if enabled_timed_out || disabled_contended.nil?
              false
            else
              disabled_contended['timeout'] ||
                disabled_contended.fetch('p99_ms') >
                  [enabled_contended.fetch('p99_ms') * 2.0, enabled.fetch('baseline').fetch('p99_ms') * 4.0].max ||
                disabled_contended.fetch('max_ms') >
                  [enabled_contended.fetch('max_ms') * 2.0, enabled.fetch('baseline').fetch('max_ms') * 4.0].max
            end

          per_class[lock_class] = {
            'proxy_scope' => entry.fetch('proxy_scope'),
            'pressure_mode' => enabled.fetch('pressure_mode', PRESSURE_MODE),
            'vm_cpus' => enabled.fetch('vm_cpus', VM_CPUS),
            'bully_cpu_limit' => enabled.fetch('bully_cpu_limit', BULLY_CPU_LIMIT),
            'bully_cpu_weight' =>
              enabled.fetch('bully_cpu_weight', BULLY_CPU_WEIGHT),
            'bully_cpu_shares' =>
              enabled.fetch('bully_cpu_shares', BULLY_CPU_SHARES),
            'bully_cpu_workers' =>
              enabled.fetch('bully_cpu_workers', BULLY_CPU_WORKERS),
            'bully_lock_workers' =>
              enabled.fetch('bully_lock_workers', lock_workers(entry)),
            'bully_lock_hold_yield_us' =>
              enabled.fetch('bully_lock_hold_yield_us', BULLY_LOCK_HOLD_YIELD_US),
            'production_objective_validated' =>
              enabled_proxy_signal &&
                disabled_materially_worse,
            'enabled_timed_out' => enabled_timed_out,
            'enabled_proxy_activity_observed' => enabled_proxy_activity,
            'enabled_punishment_observed' => enabled_punishment,
            'enabled_proxy_signal_observed' => enabled_proxy_signal,
            'enabled_proxy_attempts' => enabled_diag.fetch('attempts', 0),
            'enabled_proxy_success' => enabled_diag.fetch('success', 0),
            'enabled_donated_runtime_events' =>
              enabled_diag.fetch('donated_runtime_events', 0),
            'enabled_donated_runtime_ns' =>
              enabled_diag.fetch('donated_runtime_ns', 0),
            'enabled_donated_runtime_owner_hierarchy_throttled_ns' =>
              enabled_diag.fetch('donated_runtime_owner_hierarchy_throttled_ns', 0),
            'enabled_usage_usec_delta' => enabled.fetch('usage_usec_delta', 0),
            'enabled_throttle_delta' => enabled.fetch('throttle_delta', 0),
            'enabled_throttled_usec_delta' =>
              enabled.fetch('throttled_usec_delta', 0),
            'enabled_measure_usage_usec_delta' =>
              enabled.fetch('measure_usage_usec_delta', 0),
            'enabled_measure_throttle_delta' =>
              enabled.fetch('measure_throttle_delta', 0),
            'enabled_measure_throttled_usec_delta' =>
              enabled.fetch('measure_throttled_usec_delta', 0),
            'enabled_holder_hold_runtime_us_delta' =>
              enabled.fetch('holder_hold_runtime_us_delta', 0),
            'enabled_holder_hold_offcpu_us_delta' =>
              enabled.fetch('holder_hold_offcpu_us_delta', 0),
            'enabled_holder_hold_yields_delta' =>
              enabled.fetch('holder_hold_yields_delta', 0),
            'disabled_control_reproduced_materially_worse' => disabled_materially_worse,
            'enabled_p99_ms' => enabled_timed_out ? nil : enabled_contended.fetch('p99_ms'),
            'enabled_max_ms' => enabled_timed_out ? nil : enabled_contended.fetch('max_ms'),
            'disabled_p99_ms' =>
              disabled_contended.nil? || disabled_contended['timeout'] ? nil : disabled_contended.fetch('p99_ms'),
            'disabled_max_ms' =>
              disabled_contended.nil? || disabled_contended['timeout'] ? nil : disabled_contended.fetch('max_ms'),
            'classification' =>
              if enabled_timed_out
                'proxy-enabled-timeout'
              elsif !enabled_proxy_activity
                'proxy-activity-not-observed'
              elsif !enabled_punishment
                'punishment-not-observed'
              elsif disabled_contended.nil?
                'proxy-signal-observed'
              elsif disabled_materially_worse
                'validated'
              else
                'control-did-not-reproduce-materially-worse'
              end,
          }
        end

        {
          'require_validation' => REQUIRE_VALIDATION,
          'selected_lock_classes' =>
            SELECTED_LOCK_CLASSES.map { |entry| entry.fetch('name') },
          'production_objective_validated' =>
            per_class.values.all? { |row| row.fetch('production_objective_validated') },
          'enabled_proxy_signal_observed' =>
            per_class.values.all? { |row| row.fetch('enabled_proxy_signal_observed') },
          'run_disabled_control' => RUN_DISABLED_CONTROL,
          'full_matrix' => FULL_MATRIX,
          'classes' => per_class,
          'classification' =>
            if per_class.values.all? { |row| row.fetch('production_objective_validated') }
              'validated'
            elsif per_class.values.all? { |row| row.fetch('enabled_proxy_signal_observed') }
              'proxy-signal-observed'
            else
              'not-validated'
            end,
        }
      end

      def self.run_lock_contention(label, proxy_arg, expected_boot_message)
        kernel_params = [
          proxy_arg,
          'oops=panic',
          'softlockup_panic=1',
          'hardlockup_panic=1',
          'hung_task_panic=1',
        ]

        emit_progress(label, 'boot-start',
                      'proxy_arg' => proxy_arg,
                      'selected_lock_classes' =>
                        SELECTED_LOCK_CLASSES.map { |entry| entry.fetch('name') })
        machine.stop if machine.running?
        machine.start(kernel_params:)
        machine.wait_for_osctl_pool('tank', timeout: 45 * 60)
        machine.wait_until_online
        emit_progress(label, 'boot-online', 'proxy_arg' => proxy_arg)

        expect_kernel_config('CONFIG_SCHED_PROXY_EXEC', 'y')
        expect_kernel_config('CONFIG_PSI', 'n')

        cmdline = machine.succeeds('cat /proc/cmdline')[1]
        expect(cmdline).to include(proxy_arg)
        boot_log = machine.succeeds('dmesg')[1]
        expect(boot_log).to include(expected_boot_message)

        machine.succeeds('modprobe proxy_lock_badneighbor')
        machine.succeeds('test -w /proc/proxy_lock_badneighbor_hold')
        machine.succeeds('test -w /proc/proxy_lock_badneighbor_probe')
        machine.succeeds('dmesg -C || true')
        emit_progress(label, 'harness-ready', 'proxy_arg' => proxy_arg)

        cleanup_containers
        machine.mkdir_p('/scripts')
        machine.push_file('${lockControl}', '/scripts/proxy-lock-control.sh')
        machine.push_file('${lockMeasure}', '/scripts/proxy-lock-measure.sh')

        setup_container(BULLY_CT)
        setup_container(VICTIM_CT)
        install_ct_file(BULLY_CT, '/scripts/proxy-lock-control.sh',
                        '/scripts/proxy-lock-control.sh', mode: '500')
        install_ct_file(VICTIM_CT, '/scripts/proxy-lock-measure.sh',
                        '/scripts/proxy-lock-measure.sh', mode: '500')
        emit_progress(label, 'containers-ready')

        machine.succeeds("osctl ct exec #{BULLY_CT} test -w /proc/proxy_lock_badneighbor_hold")
        machine.succeeds("osctl ct exec #{VICTIM_CT} test -w /proc/proxy_lock_badneighbor_probe")

        results = {}
        SELECTED_LOCK_CLASSES.each do |entry|
          lock_class = entry.fetch('name')
          lock_operation = lock_operation(entry)
          lock_workers = lock_workers(entry)
          measure_count = contended_count(entry)
          progress_base = {
            'lock_class' => lock_class,
            'lock_operation' => lock_operation,
            'proxy_scope' => entry.fetch('proxy_scope'),
          }

          emit_progress(label, 'baseline-start', progress_base)
          baseline = measure_victim(lock_operation, BASELINE_COUNT)
          expect(baseline['timeout']).not_to eq(true), "baseline timed out for #{label}/#{lock_class}"
          expect(baseline.fetch('errors')).to eq(0), "baseline errors for #{label}/#{lock_class}: #{baseline.inspect}"
          emit_progress(label, 'baseline-done',
                        progress_base.merge('samples' => baseline.fetch('samples', nil),
                                            'errors' => baseline.fetch('errors', nil)))

          emit_progress(label, 'bully-start', progress_base)
          bully_relocation = start_bully(entry)
          before_stat = cpu_stat(BULLY_CT)
          warm = wait_for_bully_pressure_ready(lock_operation, before_stat)
          emit_progress(label, 'warm-ready',
                        progress_base.merge(
                          'pressure_mode' => PRESSURE_MODE,
                          'warm_throttle_delta' => warm.fetch('warm_throttle_delta'),
                          'warm_usage_usec_delta' => warm.fetch('warm_usage_usec_delta')
                        ))
          proxy_diag_before_measure = sched_proxy_exec_diag
          helper_stat_before_measure = lock_stats
          emit_progress(label, 'contended-start',
                        progress_base.merge('victim_measure_count' => measure_count,
                                            'victim_measure_timeout_sec' => VICTIM_MEASURE_TIMEOUT))
          contended = measure_victim(lock_operation, measure_count,
                                     require_active: true)
          timed_out = contended['timeout'] == true
          emit_progress(label, 'contended-done',
                        progress_base.merge(
                          'timeout' => timed_out,
                          'timeout_reason' => contended['timeout_reason'],
                          'samples' => contended['samples'],
                          'errors' => contended['errors']
                        ))
          proxy_diag_after_measure =
            if timed_out
              begin
                sched_proxy_exec_diag
              rescue StandardError => e
                proxy_diag_before_measure.merge(
                  'post_timeout_read_failed' => 1,
                  'post_timeout_read_error' => e.message
                )
              end
            else
              sched_proxy_exec_diag
            end
          helper_stat_before_stop =
            begin
              lock_stats
            rescue StandardError => e
              helper_stat_before_measure.merge(
                'post_timeout_read_failed' => 1,
                'post_timeout_read_error' => e.message
              )
            end
          after_stat =
            begin
              cpu_stat(BULLY_CT)
            rescue StandardError
              warm.fetch('warm_cpu_stat')
            end

          throttle_delta = nr_throttled(after_stat) - nr_throttled(before_stat)
          throttled_usec_delta =
            throttled_usec(after_stat) - throttled_usec(before_stat)
          usage_usec_delta =
            usage_usec(after_stat) - usage_usec(before_stat)
          measure_throttle_delta =
            nr_throttled(after_stat) - nr_throttled(warm.fetch('warm_cpu_stat'))
          measure_throttled_usec_delta =
            throttled_usec(after_stat) -
              throttled_usec(warm.fetch('warm_cpu_stat'))
          measure_usage_usec_delta =
            usage_usec(after_stat) - usage_usec(warm.fetch('warm_cpu_stat'))
          warm_usage_usec_delta =
            usage_usec(warm.fetch('warm_cpu_stat')) - usage_usec(before_stat)
          proxy_diag_measure_delta =
            counter_delta(proxy_diag_before_measure, proxy_diag_after_measure)
          helper_measure_delta =
            counter_delta(helper_stat_before_measure, helper_stat_before_stop)
          holder_hold_runs_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'hold_runs')
          holder_hold_runtime_us_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'hold_total_runtime_us')
          holder_hold_offcpu_us_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'hold_total_offcpu_us')
          holder_hold_yields_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'hold_yields')
          holder_probe_runs_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'probe_runs')
          holder_probe_wait_us_delta =
            helper_delta_value(helper_measure_delta, lock_operation, 'probe_total_wait_us')
          if PRESSURE_MODE == 'quota'
            expect(throttle_delta).to be > 0,
              "bully CT did not throttle under #{label}/#{lock_class}: " \
              "before=#{before_stat.inspect} after=#{after_stat.inspect}"
          end
          expect(usage_usec_delta).to be > 0,
            "bully CT did not accrue CPU usage under #{label}/#{lock_class}: " \
            "before=#{before_stat.inspect} after=#{after_stat.inspect}"

          unless contended['timeout']
            expect(contended.fetch('errors')).to eq(0),
              "contended errors for #{label}/#{lock_class}: #{contended.inspect}"
          end

          stop_info = stop_bully
          if timed_out
            stop_info['after_timeout'] = true
            stop_info['reason'] = 'victim measurement timed out'
          end
          helper_stat_after_stop =
            begin
              lock_stats
            rescue StandardError
              helper_stat_before_stop
            end

          result = {
            'label' => label,
            'proxy_arg' => proxy_arg,
            'vm_cpus' => VM_CPUS,
            'lock_class' => lock_class,
            'lock_operation' => lock_operation,
            'proxy_scope' => entry.fetch('proxy_scope'),
            'pressure_mode' => PRESSURE_MODE,
            'bully_cpu_limit' => BULLY_CPU_LIMIT,
            'bully_cpu_weight' => BULLY_CPU_WEIGHT,
            'bully_cpu_shares' => BULLY_CPU_SHARES,
            'bully_cpu_workers' => BULLY_CPU_WORKERS,
            'bully_lock_workers' => lock_workers,
            'bully_lock_hold_us' => BULLY_LOCK_HOLD_US,
            'bully_lock_hold_reps' => BULLY_LOCK_HOLD_REPS,
            'bully_lock_hold_yield_us' => BULLY_LOCK_HOLD_YIELD_US,
            'active_min_age_ms' => ACTIVE_MIN_AGE_MS,
            'active_min_offcpu_ms' => ACTIVE_MIN_OFFCPU_MS,
            'victim_measure_timeout_sec' => VICTIM_MEASURE_TIMEOUT,
            'victim_measure_count' => measure_count,
            'baseline' => baseline,
            'contended' => contended,
            'p95_ratio' => ratio(contended, baseline, 'p95_ms'),
            'p99_ratio' => ratio(contended, baseline, 'p99_ms'),
            'max_ratio' => ratio(contended, baseline, 'max_ms'),
            'throttle_delta' => throttle_delta,
            'warm_throttle_delta' => warm.fetch('warm_throttle_delta'),
            'throttled_usec_delta' => throttled_usec_delta,
            'warm_throttled_usec_delta' => warm.fetch('warm_throttled_usec_delta'),
            'usage_usec_delta' => usage_usec_delta,
            'warm_usage_usec_delta' => warm_usage_usec_delta,
            'measure_throttle_delta' => measure_throttle_delta,
            'measure_throttled_usec_delta' => measure_throttled_usec_delta,
            'measure_usage_usec_delta' => measure_usage_usec_delta,
            'cpu_stat_before' => before_stat,
            'cpu_stat_warm' => warm.fetch('warm_cpu_stat'),
            'cpu_stat_after' => after_stat,
            'cpu_controller_warm' => warm.fetch('cpu_controller'),
            'cpu_controller_after' =>
              cpu_controller_snapshot(warm.fetch('cgroup')),
            'sched_proxy_exec_diag_before_measure' => proxy_diag_before_measure,
            'sched_proxy_exec_diag_after_measure' => proxy_diag_after_measure,
            'sched_proxy_exec_diag_measure_delta' => proxy_diag_measure_delta,
            'donated_runtime_events_delta' =>
              proxy_diag_measure_delta.fetch('donated_runtime_events', 0),
            'donated_runtime_ns_delta' =>
              proxy_diag_measure_delta.fetch('donated_runtime_ns', 0),
            'donated_runtime_owner_hierarchy_throttled_ns_delta' =>
              proxy_diag_measure_delta.fetch('donated_runtime_owner_hierarchy_throttled_ns', 0),
            'helper_before_measure' => helper_stat_before_measure,
            'helper_before_stop' => helper_stat_before_stop,
            'helper_after_stop' => helper_stat_after_stop,
            'helper_measure_delta' => helper_measure_delta,
            'holder_hold_runs_delta' => holder_hold_runs_delta,
            'holder_hold_runtime_us_delta' => holder_hold_runtime_us_delta,
            'holder_hold_offcpu_us_delta' => holder_hold_offcpu_us_delta,
            'holder_hold_yields_delta' => holder_hold_yields_delta,
            'holder_probe_runs_delta' => holder_probe_runs_delta,
            'holder_probe_wait_us_delta' => holder_probe_wait_us_delta,
            'holder_active_after_warm' => warm.fetch('stats'),
            'holder_cgroup' => warm.fetch('cgroup'),
            'holder_in_bully_cgroup' => warm.fetch('holder_in_bully_cgroup'),
            'holder_in_payload_cgroup' => warm.fetch('holder_in_payload_cgroup'),
            'holder_in_attach_cgroup' => warm.fetch('holder_in_attach_cgroup'),
            'bully_relocation' => bully_relocation,
            'stop' => stop_info,
          }

          puts "proxy-lock-badneighbor-result #{JSON.generate(result)}"
          emit_progress(label, 'result-emitted',
                        progress_base.merge('timeout' => timed_out,
                                            'timeout_reason' => contended['timeout_reason']))
          results[lock_class] = result
          if timed_out
            next
          end
        ensure
          begin
            stop_bully if machine.running?
          rescue StandardError
            nil
          end
        end

        cleanup_containers
        kernel_log = machine.succeeds('dmesg')[1]
        expect_clean_kernel_log(kernel_log)
        emit_progress(label, 'kernel-log-clean')
        machine.stop
        emit_progress(label, 'vm-stopped')
        results
      ensure
        begin
          stop_bully if machine.running?
        rescue StandardError
          nil
        end

        begin
          cleanup_containers if machine.running?
        rescue StandardError
          nil
        end

        begin
          machine.stop if machine.running?
        rescue StandardError
          nil
        end
      end

      enabled = run_lock_contention(
        'enabled',
        'sched_proxy_exec=1',
        'sched_proxy_exec enabled via boot arg'
      )

      disabled =
        if RUN_DISABLED_CONTROL
          run_lock_contention(
            'disabled-control',
            'sched_proxy_exec=0',
            'sched_proxy_exec disabled via boot arg'
          )
        else
          {}
        end

      summary = lock_class_summary(enabled, disabled)
      puts "proxy-lock-badneighbor-summary #{JSON.generate(summary)}"
      emit_progress('summary', 'summary-emitted',
                    'classification' => summary.fetch('classification'),
                    'enabled_proxy_signal_observed' =>
                      summary.fetch('enabled_proxy_signal_observed'),
                    'production_objective_validated' =>
                      summary.fetch('production_objective_validated'))

      if REQUIRE_PROXY_SIGNAL
        expect(summary.fetch('enabled_proxy_signal_observed')).to eq(true),
          "proxy-exec enabled-side signal missing: summary=#{summary.inspect} " \
          "enabled=#{enabled.inspect}"
      end

      if REQUIRE_VALIDATION
        expect(summary.fetch('production_objective_validated')).to eq(true),
          "not all lock classes validated: summary=#{summary.inspect} " \
          "enabled=#{enabled.inspect} disabled=#{disabled.inspect}"
      end
    '';
  }
)
