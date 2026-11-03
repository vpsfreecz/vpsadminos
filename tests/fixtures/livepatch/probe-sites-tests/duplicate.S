/* An exact-name local function alongside the original global definition. */
.text
.local svm_vcpu_run
.type svm_vcpu_run, @function
svm_vcpu_run:
  call __fentry__
  push %rbp
  mov %rsp, %rbp
  pop %rbp
  ret
.size svm_vcpu_run, .-svm_vcpu_run
.section .note.GNU-stack,"",@progbits
