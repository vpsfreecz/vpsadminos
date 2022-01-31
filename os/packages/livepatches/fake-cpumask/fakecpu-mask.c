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

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/vmstat.h>
#include <linux/atomic.h>
#include <linux/cgroup.h>
#include <linux/memcontrol.h>
#include <linux/user_namespace.h>
#include <linux/xarray.h>
#include <linux/vpsadminos.h>
#include <asm/page.h>

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

struct cgroup_namespace *init_cgroup_ns_ptr;
int (*get_online_cpus_in_cpu_cgroup_ptr)(struct task_struct *);

int patched_fake_cpumask(struct task_struct *p, struct cpumask *dstmask, const struct cpumask *srcmask)
{
	int cpus;
	int cpu, enabled;

	if (srcmask != NULL)
		cpumask_copy(dstmask, srcmask);

	if (current->nsproxy->cgroup_ns == init_cgroup_ns_ptr)
		return 0;

	cpus = get_online_cpus_in_cpu_cgroup_ptr(p);

	WARN_ON(cpus == 0);

	enabled = 0;
	for_each_possible_cpu(cpu) {
		if (cpumask_test_cpu(cpu, dstmask)) {
			if (enabled == cpus)
				cpumask_clear_cpu(cpu, dstmask);
			else
				enabled++;
		}
	}

	return enabled;
}

static struct klp_func funcs[] = {
	{
		.old_name = "fake_cpumask",
		.new_func = patched_fake_cpumask,
	}, { }
};

static struct klp_object objs[] = {
	{
		/* name being NULL means vmlinux */
		.funcs = funcs,
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

	init_cgroup_ns_ptr = (struct cgroup_namespace *)kln_pointer("init_cgroup_ns");
	get_online_cpus_in_cpu_cgroup_ptr = (int (*)(struct task_struct *))kln_pointer("get_online_cpus_in_cpu_cgroup");

	return klp_enable_patch(&patch);
}

static void livepatch_exit(void)
{
}

module_init(livepatch_init);
module_exit(livepatch_exit);
MODULE_LICENSE("GPL");
MODULE_INFO(livepatch, "Y");
