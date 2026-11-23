{
  description = "Deny ptrace access to mm-less tasks without init-ns CAP_SYS_PTRACE";
  kernelRanges = [
    {
      sinceKernel = "5.7";
      untilKernel = "6.12.89";
    }
  ];
  bpfPrograms = [ "ptrace_mm_guard" ];
  linkFields = [ "ptrace_mm_guard" ];
  enable = true;
}
