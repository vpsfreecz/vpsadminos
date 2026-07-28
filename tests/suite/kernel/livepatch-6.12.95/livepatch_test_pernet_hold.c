// SPDX-License-Identifier: GPL-2.0

#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/wait.h>
#include <net/net_namespace.h>

static DECLARE_WAIT_QUEUE_HEAD(control_waitq);
static struct task_struct *holder_task;
static bool hold_requested;
static bool lock_held;

static int hold_set(const char *value, const struct kernel_param *param)
{
	bool requested;
	int ret;

	(void)param;
	ret = kstrtobool(value, &requested);
	if (ret)
		return ret;

	WRITE_ONCE(hold_requested, requested);
	wake_up_all(&control_waitq);
	return 0;
}

static const struct kernel_param_ops hold_ops = {
	.set = hold_set,
	.get = param_get_bool,
};

module_param_cb(hold, &hold_ops, &hold_requested, 0600);
MODULE_PARM_DESC(hold, "Hold pernet_ops_rwsem in the helper kthread");

module_param_named(held, lock_held, bool, 0400);
MODULE_PARM_DESC(held, "Whether a pernet registration holds pernet_ops_rwsem");

static int livepatch_test_pernet_init(struct net *net)
{
	(void)net;

	if (!READ_ONCE(hold_requested))
		return 0;

	WRITE_ONCE(lock_held, true);
	wake_up_all(&control_waitq);

	wait_event(control_waitq,
		   kthread_should_stop() || !READ_ONCE(hold_requested));

	WRITE_ONCE(lock_held, false);
	wake_up_all(&control_waitq);
	return 0;
}

static struct pernet_operations livepatch_test_pernet_ops = {
	.init = livepatch_test_pernet_init,
};

static int livepatch_test_pernet_holder(void *unused)
{
	(void)unused;

	for (;;) {
		int ret;

		wait_event(control_waitq,
			   kthread_should_stop() || READ_ONCE(hold_requested));
		if (kthread_should_stop())
			break;

		/*
		 * register_pernet_subsys() holds pernet_ops_rwsem for write
		 * while it invokes ->init() for every existing net namespace.
		 * Blocking the first callback makes the livepatch callbacks'
		 * vpsadminos_pernet_try_register() fail deterministically.
		 */
		ret = register_pernet_subsys(&livepatch_test_pernet_ops);
		if (!ret)
			unregister_pernet_subsys(&livepatch_test_pernet_ops);
	}

	return 0;
}

static int __init livepatch_test_pernet_hold_init(void)
{
	holder_task = kthread_run(livepatch_test_pernet_holder, NULL,
				  "livepatch-pernet-hold");
	return PTR_ERR_OR_ZERO(holder_task);
}

static void __exit livepatch_test_pernet_hold_exit(void)
{
	WRITE_ONCE(hold_requested, false);
	wake_up_all(&control_waitq);
	kthread_stop(holder_task);
}

module_init(livepatch_test_pernet_hold_init);
module_exit(livepatch_test_pernet_hold_exit);

MODULE_AUTHOR("vpsAdminOS");
MODULE_DESCRIPTION("Test-only pernet registration holder for livepatch failure tests");
MODULE_LICENSE("GPL");
