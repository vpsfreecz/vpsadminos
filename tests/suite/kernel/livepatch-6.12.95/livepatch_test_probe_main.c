// SPDX-License-Identifier: GPL-2.0

#include <linux/atomic.h>
#include <linux/cpumask.h>
#include <linux/jiffies.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/rhashtable.h>
#include <linux/sched.h>
#include <linux/skbuff.h>
#include <linux/smp.h>
#include <linux/wait.h>

#include <net/sctp/structs.h>
#include <net/sock.h>
#include <net/vxlan.h>

#include <asm/processor.h>

#include "svm.h"

#include "livepatch_test_probe.h"

#ifndef CONFIG_X86_64
#error "livepatch_test_probe is only implemented for x86-64"
#endif

static int shadow_failures;
static atomic_t shadow_failures_injected = ATOMIC_INIT(0);

static unsigned long probe_address;
static unsigned long probe_arg0;
static unsigned long probe_arg1;
static unsigned long probe_arg2;
static atomic64_t probe_hits = ATOMIC64_INIT(0);
static cpumask_t probe_cpus;
static bool probe_hold;
static bool probe_held;
static bool probe_spin_hold;
static bool probe_clone_arg2;
static bool probe_capture_args;
static bool probe_capture_vxlan_age_timer;
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

static bool svm_x2apic_inject;
static unsigned long svm_x2avic_enabled_address;
static struct vcpu_svm *svm_x2apic_test_vcpu;
static bool svm_x2avic_original;
static bool svm_x2avic_original_valid;
static bool svm_x2apic_require_nested;
static atomic_t svm_x2apic_injections = ATOMIC_INIT(0);

static unsigned long sctp_asoc_address;
static atomic_t sctp_mismatch_injections = ATOMIC_INIT(0);
static unsigned int rhashtable_restart_passes;

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

/*
 * These are the x2APIC MSRs which svm_set_x2apic_msr_interception() tracks
 * in this exact kernel.  The test injects the same permissive bitmap state
 * left by the vulnerable nested-AVIC transition, and then checks that the
 * vCPU-entry repair restored every tracked read/write intercept.
 */
static const u16 livepatch_test_x2apic_msrs[] = {
	0x802, 0x803, 0x808, 0x809, 0x80a, 0x80b, 0x80d, 0x80e,
	0x80f, 0x810, 0x818, 0x820, 0x828, 0x830, 0x831, 0x834,
	0x835, 0x836, 0x837, 0x838, 0x839, 0x83e,
};

static u32 livepatch_test_msrpm_offset(u32 msr)
{
	return (msr / 4) / 4;
}

static bool livepatch_test_x2apic_intercepted(const u32 *msrpm, u32 msr)
{
	u32 value = READ_ONCE(msrpm[livepatch_test_msrpm_offset(msr)]);
	u8 read_bit = 2 * (msr & 0x0f);
	u8 write_bit = read_bit + 1;

	return value & BIT(read_bit) && value & BIT(write_bit);
}

static void livepatch_test_make_x2apic_msr_permissive(u32 *msrpm, u32 msr)
{
	u32 offset = livepatch_test_msrpm_offset(msr);
	u8 read_bit = 2 * (msr & 0x0f);
	u8 write_bit = read_bit + 1;
	u32 value = READ_ONCE(msrpm[offset]);

	value &= ~BIT(read_bit);
	value &= ~BIT(write_bit);
	WRITE_ONCE(msrpm[offset], value);
}

static void livepatch_test_inject_svm_x2apic(struct pt_regs *regs)
{
	struct vcpu_svm *svm;
	bool *x2avic_enabled;
	unsigned int i;

	if (!READ_ONCE(svm_x2apic_inject) ||
	    !READ_ONCE(svm_x2avic_enabled_address))
		return;

	svm = (struct vcpu_svm *)regs_get_kernel_argument(regs, 0);
	if (!svm || !svm->msrpm ||
	    (READ_ONCE(svm_x2apic_require_nested) &&
	     !is_guest_mode(&svm->vcpu)))
		return;

	x2avic_enabled = (bool *)READ_ONCE(svm_x2avic_enabled_address);
	if (!READ_ONCE(svm_x2avic_original_valid)) {
		WRITE_ONCE(svm_x2avic_original, READ_ONCE(*x2avic_enabled));
		WRITE_ONCE(svm_x2avic_original_valid, true);
	}
	WRITE_ONCE(*x2avic_enabled, true);

	for (i = 0; i < ARRAY_SIZE(livepatch_test_x2apic_msrs); i++) {
		u32 msr = livepatch_test_x2apic_msrs[i];

		livepatch_test_make_x2apic_msr_permissive(svm->msrpm, msr);
	}

	WRITE_ONCE(svm->x2avic_msrs_intercepted, false);
	WRITE_ONCE(svm_x2apic_test_vcpu, svm);
	WRITE_ONCE(svm_x2apic_inject, false);
	atomic_inc(&svm_x2apic_injections);
}

