args:

import ./bpf-atomic-fetch-precision.nix (
  args
  // {
    profile = {
      fixId = "bpf-null-call-argument-precision";
      oracleId = "bpf-null-call-argument-precision-operation-safety";
      programName = "bpf_null_call_argument_precision";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-null-call-argument-precision.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-null-call-argument-precision.sh";
      bpfSource = ''
        // SPDX-License-Identifier: GPL-2.0
        #include <linux/bpf.h>
        #include <bpf/bpf_helpers.h>

        static int null_context_callback(__u32 index, void *context)
        {
          return 0;
        }

        SEC("socket")
        int bpf_null_call_argument_precision(struct __sk_buff *skb)
        {
          long result = bpf_loop(2, null_context_callback, (void *)0, 0);

          return result == 2 ? skb->len : 0;
        }

        char LICENSE[] SEC("license") = "GPL";
      '';
    };
  }
)
