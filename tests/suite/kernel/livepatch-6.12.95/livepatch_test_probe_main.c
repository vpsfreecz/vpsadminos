// SPDX-License-Identifier: GPL-2.0

#include <linux/atomic.h>
#include <linux/cpumask.h>
#include <linux/jiffies.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/skbuff.h>
#include <linux/smp.h>
#include <linux/wait.h>

#include <asm/processor.h>

#include "livepatch_test_probe.h"

#ifndef CONFIG_X86_64
#error "livepatch_test_probe is only implemented for x86-64"
#endif

static int shadow_failures;
static atomic_t shadow_failures_injected = ATOMIC_INIT(0);

static unsigned long probe_address;
static unsigned long probe_arg0;
static unsigned long probe_arg2;
static atomic64_t probe_hits = ATOMIC64_INIT(0);
static cpumask_t probe_cpus;
static bool probe_hold;
static bool probe_held;
static bool probe_spin_hold;
static bool probe_clone_arg2;
static struct sk_buff *probe_arg2_clone;
static atomic_t probe_redirect_active = ATOMIC_INIT(0);
static struct task_struct *probe_resume_task;
static DECLARE_WAIT_QUEUE_HEAD(probe_waitq);
static unsigned long probe2_address;
static atomic64_t probe2_hits = ATOMIC64_INIT(0);
static atomic64_t probe2_match_hits = ATOMIC64_INIT(0);
static unsigned long probe3_address;
static atomic64_t probe3_hits = ATOMIC64_INIT(0);
static atomic64_t probe3_match_hits = ATOMIC64_INIT(0);
static unsigned long probe_match_arg0;
static DEFINE_MUTEX(probe_mutex);
static bool probe_registered;
static bool probe2_registered;
static bool probe3_registered;

unsigned long livepatch_test_probe_marker;
unsigned long livepatch_test_probe_resume;

static noinline notrace void *livepatch_test_return_null(void)
{
	return NULL;
}

static int livepatch_test_shadow_alloc_pre(struct kprobe *probe,
					   struct pt_regs *regs)
{
	int remaining;

	(void)probe;

	remaining = READ_ONCE(shadow_failures);
	while (remaining > 0) {
		int observed;

		observed = cmpxchg(&shadow_failures, remaining, remaining - 1);
		if (observed == remaining) {
			/*
			 * Redirect the probed function entry to a normal
			 * x86-64 return stub.  Returning nonzero tells kprobes
			 * not to single-step the original instruction, so the
			 * real klp_shadow_alloc() creates no shadow.
			 */
			regs->ip = (unsigned long)livepatch_test_return_null;
			atomic_inc(&shadow_failures_injected);
			return 1;
		}
		remaining = observed;
	}

	return 0;
}

static void livepatch_test_shadow_alloc_post(struct kprobe *probe,
					     struct pt_regs *regs,
					     unsigned long flags)
{
	(void)probe;
	(void)regs;
	(void)flags;
}

static struct kprobe shadow_alloc_probe = {
	.symbol_name = "klp_shadow_alloc",
	.pre_handler = livepatch_test_shadow_alloc_pre,
	/*
	 * A post-handler keeps this as a regular kprobe.  Optimized kprobes
	 * cannot honor the failure path's instruction-pointer redirection.
	 */
	.post_handler = livepatch_test_shadow_alloc_post,
};

static void livepatch_test_record_probe_hit(void)
{
	atomic64_inc(&probe_hits);
	cpumask_set_cpu(raw_smp_processor_id(), &probe_cpus);
}

NOKPROBE_SYMBOL(livepatch_test_record_probe_hit);

void notrace livepatch_test_wait_for_release(void)
{
	WRITE_ONCE(probe_held, true);
	wait_event(probe_waitq, !READ_ONCE(probe_hold));
	WRITE_ONCE(probe_resume_task, current);
	WRITE_ONCE(probe_held, false);
	atomic_set(&probe_redirect_active, 0);
	wake_up_all(&probe_waitq);
}

NOKPROBE_SYMBOL(livepatch_test_wait_for_release);
NOKPROBE_SYMBOL(livepatch_test_hold_trampoline);