NOKPROBE_SYMBOL(livepatch_test_inject_svm_x2apic);

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
	struct net_device *dev;
	struct sk_buff *clone;
	struct sk_buff *old;
	struct vxlan_dev *vxlan;

	(void)probe;

	if (READ_ONCE(probe_resume_task) == current) {
		WRITE_ONCE(probe_resume_task, NULL);
		wake_up_all(&probe_waitq);
		return 0;
	}
	livepatch_test_inject_svm_x2apic(regs);
	if (READ_ONCE(probe_hold) &&
	    atomic_cmpxchg(&probe_redirect_active, 0, 1))
		return 0;
	livepatch_test_record_probe_hit();
	if (READ_ONCE(probe_capture_vxlan_age_timer)) {
		dev = (struct net_device *)regs_get_kernel_argument(regs, 0);
		if (dev) {
			vxlan = netdev_priv(dev);
			cmpxchg(&probe_arg0, 0,
				(unsigned long)&vxlan->age_timer);
		}
	} else if (READ_ONCE(probe_capture_args)) {
		WRITE_ONCE(probe_arg0, regs_get_kernel_argument(regs, 0));
		WRITE_ONCE(probe_arg1, regs_get_kernel_argument(regs, 1));
		WRITE_ONCE(probe_arg2, regs_get_kernel_argument(regs, 2));
	}
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
	WRITE_ONCE(probe_arg1, 0);
	WRITE_ONCE(probe_arg2, 0);
	WRITE_ONCE(probe_capture_vxlan_age_timer, false);
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

static int livepatch_test_get_probe_arg1(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%#lx\n", READ_ONCE(probe_arg1));
}

static const struct kernel_param_ops probe_arg1_ops = {
	.get = livepatch_test_get_probe_arg1,
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

static int
livepatch_test_set_svm_x2apic_inject(const char *value,
				     const struct kernel_param *param)
{
	bool inject;
	int ret;

	(void)param;
	ret = kstrtobool(value, &inject);
	if (ret)
		return ret;
	if (inject) {
		if (!READ_ONCE(svm_x2avic_enabled_address))
			return -EINVAL;
	}
	WRITE_ONCE(svm_x2apic_inject, inject);
	return 0;
}

static int
livepatch_test_get_svm_x2apic_inject(char *buffer,
				     const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%c\n",
			 READ_ONCE(svm_x2apic_inject) ? 'Y' : 'N');
}

static const struct kernel_param_ops svm_x2apic_inject_ops = {
	.set = livepatch_test_set_svm_x2apic_inject,
	.get = livepatch_test_get_svm_x2apic_inject,
};

static int
livepatch_test_get_svm_x2apic_injections(char *buffer,
					 const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%d\n",
			 atomic_read(&svm_x2apic_injections));
}

static const struct kernel_param_ops svm_x2apic_injections_ops = {
	.get = livepatch_test_get_svm_x2apic_injections,
};

static int
livepatch_test_get_svm_x2apic_state(char *buffer,
				    const struct kernel_param *param)
{
	struct vcpu_svm *svm = READ_ONCE(svm_x2apic_test_vcpu);
	unsigned int intercepted = 0;
	unsigned int i;

	(void)param;
	if (!svm)
		return sysfs_emit(buffer, "none\n");

	for (i = 0; i < ARRAY_SIZE(livepatch_test_x2apic_msrs); i++)
		intercepted += livepatch_test_x2apic_intercepted(svm->msrpm,
						livepatch_test_x2apic_msrs[i]);

	if (!READ_ONCE(svm->x2avic_msrs_intercepted) && !intercepted)
		return sysfs_emit(buffer, "permissive\n");
	if (READ_ONCE(svm->x2avic_msrs_intercepted) &&
	    intercepted == ARRAY_SIZE(livepatch_test_x2apic_msrs))
		return sysfs_emit(buffer, "intercepted\n");
	return sysfs_emit(buffer, "mixed:%u/%zu:%u\n", intercepted,
			 ARRAY_SIZE(livepatch_test_x2apic_msrs),
			 READ_ONCE(svm->x2avic_msrs_intercepted));
}

static const struct kernel_param_ops svm_x2apic_state_ops = {
	.get = livepatch_test_get_svm_x2apic_state,
};

