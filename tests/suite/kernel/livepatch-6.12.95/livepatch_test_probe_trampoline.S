/* SPDX-License-Identifier: GPL-2.0 */

#include <linux/linkage.h>
#include <linux/objtool.h>
#include <asm/nospec-branch.h>
#include <asm/unwind_hints.h>

/*
 * The regular kprobe redirects a function entry or an internal instruction
 * here.  Push an address inside the target as a synthetic return address, then
 * preserve flags and every general-purpose register before sleeping.
 * UNWIND_HINT_FUNC makes the synthetic frame visible to the reliable ORC
 * unwinder, while the original target frame remains directly below it.
 */
SYM_FUNC_START(livepatch_test_hold_trampoline)
	ENDBR
	pushq	livepatch_test_probe_marker(%rip)
	UNWIND_HINT_FUNC

	pushfq
	pushq	%rax
	pushq	%rbx
	pushq	%rcx
	pushq	%rdx
	pushq	%rsi
	pushq	%rdi
	pushq	%rbp
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	call	livepatch_test_wait_for_release
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%r11
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rbp
	popq	%rdi
	popq	%rsi
	popq	%rdx
	popq	%rcx
	popq	%rbx
	popq	%rax
	popfq

	addq	$8, %rsp
	UNWIND_HINT_FUNC

	/*
	 * Tail-call the original entry without clobbering a target register.
	 * The first entry after release is ignored by the probe's current-task
	 * resume guard, so it executes the real first instruction exactly once.
	 */
	pushq	%r11
	movq	livepatch_test_probe_resume(%rip), %r11
	xchgq	%r11, (%rsp)
	UNWIND_HINT_FUNC
	RET
SYM_FUNC_END(livepatch_test_hold_trampoline)