static int livepatch_test_probe_pre(struct kprobe *probe,
				    struct pt_regs *regs)
{
	struct sk_buff *clone;
	struct sk_buff *old;

	(void)probe;

	if (READ_ONCE(probe_resume_task) == current) {
		WRITE_ONCE(probe_resume_task, NULL);
		wake_up_all(&probe_waitq);
		return 0;
	}
	if (READ_ONCE(probe_hold) &&
	    atomic_cmpxchg(&probe_redirect_active, 0, 1))
		return 0;
	livepatch_test_record_probe_hit();
	if (!READ_ONCE(probe_hold))
		return 0;
	WRITE_ONCE(probe_arg0, regs_get_kernel_argument(regs, 0));
	WRITE_ONCE(probe_arg2, regs_get_kernel_argument(regs, 2));
	if (READ_ONCE(probe_clone_arg2) && !READ_ONCE(probe_arg2_clone)) {
		clone = skb_clone((struct sk_buff *)READ_ONCE(probe_arg2),
				  GFP_ATOMIC);
		if (clone) {
			old = cmpxchg(&probe_arg2_clone, NULL, clone);
			if (old)
				kfree_skb(clone);
		}
	}
	if (READ_ONCE(probe_spin_hold)) {
		unsigned long deadline = jiffies + 5 * HZ;

		/*
		 * Some internal instruction sites have an established target
		 * frame but no function-entry stack alignment for the
		 * schedulable redirection trampoline. Keep the kprobe handler
		 * active for these bounded transition tests so the target task
		 * cannot switch patch state, then single-step the original
		 * instruction after release.
		 */
		WRITE_ONCE(probe_held, true);
		while (READ_ONCE(probe_hold) &&
		       time_before(jiffies, deadline))
			cpu_relax();
		if (READ_ONCE(probe_hold))
			WRITE_ONCE(probe_hold, false);
		WRITE_ONCE(probe_held, false);
		atomic_set(&probe_redirect_active, 0);
		wake_up_all(&probe_waitq);
		return 0;
	}

	instruction_pointer_set(regs,
				(unsigned long)livepatch_test_hold_trampoline);
	return 1;
}

NOKPROBE_SYMBOL(livepatch_test_probe_pre);

static void livepatch_test_probe_post(struct kprobe *probe,
				      struct pt_regs *regs,
				      unsigned long flags)
{
	(void)probe;
	(void)regs;
	(void)flags;
}

NOKPROBE_SYMBOL(livepatch_test_probe_post);

static struct kprobe target_probe = {
	.pre_handler = livepatch_test_probe_pre,
	/*
	 * A post-handler keeps this as a regular kprobe.  Optimized kprobes
	 * cannot honor the held path's instruction-pointer redirection.
	 */
	.post_handler = livepatch_test_probe_post,
};

static int livepatch_test_set_probe_hold(const char *value,
					 const struct kernel_param *param)
{
	bool hold;
	int ret;

	(void)param;
	ret = kstrtobool(value, &hold);
	if (ret)
		return ret;

	WRITE_ONCE(probe_hold, hold);
	if (!hold)
		wake_up_all(&probe_waitq);
	return 0;
}

static int livepatch_test_get_probe_hold(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%c\n",
			  READ_ONCE(probe_hold) ? 'Y' : 'N');
}

static const struct kernel_param_ops probe_hold_ops = {
	.set = livepatch_test_set_probe_hold,
	.get = livepatch_test_get_probe_hold,
};

static int livepatch_test_set_probe_clone_arg2(
	const char *value,
	const struct kernel_param *param)
{
	struct sk_buff *clone;
	bool enabled;
	int ret;

	(void)param;
	ret = kstrtobool(value, &enabled);
	if (ret)
		return ret;

	WRITE_ONCE(probe_clone_arg2, enabled);
	if (enabled)
		return 0;

	clone = xchg(&probe_arg2_clone, NULL);
	if (clone)
		kfree_skb(clone);

	return 0;
}

static int livepatch_test_get_probe_clone_arg2(
	char *buffer,
	const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%c\n",
			 READ_ONCE(probe_clone_arg2) ? 'Y' : 'N');
}

