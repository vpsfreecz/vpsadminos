{ kernelVersion }:
{
  # The reviewed native .110 candidate must expose the NFS cancellation ABI
  # without a livepatch and run KVM on both vendors. Stable cannot substitute
  # for that exact target; retire this directory with the kernel.
  runnerTests = [
    {
      template = "kernel/livepatch-lifecycle";
      instances = [ { inherit kernelVersion; } ];
    }
  ];
}
