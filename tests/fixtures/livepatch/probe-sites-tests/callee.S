/* Original FUSE function; local binding permits an ambiguity control at link. */
.text
.p2align 4
.local fuse_copy_finish
.type fuse_copy_finish, @function
fuse_copy_finish:
#ifdef UNSAFE_CALLEE_FRAME
  push %rbp
  mov %rsp, %rbp
#endif
  call __fentry__
  .local fixture_fuse_hold
fixture_fuse_hold:
  push %rbp
#ifdef SCHEDULED_CALLEE_PROLOGUE
  /* This register move executes after the selected hold point. */
  mov %rdi, %rdx
#endif
  mov %rsp, %rbp
  pop %rbp
  ret
.size fuse_copy_finish, .-fuse_copy_finish
.section .note.GNU-stack,"",@progbits
