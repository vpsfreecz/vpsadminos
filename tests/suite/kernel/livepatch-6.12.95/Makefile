obj-m += livepatch_test_pernet_hold.o
obj-m += livepatch_test_probe.o
livepatch_test_probe-y := livepatch_test_probe_main.o \
	livepatch_test_probe_trampoline.o

ccflags-y += -I$(srctree)/arch/x86/kvm
ccflags-y += -I$(srctree)/arch/x86/kvm/svm