static int
livepatch_test_set_svm_x2apic_restore(const char *value,
				      const struct kernel_param *param)
{
	bool restore;
	int ret;

	(void)param;
	ret = kstrtobool(value, &restore);
	if (ret)
		return ret;
	if (!restore)
		return 0;

	WRITE_ONCE(svm_x2apic_inject, false);
	WRITE_ONCE(svm_x2apic_test_vcpu, NULL);
	if (READ_ONCE(svm_x2avic_original_valid) &&
	    READ_ONCE(svm_x2avic_enabled_address))
		WRITE_ONCE(*(bool *)READ_ONCE(svm_x2avic_enabled_address),
			   READ_ONCE(svm_x2avic_original));
	WRITE_ONCE(svm_x2avic_original_valid, false);
	atomic_set(&svm_x2apic_injections, 0);
	return 0;
}

static const struct kernel_param_ops svm_x2apic_restore_ops = {
	.set = livepatch_test_set_svm_x2apic_restore,
};

static int
livepatch_test_set_sctp_transport_count(const char *value,
					const struct kernel_param *param)
{
	struct sctp_association *asoc;
	unsigned int count;
	int ret;

	(void)param;
	ret = kstrtouint(value, 0, &count);
	if (ret)
		return ret;
	if (count > U16_MAX)
		return -ERANGE;
	asoc = (struct sctp_association *)READ_ONCE(sctp_asoc_address);
	if (!asoc)
		return -ENODEV;
	WRITE_ONCE(asoc->peer.transport_count, count);
	return 0;
}

static int
livepatch_test_get_sctp_transport_count(char *buffer,
					const struct kernel_param *param)
{
	struct sctp_association *asoc;

	(void)param;
	asoc = (struct sctp_association *)READ_ONCE(sctp_asoc_address);
	if (!asoc)
		return sysfs_emit(buffer, "none\n");
	return sysfs_emit(buffer, "%u\n",
			 READ_ONCE(asoc->peer.transport_count));
}

static const struct kernel_param_ops sctp_transport_count_ops = {
	.set = livepatch_test_set_sctp_transport_count,
	.get = livepatch_test_get_sctp_transport_count,
};

static int
livepatch_test_set_sctp_mismatch_transmitted(const char *value,
					     const struct kernel_param *param)
{
	struct sctp_transport *alternate = NULL;
	struct sctp_transport *owner = NULL;
	struct sctp_transport *transport;
	struct sctp_association *asoc;
	struct sctp_chunk *chunk;
	bool inject;
	int ret;

	(void)param;
	ret = kstrtobool(value, &inject);
	if (ret || !inject)
		return ret;

	asoc = (struct sctp_association *)READ_ONCE(sctp_asoc_address);
	if (!asoc || !asoc->base.sk)
		return -ENODEV;

	lock_sock(asoc->base.sk);
	list_for_each_entry(transport, &asoc->peer.transport_addr_list,
			    transports) {
		if (!list_empty(&transport->transmitted))
			owner = transport;
	}
	if (!owner) {
		ret = -ENOENT;
		goto out_release;
	}
	list_for_each_entry(transport, &asoc->peer.transport_addr_list,
			    transports) {
		if (transport != owner) {
			alternate = transport;
			break;
		}
	}
	if (!alternate) {
		ret = -ENXIO;
		goto out_release;
	}

	chunk = list_first_entry(&owner->transmitted, struct sctp_chunk,
				 transmitted_list);
	if (chunk->transport != owner) {
		ret = -EUCLEAN;
		goto out_release;
	}

	WRITE_ONCE(chunk->transport, alternate);
	atomic_inc(&sctp_mismatch_injections);
	ret = 0;

out_release:
	release_sock(asoc->base.sk);
	return ret;
}

static int
livepatch_test_get_sctp_mismatch_injections(char *buffer,
					    const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%d\n",
			  atomic_read(&sctp_mismatch_injections));
}

static const struct kernel_param_ops sctp_mismatch_transmitted_ops = {
	.set = livepatch_test_set_sctp_mismatch_transmitted,
};

static const struct kernel_param_ops sctp_mismatch_injections_ops = {
	.get = livepatch_test_get_sctp_mismatch_injections,
};

