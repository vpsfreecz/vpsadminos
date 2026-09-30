import ../../make-test.nix (
  { pkgs }:
  let
    title = "clamps a preactivation-oversized TUN align at use time";
    common = import ./livepatch-6.12.95-common.nix {
      inherit pkgs;
      selectedExample = title;
    };
  in
  common
  // {
    name = "kernel-livepatch-tun-intel";
    description = "Intel/KVM: preexisting oversized TUN headroom is clamped at use time";
    tags = [ "livepatch-intel" ];
    testScript = common.testScript + ''
      before(:suite) do
        # This uses the ordinary TestEvaluator DSL, not RSpec's runner.
        expect(get_example_count).to eq(1)
        machine.all_succeed(
          "grep -Eq '^vendor_id[[:space:]]*: GenuineIntel$' /proc/cpuinfo",
          "modprobe kvm_intel", "test -c /dev/kvm", KVM_SMOKE
        )
        machine.succeeds("dmesg")
        @dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
      end
    '';
  }
)