static const struct kernel_param_ops probe_clone_arg2_ops = {
	.set = livepatch_test_set_probe_clone_arg2,
	.get = livepatch_test_get_probe_clone_arg2,
};

static int livepatch_test_get_probe_arg2_clone_held(
	char *buffer,
	const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%c\n",
			 READ_ONCE(probe_arg2_clone) ? 'Y' : 'N');
}

static const struct kernel_param_ops probe_arg2_clone_held_ops = {
	.get = livepatch_test_get_probe_arg2_clone_held,
};

static int livepatch_test_probe2_pre(struct kprobe *probe,
				     struct pt_regs *regs)
{
	(void)probe;
	atomic64_inc(&probe2_hits);
	if (regs->di == READ_ONCE(probe_match_arg0))
		atomic64_inc(&probe2_match_hits);
	return 0;
}

static void livepatch_test_probe2_post(struct kprobe *probe,
				       struct pt_regs *regs,
				       unsigned long flags)
{
	(void)probe;
	(void)regs;
	(void)flags;
}

NOKPROBE_SYMBOL(livepatch_test_probe2_post);

static struct kprobe target_probe2 = {
	.pre_handler = livepatch_test_probe2_pre,
	/*
	 * Keep the second counter as a regular kprobe.  It is paired with the
	 * primary probe to prove that a distinct transition or producer path
	 * executed; an optimized probe must not obscure another probe in the
	 * same function.
	 */
	.post_handler = livepatch_test_probe2_post,
};

static int livepatch_test_probe3_pre(struct kprobe *probe,
				     struct pt_regs *regs)
{
	(void)probe;
	atomic64_inc(&probe3_hits);
	if (regs->di == READ_ONCE(probe_match_arg0))
		atomic64_inc(&probe3_match_hits);
	return 0;
}

static void livepatch_test_probe3_post(struct kprobe *probe,
				       struct pt_regs *regs,
				       unsigned long flags)
{
	(void)probe;
	(void)regs;
	(void)flags;
}

NOKPROBE_SYMBOL(livepatch_test_probe3_post);

static struct kprobe target_probe3 = {
	.pre_handler = livepatch_test_probe3_pre,
	.post_handler = livepatch_test_probe3_post,
};

static int livepatch_test_set_probe_address(const char *value,
					    const struct kernel_param *param)
{
	unsigned long address;
	int ret;

	(void)param;
	ret = kstrtoul(value, 0, &address);
	if (ret)
		return ret;

	mutex_lock(&probe_mutex);
	if (atomic_read(&probe_redirect_active) ||
	    READ_ONCE(probe_held) ||
	    READ_ONCE(probe_resume_task)) {
		mutex_unlock(&probe_mutex);
		return -EBUSY;
	}
	if (probe_registered) {
		unregister_kprobe(&target_probe);
		probe_registered = false;
	}

	WRITE_ONCE(probe_address, 0);
	WRITE_ONCE(probe_arg0, 0);
	WRITE_ONCE(probe_arg2, 0);
	WRITE_ONCE(probe_hold, false);
	wake_up_all(&probe_waitq);
	WRITE_ONCE(probe_held, false);
	WRITE_ONCE(probe_resume_task, NULL);
	atomic_set(&probe_redirect_active, 0);
	atomic64_set(&probe_hits, 0);
	/*
	 * unregister_kprobe() disables the reusable descriptor and
	 * register_kprobe() intentionally preserves KPROBE_FLAG_DISABLED.
	 * Clear the stale registration state before assigning a new target.
	 */
	WRITE_ONCE(target_probe.flags, 0);
	WRITE_ONCE(target_probe.nmissed, 0);
	cpumask_clear(&probe_cpus);
	if (!address) {
		mutex_unlock(&probe_mutex);
		return 0;
	}

	target_probe.addr = (kprobe_opcode_t *)address;
	WRITE_ONCE(livepatch_test_probe_marker, address + 1);
	WRITE_ONCE(livepatch_test_probe_resume, address);
	ret = register_kprobe(&target_probe);
	if (!ret) {
		probe_registered = true;
		WRITE_ONCE(probe_address, address);
	}
	mutex_unlock(&probe_mutex);

	return ret;
}

