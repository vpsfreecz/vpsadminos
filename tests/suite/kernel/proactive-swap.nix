import ../../make-test.nix (
  { pkgs }:
  {
    name = "kernel-proactive-swap";

    description = ''
      Smoke test the proactive DAMON reclaim configuration
    '';

    tags = [ "proactive-swap" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config = {
        imports = [
          ../../../os/configs/proactive-swap-qemu.nix
        ];
      };
    };

    testScript = ''
      machine.start

      machine.wait_for_service("test-shell")
      machine.wait_for_service("damon-reclaim")
      machine.wait_until_succeeds("test -d /sys/module/damon_reclaim/parameters")
      machine.wait_until_succeeds("test \"$(cat /sys/module/damon_reclaim/parameters/enabled)\" = Y")

      _, free_mem_bytes = machine.succeeds("cat /sys/module/damon_reclaim/parameters/quota_free_mem_bytes")
      expect(free_mem_bytes.strip).to eq("536870912")

      _, free_mem_rate = machine.succeeds("cat /sys/module/damon_reclaim/parameters/quota_free_mem_rate")
      expect(free_mem_rate.strip).to eq("0")

      _, kdamond_pid = machine.succeeds("cat /sys/module/damon_reclaim/parameters/kdamond_pid")
      expect(kdamond_pid.strip.to_i).to be > 0
    '';
  }
)
