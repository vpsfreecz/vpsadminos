args:

import ./bpf-atomic-fetch-precision.nix (
  args
  // {
    profile = {
      fixId = "bpf-callback-frame-precision";
      oracleId = "bpf-callback-frame-precision-operation-safety";
      programName = "bpf_callback_frame_precision";
      adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-callback-frame-precision.nix";
      validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-callback-frame-precision.sh";
      bpfSource = ''
        // SPDX-License-Identifier: GPL-2.0
        #include <linux/bpf.h>
        #include <bpf/bpf_helpers.h>

        static int callback_frame(__u32 index, void *context)
        {
          return 0;
        }

        SEC("socket")
        int bpf_callback_frame_precision(struct __sk_buff *skb)
        {
          __u32 iterations = (skb->len & 1) + 1;
          long first = bpf_loop(iterations, callback_frame, (void *)0, 0);
          long second = bpf_loop(iterations, callback_frame, (void *)0, 0);

          return first == iterations && second == iterations ? skb->len : 0;
        }

        char LICENSE[] SEC("license") = "GPL";
      '';
    };
  }
)
