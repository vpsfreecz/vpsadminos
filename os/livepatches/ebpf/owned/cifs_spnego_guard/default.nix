{
  description = "Deny userspace-created cifs.spnego keys outside CIFS private upcalls";
  kernelRanges = [
    {
      sinceKernel = "5.7";
      untilKernel = "6.12.92";
    }
  ];
  bpfPrograms = [ "cifs_spnego" ];
  linkFields = [ "cifs_spnego" ];
  enable = true;
}
