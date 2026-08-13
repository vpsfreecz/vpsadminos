// SPDX-License-Identifier: GPL-2.0-only

#include "test_util.h"
#include "kvm_util.h"
#include "processor.h"
#include "svm_util.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *ready_paths[3];
static const char *release_paths[3];

static void write_ready(unsigned int stage)
{
	const char *ready_path = ready_paths[stage - 1];
	int fd = open(ready_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);

	TEST_ASSERT(fd >= 0, "open(%s) failed, errno=%d", ready_path, errno);
	TEST_ASSERT(write(fd, "ready\n", 6) == 6,
		    "write(%s) failed, errno=%d", ready_path, errno);
	TEST_ASSERT(!close(fd), "close(%s) failed, errno=%d", ready_path,
		    errno);
}

static void wait_for_release(unsigned int stage)
{
	const char *release_path = release_paths[stage - 1];
	struct stat statbuf;

	while (stat(release_path, &statbuf)) {
		TEST_ASSERT(errno == ENOENT, "stat(%s) failed, errno=%d",
			    release_path, errno);
		usleep(1000);
	}
}

static void l2_guest_code(struct svm_test_data *svm)
{
	(void)svm;
	for (;;)
		vmmcall();
}

static void l1_guest_code(struct svm_test_data *svm)
{
	#define L2_GUEST_STACK_SIZE 64
	unsigned long l2_guest_stack[L2_GUEST_STACK_SIZE];
	struct vmcb *vmcb = svm->vmcb;

	generic_svm_setup(svm, l2_guest_code,
			  &l2_guest_stack[L2_GUEST_STACK_SIZE]);
	run_guest(vmcb, svm->vmcb_gpa);
	GUEST_ASSERT(vmcb->control.exit_code == SVM_EXIT_VMMCALL);
	vmcb->save.rip += 3;
	GUEST_SYNC(1);
	run_guest(vmcb, svm->vmcb_gpa);
	GUEST_ASSERT(vmcb->control.exit_code == SVM_EXIT_VMMCALL);
	vmcb->save.rip += 3;
	GUEST_SYNC(2);
	run_guest(vmcb, svm->vmcb_gpa);
	GUEST_ASSERT(vmcb->control.exit_code == SVM_EXIT_VMMCALL);
	vmcb->save.rip += 3;
	GUEST_SYNC(3);
	GUEST_DONE();
}

int main(int argc, char **argv)
{
	struct kvm_vcpu *vcpu;
	vm_vaddr_t svm_gva;
	struct kvm_vm *vm;

	TEST_ASSERT(argc == 7,
		    "usage: %s READY1 RELEASE1 READY2 RELEASE2 READY3 RELEASE3",
		    argv[0]);
	ready_paths[0] = argv[1];
	release_paths[0] = argv[2];
	ready_paths[1] = argv[3];
	release_paths[1] = argv[4];
	ready_paths[2] = argv[5];
	release_paths[2] = argv[6];
	TEST_REQUIRE(kvm_cpu_has(X86_FEATURE_SVM));
	vm = vm_create_with_one_vcpu(&vcpu, l1_guest_code);
	vcpu_alloc_svm(vm, &svm_gva);
	vcpu_args_set(vcpu, 1, svm_gva);

	for (;;) {
		struct ucall uc;

		vcpu_run(vcpu);
		TEST_ASSERT_KVM_EXIT_REASON(vcpu, KVM_EXIT_IO);
		switch (get_ucall(vcpu, &uc)) {
		case UCALL_ABORT:
			REPORT_GUEST_ASSERT(uc);
		case UCALL_DONE:
			kvm_vm_free(vm);
			return 0;
		case UCALL_SYNC:
			TEST_ASSERT(uc.args[1] >= 1 && uc.args[1] <= 3,
				    "Unexpected stage %lu", uc.args[1]);
			write_ready(uc.args[1]);
			wait_for_release(uc.args[1]);
			break;
		default:
			TEST_FAIL("Unknown ucall 0x%lx.", uc.cmd);
		}
	}
}
