/*
 * vpsAdminOS Livepatch
 * ===========================================================================
 * 
 * 
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/livepatch.h>
#include <linux/kprobes.h>

#include <linux/atomic.h>
#include <linux/binfmts.h>
#include <linux/blkdev.h>
#include <linux/cgroup.h>
#include <linux/compat.h>
#include <linux/context_tracking.h>
#include <linux/cpufreq.h>
#include <linux/cpuidle.h>
#include <linux/cpuset.h>
#include <linux/ctype.h>
#include <linux/debugfs.h>
#include <linux/delayacct.h>
#include <linux/energy_model.h>
#include <linux/init.h>
#include <linux/init_task.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/kthread.h>
#include <linux/membarrier.h>
#include <linux/memcontrol.h>
#include <linux/migrate.h>
#include <linux/mm.h>
#include <linux/mmu_context.h>
#include <linux/nmi.h>
#include <linux/prefetch.h>
#include <linux/proc_fs.h>
#include <linux/profile.h>
#include <linux/psi.h>
#include <linux/rcupdate_wait.h>
#include <linux/sched/autogroup.h>
#include <linux/sched/clock.h>
#include <linux/sched/coredump.h>
#include <linux/sched/cpufreq.h>
#include <linux/sched/cputime.h>
#include <linux/sched/deadline.h>
#include <linux/sched/debug.h>
#include <linux/sched.h>
#include <linux/sched/hotplug.h>
#include <linux/sched/idle.h>
#include <linux/sched/init.h>
#include <linux/sched/isolation.h>
#include <linux/sched/jobctl.h>
#include <linux/sched/loadavg.h>
#include <linux/sched/mm.h>
#include <linux/sched/nohz.h>
#include <linux/sched/numa_balancing.h>
#include <linux/sched/prio.h>
#include <linux/sched/rt.h>
#include <linux/sched/signal.h>
#include <linux/sched/smt.h>
#include <linux/sched/stat.h>
#include <linux/sched/sysctl.h>
#include <linux/sched/task.h>
#include <linux/sched/task_stack.h>
#include <linux/sched/topology.h>
#include <linux/sched/user.h>
#include <linux/sched/wake_q.h>
#include <linux/sched/xacct.h>
#include <linux/security.h>
#include <linux/stop_machine.h>
#include <linux/suspend.h>
#include <linux/swait.h>
#include <linux/syscalls.h>
#include <linux/task_work.h>
#include <linux/tsacct_kern.h>
#include <linux/user_namespace.h>
#include <linux/vmstat.h>
#include <linux/xarray.h>
#include <linux/sunrpc/clnt.h>
#include <linux/nfs_fs.h>

#define KPROBE_PRE_HANDLER(fname) static int __kprobes fname(struct kprobe *p, struct pt_regs *regs)

long unsigned int kln_addr = 0;
unsigned long (*kln_pointer)(const char *name) = NULL;

static struct kprobe kp0, kp1;

KPROBE_PRE_HANDLER(handler_pre0)
{
	kln_addr = (--regs->ip);

	return 0;
}

KPROBE_PRE_HANDLER(handler_pre1)
{
	return 0;
}

static int do_register_kprobe(struct kprobe *kp, char *symbol_name, void *handler)
{
	int ret;

	kp->symbol_name = symbol_name;
	kp->pre_handler = handler;

	ret = register_kprobe(kp);
	if (ret < 0) {
	  pr_err("register_probe() for symbol %s failed, returned %d\n", symbol_name, ret);
	  return ret;
	}

	pr_info("Planted kprobe for symbol %s at %p\n", symbol_name, kp->addr);

	return ret;
}

int (*rpc_call_sync_ptr)(struct rpc_clnt *clnt, const struct rpc_message *msg, int flags);

static int patched_nfs_wait_bit_killable(struct wait_bit_key *key, int mode)
{
	freezable_schedule();
	if (signal_pending_state(mode, current))
		return -ERESTARTSYS;
	return 0;
}

static int
patched_nfs3_rpc_wrapper(struct rpc_clnt *clnt, struct rpc_message *msg, int flags)
{
	int res;
	do {
		res = rpc_call_sync_ptr(clnt, msg, flags);
		if (res != -EJUKEBOX)
			break;
		freezable_schedule_timeout_killable(NFS_JUKEBOX_RETRY_TIME);
		res = -ERESTARTSYS;
	} while (!fatal_signal_pending(current));
	return res;
}

static int patched_rpc_wait_bit_killable(struct wait_bit_key *key, int mode)
{
	freezable_schedule();
	if (signal_pending_state(mode, current))
		return -ERESTARTSYS;
	return 0;
}

static struct klp_func nfs_funcs[] = {
	{
		.old_name = "nfs_wait_bit_killable",
		.new_func = patched_nfs_wait_bit_killable,
	}, { }
};

static struct klp_func nfsv3_funcs[] = {
	{
		.old_name = "nfs3_rpc_wrapper",
		.new_func = patched_nfs3_rpc_wrapper,
	}, { }
};

static struct klp_func sunrpc_funcs[] = {
	{
		.old_name = "rpc_wait_bit_killable",
		.new_func = patched_rpc_wait_bit_killable,
	}, { }
};

static struct klp_object objs[] = {
	{
		.name = "nfs",
		.funcs = nfs_funcs,
	},
	{
		.name = "nfsv3",
		.funcs = nfsv3_funcs,
	},
	{
		.name = "sunrpc",
		.funcs = sunrpc_funcs,
	}, { }
};

static struct klp_patch patch = {
	.mod = THIS_MODULE,
	.objs = objs,
};

static int livepatch_init(void)
{
	int ret;

	pr_info("module loaded\n");

	ret = do_register_kprobe(&kp0, "kallsyms_lookup_name", handler_pre0);
	if (ret < 0)
	  return ret;

	ret = do_register_kprobe(&kp1, "kallsyms_lookup_name", handler_pre1);
	if (ret < 0) {
	  unregister_kprobe(&kp0);
	  return ret;
	}

	unregister_kprobe(&kp0);
	unregister_kprobe(&kp1);

	pr_info("kallsyms_lookup_name address = 0x%lx\n", kln_addr);

	kln_pointer = (unsigned long (*)(const char *name)) kln_addr;

	pr_info("kallsyms_lookup_name address = 0x%lx\n", kln_pointer("kallsyms_lookup_name"));

	rpc_call_sync_ptr = (int (*)(struct rpc_clnt *, const struct rpc_message *, int))kln_pointer("rpc_call_sync");
	return klp_enable_patch(&patch);
}

static void livepatch_exit(void)
{
}

module_init(livepatch_init);
module_exit(livepatch_exit);
MODULE_LICENSE("GPL");
MODULE_INFO(livepatch, "Y");
