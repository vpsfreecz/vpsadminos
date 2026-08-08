// SPDX-License-Identifier: GPL-2.0-only
#include <err.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void)
{
	struct kvm_userspace_memory_region region = {
		.slot = 0,
		.guest_phys_addr = 0,
		.memory_size = 4096,
	};
	struct kvm_sregs sregs;
	struct kvm_regs regs = {
		.rflags = 2,
		.rip = 0,
		.rsp = 0x1000,
	};
	struct kvm_run *run;
	size_t run_size;
	uint8_t *memory;
	int kvm_fd;
	int vcpu_fd;
	int vm_fd;

	kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
	if (kvm_fd < 0)
		err(EXIT_FAILURE, "open /dev/kvm");
	if (ioctl(kvm_fd, KVM_GET_API_VERSION, 0) != KVM_API_VERSION)
		err(EXIT_FAILURE, "KVM_GET_API_VERSION");

	vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
	if (vm_fd < 0)
		err(EXIT_FAILURE, "KVM_CREATE_VM");
	if (ioctl(vm_fd, KVM_SET_TSS_ADDR, 0xfffbd000) < 0)
		err(EXIT_FAILURE, "KVM_SET_TSS_ADDR");

	memory = mmap(NULL, region.memory_size, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (memory == MAP_FAILED)
		err(EXIT_FAILURE, "mmap guest memory");
	memory[0] = 0xf4; /* HLT */
	region.userspace_addr = (uintptr_t)memory;
	if (ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region) < 0)
		err(EXIT_FAILURE, "KVM_SET_USER_MEMORY_REGION");

	vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
	if (vcpu_fd < 0)
		err(EXIT_FAILURE, "KVM_CREATE_VCPU");
	run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (run_size < sizeof(*run))
		err(EXIT_FAILURE, "KVM_GET_VCPU_MMAP_SIZE");
	run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu_fd, 0);
	if (run == MAP_FAILED)
		err(EXIT_FAILURE, "mmap kvm_run");

	if (ioctl(vcpu_fd, KVM_GET_SREGS, &sregs) < 0)
		err(EXIT_FAILURE, "KVM_GET_SREGS");
	sregs.cs.base = 0;
	sregs.cs.selector = 0;
	if (ioctl(vcpu_fd, KVM_SET_SREGS, &sregs) < 0)
		err(EXIT_FAILURE, "KVM_SET_SREGS");
	if (ioctl(vcpu_fd, KVM_SET_REGS, &regs) < 0)
		err(EXIT_FAILURE, "KVM_SET_REGS");
	if (ioctl(vcpu_fd, KVM_RUN, 0) < 0)
		err(EXIT_FAILURE, "KVM_RUN");
	if (run->exit_reason != KVM_EXIT_HLT)
		errx(EXIT_FAILURE, "unexpected KVM exit %u", run->exit_reason);

	puts("kvm smoke passed");
	return EXIT_SUCCESS;
}