static int livepatch_test_get_probe_address(char *buffer,
					    const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe_address));
}

static const struct kernel_param_ops probe_address_ops = {
	.set = livepatch_test_set_probe_address,
	.get = livepatch_test_get_probe_address,
};

static int livepatch_test_get_probe_hits(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lld\n", atomic64_read(&probe_hits));
}

static const struct kernel_param_ops probe_hits_ops = {
	.get = livepatch_test_get_probe_hits,
};

static int livepatch_test_get_probe_arg0(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe_arg0));
}

static const struct kernel_param_ops probe_arg0_ops = {
	.get = livepatch_test_get_probe_arg0,
};

static int livepatch_test_get_probe_arg2(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe_arg2));
}

static const struct kernel_param_ops probe_arg2_ops = {
	.get = livepatch_test_get_probe_arg2,
};

static int livepatch_test_set_probe2_address(const char *value,
					     const struct kernel_param *param)
{
	unsigned long address;
	int ret;

	(void)param;
	ret = kstrtoul(value, 0, &address);
	if (ret)
		return ret;

	mutex_lock(&probe_mutex);
	if (probe2_registered) {
		unregister_kprobe(&target_probe2);
		probe2_registered = false;
	}

	WRITE_ONCE(probe2_address, 0);
	atomic64_set(&probe2_hits, 0);
	atomic64_set(&probe2_match_hits, 0);
	WRITE_ONCE(target_probe2.flags, 0);
	WRITE_ONCE(target_probe2.nmissed, 0);
	if (!address) {
		mutex_unlock(&probe_mutex);
		return 0;
	}

	target_probe2.addr = (kprobe_opcode_t *)address;
	ret = register_kprobe(&target_probe2);
	if (!ret) {
		probe2_registered = true;
		WRITE_ONCE(probe2_address, address);
	}
	mutex_unlock(&probe_mutex);

	return ret;
}

static int livepatch_test_get_probe2_address(char *buffer,
					     const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe2_address));
}

static const struct kernel_param_ops probe2_address_ops = {
	.set = livepatch_test_set_probe2_address,
	.get = livepatch_test_get_probe2_address,
};

static int livepatch_test_get_probe2_hits(char *buffer,
					  const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lld\n", atomic64_read(&probe2_hits));
}

static const struct kernel_param_ops probe2_hits_ops = {
	.get = livepatch_test_get_probe2_hits,
};

static int livepatch_test_get_probe2_match_hits(
	char *buffer,
	const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lld\n",
			  atomic64_read(&probe2_match_hits));
}

static const struct kernel_param_ops probe2_match_hits_ops = {
	.get = livepatch_test_get_probe2_match_hits,
};

static int livepatch_test_set_probe3_address(const char *value,
					     const struct kernel_param *param)
{
	unsigned long address;
	int ret;

	(void)param;
	ret = kstrtoul(value, 0, &address);
	if (ret)
		return ret;

	mutex_lock(&probe_mutex);
	if (probe3_registered) {
		unregister_kprobe(&target_probe3);
		probe3_registered = false;
	}

	WRITE_ONCE(probe3_address, 0);
	atomic64_set(&probe3_hits, 0);
	atomic64_set(&probe3_match_hits, 0);
	WRITE_ONCE(target_probe3.flags, 0);
	WRITE_ONCE(target_probe3.nmissed, 0);
	if (!address) {
		mutex_unlock(&probe_mutex);
		return 0;
	}

	target_probe3.addr = (kprobe_opcode_t *)address;
	ret = register_kprobe(&target_probe3);
	if (!ret) {
		probe3_registered = true;
		WRITE_ONCE(probe3_address, address);
	}
	mutex_unlock(&probe_mutex);

	return ret;
}

static int livepatch_test_get_probe3_address(char *buffer,
					     const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe3_address));
}

static const struct kernel_param_ops probe3_address_ops = {
	.set = livepatch_test_set_probe3_address,
	.get = livepatch_test_get_probe3_address,
};

static int livepatch_test_get_probe3_hits(char *buffer,
					  const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lld\n", atomic64_read(&probe3_hits));
}

