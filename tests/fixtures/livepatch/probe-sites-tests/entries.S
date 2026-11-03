/* Tiny, unexecuted x86-64 entry contracts; no kernel or module build. */
#ifndef TEXT_PADDING
#define TEXT_PADDING 0
#endif

.text
.if TEXT_PADDING
.space TEXT_PADDING, 0x90
.endif

.macro entry name
  .p2align 4
  .globl \name
  .type \name, @function
\name:
#ifdef UNSAFE_ENTRY_PREFIX
  xor %edi, %edi
#endif
#ifdef UNSAFE_ENTRY_FRAME
  push %rbp
  mov %rsp, %rbp
#endif
  call __fentry__
  .globl fixture_\name\()_entry
fixture_\name\()_entry:
  push %rbp
  mov %rsp, %rbp
  pop %rbp
  ret
  .size \name, .-\name
.endm

entry svm_vcpu_run
entry nft_pipapo_insert
entry xs_tcp_tls_setup_socket

.section .note.GNU-stack,"",@progbits
