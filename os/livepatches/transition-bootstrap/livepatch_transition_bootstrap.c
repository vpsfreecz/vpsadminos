// SPDX-License-Identifier: GPL-2.0-only

#include <linux/cpu.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/sched.h>
#include <linux/smp.h>

typedef struct task_struct *(*idle_task_fn_t)(int cpu);
typedef void (*klp_update_patch_state_fn_t)(struct task_struct *task);

static idle_task_fn_t resolved_idle_task;
static klp_update_patch_state_fn_t resolved_klp_update_patch_state;

static int resolve_symbol(const char *name, void **address)
{
	struct kprobe probe = {
		.symbol_name = name,
	};
	int ret;

	ret = register_kprobe(&probe);
	if (ret)
		return ret;

	*address = probe.addr;
	unregister_kprobe(&probe);
	return 0;
}

/*
 * This callback is used only while the minimal transition guard is the active
 * transition.  Its two replacement functions can never be executing on an
 * idle task's inactive stack.  On the target CPU, the idle task is either
 * current or local interrupt exclusion prevents it from becoming current
 * while klp_update_patch_state() changes its state.
 */
static void switch_online_idle(void *unused)
{
	struct task_struct *task = resolved_idle_task(smp_processor_id());

	resolved_klp_update_patch_state(task);
}

static int switch_guard_idle_tasks(void)
{
	int cpu;
	int ret = 0;

	cpus_read_lock();
	for_each_online_cpu(cpu) {
		ret = smp_call_function_single(cpu, switch_online_idle, NULL, 1);
		if (ret)
			goto out;
	}

	for_each_possible_cpu(cpu) {
		if (!cpu_online(cpu))
			resolved_klp_update_patch_state(resolved_idle_task(cpu));
	}
out:
	cpus_read_unlock();
	return ret;
}

static int set_kick_idle(const char *value, const struct kernel_param *param)
{
	bool kick;
	int ret;

	ret = kstrtobool(value, &kick);
	if (ret)
		return ret;
	if (!kick)
		return -EINVAL;

	return switch_guard_idle_tasks();
}

static const struct kernel_param_ops kick_idle_ops = {
	.set = set_kick_idle,
};

module_param_cb(kick_idle, &kick_idle_ops, NULL, 0200);
MODULE_PARM_DESC(kick_idle,
		 "switch idle tasks during the minimal livepatch transition guard");

static int __init transition_bootstrap_init(void)
{
	int ret;

	ret = resolve_symbol("idle_task", (void **)&resolved_idle_task);
	if (ret)
		return ret;

	ret = resolve_symbol("klp_update_patch_state",
			     (void **)&resolved_klp_update_patch_state);
	if (ret)
		return ret;

	return 0;
}

static void __exit transition_bootstrap_exit(void)
{
}

module_init(transition_bootstrap_init);
module_exit(transition_bootstrap_exit);

MODULE_AUTHOR("vpsAdminOS maintainers");
MODULE_DESCRIPTION("Bootstrap idle tasks into a minimal livepatch transition guard");
MODULE_LICENSE("GPL");
