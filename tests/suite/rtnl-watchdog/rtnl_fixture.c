// SPDX-License-Identifier: GPL-2.0
/* Disposable VM fixture only. Never include this module in a production package. */
#include <linux/capability.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/proc_fs.h>
#include <linux/refcount.h>
#include <linux/rtnetlink.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define SLOT_COUNT 128
#define MAX_HOLD_MS 9000

struct fixture_slot {
  pid_t pid;
  char api[16];
  int result;
  bool active;
  bool acquired;
};

static struct fixture_slot slots[SLOT_COUNT];
static DEFINE_SPINLOCK(slots_lock);
static DECLARE_WAIT_QUEUE_HEAD(release_wait);
static atomic_t release_generation = ATOMIC_INIT(0);
static struct proc_dir_entry *fixture_dir;

static int reserve_slot(const char *api)
{
  unsigned long flags;
  int i;

  spin_lock_irqsave(&slots_lock, flags);
  for (i = 0; i < SLOT_COUNT; i++) {
    if (!slots[i].active) {
      memset(&slots[i], 0, sizeof(slots[i]));
      slots[i].pid = task_pid_nr(current);
      strscpy(slots[i].api, api, sizeof(slots[i].api));
      slots[i].active = true;
      break;
    }
  }
  spin_unlock_irqrestore(&slots_lock, flags);
  return i == SLOT_COUNT ? -ENOSPC : i;
}

static ssize_t call_write(struct file *file, const char __user *buffer,
                          size_t count, loff_t *offset)
{
  char command[64], api[16], extra;
  unsigned int hold_ms;
  unsigned long flags;
  refcount_t refs;
  int slot, generation, result = 0;
  bool acquired = false;

  if (!capable(CAP_SYS_ADMIN))
    return -EPERM;
  if (!count || count >= sizeof(command))
    return -EINVAL;
  if (copy_from_user(command, buffer, count))
    return -EFAULT;
  command[count] = '\0';
  if (sscanf(command, "%15s %u %c", api, &hold_ms, &extra) != 2 ||
      hold_ms > MAX_HOLD_MS)
    return -EINVAL;
  if (strcmp(api, "lock") && strcmp(api, "killable") &&
      strcmp(api, "try") && strcmp(api, "ref1") && strcmp(api, "ref2"))
    return -EINVAL;
  if (!try_module_get(THIS_MODULE))
    return -ENODEV;
  slot = reserve_slot(api);
  if (slot < 0) {
    module_put(THIS_MODULE);
    return slot;
  }
  generation = atomic_read(&release_generation);

  /* Run in the writer's task: tracing must observe its real nested cgroup. */
  if (!strcmp(api, "lock")) {
    rtnl_lock();
    acquired = true;
    result = 1;
  } else if (!strcmp(api, "killable")) {
    result = rtnl_lock_killable();
    acquired = !result;
  } else if (!strcmp(api, "try")) {
    result = rtnl_trylock();
    acquired = result;
  } else {
    refcount_set(&refs, !strcmp(api, "ref1") ? 1 : 2);
    result = refcount_dec_and_rtnl_lock(&refs);
    acquired = result;
  }

  spin_lock_irqsave(&slots_lock, flags);
  slots[slot].acquired = acquired;
  slots[slot].result = result;
  spin_unlock_irqrestore(&slots_lock, flags);

  if (acquired) {
    /* The wait has a kernel-side nine-second safety timeout even when the
     * userspace controller never sends its release request. */
    if (hold_ms)
      wait_event_timeout(release_wait,
                         atomic_read(&release_generation) != generation,
                         msecs_to_jiffies(hold_ms));
    rtnl_unlock();
  }

  spin_lock_irqsave(&slots_lock, flags);
  slots[slot].active = false;
  slots[slot].acquired = false;
  spin_unlock_irqrestore(&slots_lock, flags);
  module_put(THIS_MODULE);
  return result < 0 ? result : count;
}

static ssize_t release_write(struct file *file, const char __user *buffer,
                             size_t count, loff_t *offset)
{
  if (!capable(CAP_SYS_ADMIN))
    return -EPERM;
  /* Independent of RTNL and the per-call status lock. */
  atomic_inc(&release_generation);
  wake_up_all(&release_wait);
  return count;
}

static int status_show(struct seq_file *seq, void *unused)
{
  struct fixture_slot *snapshot;
  unsigned long flags;
  int i;

  snapshot = kmalloc(sizeof(slots), GFP_KERNEL);
  if (!snapshot)
    return -ENOMEM;
  spin_lock_irqsave(&slots_lock, flags);
  memcpy(snapshot, slots, sizeof(slots));
  spin_unlock_irqrestore(&slots_lock, flags);
  seq_puts(seq, "pid api active acquired result\n");
  for (i = 0; i < SLOT_COUNT; i++) {
    if (snapshot[i].pid)
      seq_printf(seq, "%d %s %u %u %d\n", snapshot[i].pid,
                 snapshot[i].api, snapshot[i].active,
                 snapshot[i].acquired, snapshot[i].result);
  }
  kfree(snapshot);
  return 0;
}

static int status_open(struct inode *inode, struct file *file)
{
  return single_open(file, status_show, NULL);
}

static const struct proc_ops call_ops = { .proc_write = call_write };
static const struct proc_ops release_ops = { .proc_write = release_write };
static const struct proc_ops status_ops = {
  .proc_open = status_open,
  .proc_read = seq_read,
  .proc_lseek = seq_lseek,
  .proc_release = single_release,
};

static int __init fixture_init(void)
{
  fixture_dir = proc_mkdir("rtnl_monitor_fixture", NULL);
  if (!fixture_dir)
    return -ENOMEM;
  if (!proc_create("call", 0200, fixture_dir, &call_ops) ||
      !proc_create("release", 0200, fixture_dir, &release_ops) ||
      !proc_create("status", 0400, fixture_dir, &status_ops)) {
    proc_remove(fixture_dir);
    return -ENOMEM;
  }
  return 0;
}

static void __exit fixture_exit(void)
{
  atomic_inc(&release_generation);
  wake_up_all(&release_wait);
  proc_remove(fixture_dir);
}

module_init(fixture_init);
module_exit(fixture_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Test-only bounded caller-context RTNL contention fixture");
