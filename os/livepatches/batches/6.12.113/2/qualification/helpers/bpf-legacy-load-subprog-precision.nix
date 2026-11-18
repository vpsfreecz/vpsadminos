args:

import ./bpf-atomic-fetch-precision.nix (
  args
  // {
    profile = {
      fixId = "bpf-legacy-load-subprog-precision";
      oracleId = "bpf-legacy-load-subprog-precision-operation-safety";
      programName = "bpf_legacy_load_subprog_precision";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-legacy-load-subprog-precision.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-legacy-load-subprog-precision.sh";
      bpfSource = ''
        // SPDX-License-Identifier: GPL-2.0
        #include <linux/bpf.h>
        #include <bpf/bpf_helpers.h>

        __attribute__((naked, noinline, used))
        static int legacy_load_subprogram(void)
        {
          asm volatile (
            "r6 = r1;"
            ".8byte 0x20;"
            "r0 = 1;"
            "exit;"
          );
        }

        SEC("socket")
        __attribute__((naked))
        int bpf_legacy_load_subprog_precision(void)
        {
          asm volatile (
            "call legacy_load_subprogram;"
            "if r0 != 1 goto 1f;"
            "r0 = 64;"
            "1: exit;"
          );
        }

        char LICENSE[] SEC("license") = "GPL";
      '';
    };
  }
)