static int
livepatch_test_set_rhashtable_restart(const char *value,
				      const struct kernel_param *param)
{
	struct rhashtable_params params = {
		.head_offset = 0,
		.key_offset = sizeof(struct rhash_head),
		.key_len = sizeof(u32),
	};
	struct rhashtable_iter iter;
	struct rhashtable table;
	bool run;
	int ret;

	(void)param;
	ret = kstrtobool(value, &run);
	if (ret || !run)
		return ret;

	ret = rhashtable_init(&table, &params);
	if (ret)
		return ret;
	rhashtable_walk_enter(&table, &iter);

	spin_lock(&table.lock);
	list_del(&iter.walker.list);
	iter.walker.tbl = NULL;
	iter.p = (struct rhash_head *)ERR_PTR(-EUCLEAN);
	spin_unlock(&table.lock);

	ret = rhashtable_walk_start_check(&iter);
	if (ret == -EAGAIN && !iter.p) {
		rhashtable_restart_passes++;
		ret = 0;
	} else if (!ret) {
		ret = -EUCLEAN;
	}
	rhashtable_walk_stop(&iter);
	rhashtable_walk_exit(&iter);
	rhashtable_destroy(&table);
	return ret;
}

static int livepatch_test_get_restart_passes(char *buffer,
					     const struct kernel_param *param)
{
	(void)param;
	return sysfs_emit(buffer, "%u\n",
			 READ_ONCE(rhashtable_restart_passes));
}

static const struct kernel_param_ops rhashtable_restart_ops = {
	.set = livepatch_test_set_rhashtable_restart,
};

static const struct kernel_param_ops rhashtable_restart_passes_ops = {
	.get = livepatch_test_get_restart_passes,
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

module_param_cb(probe_arg1, &probe_arg1_ops, NULL, 0400);
MODULE_PARM_DESC(probe_arg1,
		 "Second argument observed at probe_address when capture is enabled");

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

module_param(probe_capture_args, bool, 0600);
MODULE_PARM_DESC(probe_capture_args,
		 "Capture the first three arguments without holding the probed task");

module_param(probe_capture_vxlan_age_timer, bool, 0600);
MODULE_PARM_DESC(probe_capture_vxlan_age_timer,
		 "Capture the probed VXLAN device's exact ageing-timer address once");

module_param_cb(shadow_failures_injected, &shadow_injected_ops, NULL, 0400);
MODULE_PARM_DESC(shadow_failures_injected,
		 "klp_shadow_alloc() failures injected");

module_param(svm_x2avic_enabled_address, ulong, 0600);
MODULE_PARM_DESC(svm_x2avic_enabled_address,
		 "Exact kvm_amd x2avic_enabled address used by the SVM state test");

module_param(svm_x2apic_require_nested, bool, 0600);
MODULE_PARM_DESC(svm_x2apic_require_nested,
		 "Inject only while the probed vCPU is running L2");

module_param_cb(svm_x2apic_inject, &svm_x2apic_inject_ops, NULL, 0600);
MODULE_PARM_DESC(svm_x2apic_inject,
		 "Inject one permissive nested-SVM x2APIC MSR bitmap");

module_param_cb(svm_x2apic_injections, &svm_x2apic_injections_ops, NULL, 0400);
MODULE_PARM_DESC(svm_x2apic_injections,
		 "Permissive nested-SVM x2APIC bitmap states injected");

module_param_cb(svm_x2apic_state, &svm_x2apic_state_ops, NULL, 0400);
MODULE_PARM_DESC(svm_x2apic_state,
		 "Saved nested-SVM x2APIC bitmap state");

module_param_cb(svm_x2apic_restore, &svm_x2apic_restore_ops, NULL, 0200);
MODULE_PARM_DESC(svm_x2apic_restore,
		 "Restore the original host x2AVIC test state and forget the vCPU");

module_param(sctp_asoc_address, ulong, 0600);
MODULE_PARM_DESC(sctp_asoc_address,
		 "Exact live SCTP association address used by the count-wrap test");

module_param_cb(sctp_transport_count, &sctp_transport_count_ops, NULL, 0600);
MODULE_PARM_DESC(sctp_transport_count,
		 "Read or set the test association's legacy peer transport count");

module_param_cb(sctp_mismatch_transmitted,
		&sctp_mismatch_transmitted_ops, NULL, 0200);
MODULE_PARM_DESC(sctp_mismatch_transmitted,
		 "Move one real transmitted chunk onto a different live transport pointer");

module_param_cb(sctp_mismatch_injections,
		&sctp_mismatch_injections_ops, NULL, 0400);
MODULE_PARM_DESC(sctp_mismatch_injections,
		 "Real SCTP transmitted chunks given a mismatched transport pointer");

module_param_cb(rhashtable_restart, &rhashtable_restart_ops, NULL, 0200);
MODULE_PARM_DESC(rhashtable_restart,
		 "Exercise the stale-pointer table-restart branch once");

module_param_cb(rhashtable_restart_passes,
		&rhashtable_restart_passes_ops, NULL, 0400);
MODULE_PARM_DESC(rhashtable_restart_passes,
		 "Successful stale-pointer table-restart checks");

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