static const struct kernel_param_ops probe3_hits_ops = {
	.get = livepatch_test_get_probe3_hits,
};

static int livepatch_test_get_probe3_match_hits(
	char *buffer,
	const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lld\n",
			  atomic64_read(&probe3_match_hits));
}

static const struct kernel_param_ops probe3_match_hits_ops = {
	.get = livepatch_test_get_probe3_match_hits,
};

static int livepatch_test_set_probe_match_arg0(
	const char *value,
	const struct kernel_param *param)
{
	unsigned long arg0;
	int ret;

	(void)param;
	ret = kstrtoul(value, 0, &arg0);
	if (ret)
		return ret;

	WRITE_ONCE(probe_match_arg0, 0);
	atomic64_set(&probe2_match_hits, 0);
	atomic64_set(&probe3_match_hits, 0);
	WRITE_ONCE(probe_match_arg0, arg0);
	return 0;
}

static int livepatch_test_get_probe_match_arg0(
	char *buffer,
	const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe_match_arg0));
}

static const struct kernel_param_ops probe_match_arg0_ops = {
	.set = livepatch_test_set_probe_match_arg0,
	.get = livepatch_test_get_probe_match_arg0,
};

static int livepatch_test_get_probe_missed(char *buffer,
					   const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lu\n",
			  READ_ONCE(target_probe.nmissed));
}

static const struct kernel_param_ops probe_missed_ops = {
	.get = livepatch_test_get_probe_missed,
};

static int livepatch_test_get_probe2_missed(char *buffer,
					    const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lu\n",
			  READ_ONCE(target_probe2.nmissed));
}

static const struct kernel_param_ops probe2_missed_ops = {
	.get = livepatch_test_get_probe2_missed,
};

static int livepatch_test_get_probe3_missed(char *buffer,
					    const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%lu\n",
			  READ_ONCE(target_probe3.nmissed));
}

static const struct kernel_param_ops probe3_missed_ops = {
	.get = livepatch_test_get_probe3_missed,
};

static int livepatch_test_get_probe_cpu_count(char *buffer,
					      const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%u\n", cpumask_weight(&probe_cpus));
}

static const struct kernel_param_ops probe_cpu_count_ops = {
	.get = livepatch_test_get_probe_cpu_count,
};

static int livepatch_test_get_probe_held(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%c\n",
			  READ_ONCE(probe_held) ? 'Y' : 'N');
}

static const struct kernel_param_ops probe_held_ops = {
	.get = livepatch_test_get_probe_held,
};

static int livepatch_test_get_shadow_injected(char *buffer,
					      const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%d\n",
			  atomic_read(&shadow_failures_injected));
}

static const struct kernel_param_ops shadow_injected_ops = {
	.get = livepatch_test_get_shadow_injected,
};

module_param(shadow_failures, int, 0600);
MODULE_PARM_DESC(shadow_failures,
		 "Number of upcoming klp_shadow_alloc() calls to fail");

module_param_cb(probe_address, &probe_address_ops, NULL, 0600);
MODULE_PARM_DESC(probe_address,
		 "Exact kernel text address at which to count entries");

module_param_cb(probe_hits, &probe_hits_ops, NULL, 0400);
MODULE_PARM_DESC(probe_hits, "Entries observed at probe_address");

module_param_cb(probe_arg0, &probe_arg0_ops, NULL, 0400);
MODULE_PARM_DESC(probe_arg0,
		 "First argument observed at the held probe_address entry");

module_param_cb(probe_arg2, &probe_arg2_ops, NULL, 0400);
MODULE_PARM_DESC(probe_arg2,
		 "Third argument observed at the held probe_address entry");

module_param_cb(probe2_address, &probe2_address_ops, NULL, 0600);
MODULE_PARM_DESC(probe2_address,
		 "Second exact kernel text address at which to count entries");

module_param_cb(probe2_hits, &probe2_hits_ops, NULL, 0400);
MODULE_PARM_DESC(probe2_hits, "Entries observed at probe2_address");

module_param_cb(probe2_match_hits, &probe2_match_hits_ops, NULL, 0400);
MODULE_PARM_DESC(probe2_match_hits,
		 "Probe2 entries matching probe_match_arg0");

module_param_cb(probe3_address, &probe3_address_ops, NULL, 0600);
MODULE_PARM_DESC(probe3_address,
		 "Third exact kernel text address at which to count entries");

module_param_cb(probe3_hits, &probe3_hits_ops, NULL, 0400);
MODULE_PARM_DESC(probe3_hits, "Entries observed at probe3_address");

module_param_cb(probe3_match_hits, &probe3_match_hits_ops, NULL, 0400);
MODULE_PARM_DESC(probe3_match_hits,
		 "Probe3 entries matching probe_match_arg0");

module_param_cb(probe_match_arg0, &probe_match_arg0_ops, NULL, 0600);
MODULE_PARM_DESC(probe_match_arg0,
		 "First argument for probe2 and probe3 match counters");

module_param_cb(probe_missed, &probe_missed_ops, NULL, 0400);
MODULE_PARM_DESC(probe_missed,
		 "Entries missed at probe_address while another kprobe was active");

module_param_cb(probe2_missed, &probe2_missed_ops, NULL, 0400);
MODULE_PARM_DESC(probe2_missed,
		 "Entries missed at probe2_address while another kprobe was active");

module_param_cb(probe3_missed, &probe3_missed_ops, NULL, 0400);
MODULE_PARM_DESC(probe3_missed,
		 "Entries missed at probe3_address while another kprobe was active");

module_param_cb(probe_cpu_count, &probe_cpu_count_ops, NULL, 0400);
MODULE_PARM_DESC(probe_cpu_count, "CPUs observed at probe_address");

module_param_cb(probe_hold, &probe_hold_ops, NULL, 0600);
MODULE_PARM_DESC(probe_hold, "Hold a probed frame until explicitly released");

module_param_cb(probe_held, &probe_held_ops, NULL, 0400);
MODULE_PARM_DESC(probe_held, "Whether a probed frame is currently held");

module_param_cb(probe_clone_arg2, &probe_clone_arg2_ops, NULL, 0600);
MODULE_PARM_DESC(probe_clone_arg2,
		 "Retain a test-only clone of the probed frame's third argument");

module_param_cb(probe_arg2_clone_held, &probe_arg2_clone_held_ops, NULL, 0400);
MODULE_PARM_DESC(probe_arg2_clone_held,
		 "Whether the test-only third-argument clone is retained");

module_param(probe_spin_hold, bool, 0600);
MODULE_PARM_DESC(probe_spin_hold,
		 "Hold the probed instruction in its non-sleeping kprobe handler");

module_param_cb(shadow_failures_injected, &shadow_injected_ops, NULL, 0400);
MODULE_PARM_DESC(shadow_failures_injected,
		 "klp_shadow_alloc() failures injected");

static int __init livepatch_test_probe_init(void)
{
	return register_kprobe(&shadow_alloc_probe);
}

static void __exit livepatch_test_probe_exit(void)
{
	struct sk_buff *clone;

	WRITE_ONCE(probe_hold, false);
	wake_up_all(&probe_waitq);
	wait_event(probe_waitq,
		   !atomic_read(&probe_redirect_active) &&
		   !READ_ONCE(probe_held) &&
		   !READ_ONCE(probe_resume_task));

	mutex_lock(&probe_mutex);
	if (probe_registered) {
		unregister_kprobe(&target_probe);
		probe_registered = false;
	}
	if (probe2_registered) {
		unregister_kprobe(&target_probe2);
		probe2_registered = false;
	}
	if (probe3_registered) {
		unregister_kprobe(&target_probe3);
		probe3_registered = false;
	}
	mutex_unlock(&probe_mutex);
	WRITE_ONCE(probe_clone_arg2, false);
	clone = xchg(&probe_arg2_clone, NULL);
	if (clone)
		kfree_skb(clone);
	unregister_kprobe(&shadow_alloc_probe);
}

module_init(livepatch_test_probe_init);
module_exit(livepatch_test_probe_exit);

MODULE_AUTHOR("vpsAdminOS");
MODULE_DESCRIPTION("Test-only probes for cumulative livepatch validation");
MODULE_LICENSE("GPL");
