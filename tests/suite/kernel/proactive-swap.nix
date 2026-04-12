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
      config =
        { lib, ... }:
        {
          imports = [
            ../../../os/configs/proactive-swap-qemu.nix
          ];

          boot.enableUnifiedCgroupHierarchy = true;
          boot.qemu.memory = lib.mkOverride 40 2048;
          boot.kernel.sysctl."vm.min_free_kbytes" = lib.mkOverride 40 65536;

          environment.systemPackages = with pkgs; [
            python3
            sysinfo-to-json
          ];

          runit.services.proactive-swap-smoke.run = lib.mkForce ''
            exec sleep infinity
          '';
          runit.services.proactive-swap-smoke.oneShot = lib.mkForce false;
        };
    };

    testScript = ''
      def self.parse_meminfo(content)
        content.strip.each_line.to_h do |line|
          param, value, _ = line.split
          [param[0..-2], value.to_i]
        end
      end

      def self.parse_sysinfo(content)
        JSON.parse(content)
      end

      def self.read_in_cgroup(cgroup, command)
        machine.succeeds("sh -c 'echo $$ > #{cgroup}/cgroup.procs; exec #{command}'")[1]
      end

      machine.start

      machine.wait_for_service("damon-reclaim")
      machine.wait_until_succeeds("test -d /sys/module/damon_reclaim/parameters")
      machine.wait_until_succeeds("test \"$(cat /sys/module/damon_reclaim/parameters/enabled)\" = Y")

      _, free_mem_bytes = machine.succeeds("cat /sys/module/damon_reclaim/parameters/quota_free_mem_bytes")
      expect(free_mem_bytes.strip).to eq("536870912")

      _, free_mem_rate = machine.succeeds("cat /sys/module/damon_reclaim/parameters/quota_free_mem_rate")
      expect(free_mem_rate.strip).to eq("0")

      _, kdamond_pid = machine.succeeds("cat /sys/module/damon_reclaim/parameters/kdamond_pid")
      expect(kdamond_pid.strip.to_i).to be > 0

      host_swap_bytes = 1024 * 1024 * 1024

      _, host_swap_device = machine.succeeds(<<~SH)
        sh -eu -c '
          modprobe zram
          zramctl --find --size #{host_swap_bytes}
        '
      SH
      host_swap_device = host_swap_device.strip

      machine.all_succeed(
        "mkswap #{host_swap_device}",
        "swapon #{host_swap_device}"
      )
      machine.wait_until_succeeds("grep -q '^#{host_swap_device}' /proc/swaps")

      cgroup = "/sys/fs/cgroup/proactive-test"
      normal_swap_bytes = 64 * 1024 * 1024
      normal_swap_kb = normal_swap_bytes / 1024

      machine.all_succeed(
        "mkdir -p #{cgroup}",
        "printf '%d' #{1536 * 1024 * 1024} > #{cgroup}/memory.max",
        "printf '%d' #{normal_swap_bytes} > #{cgroup}/memory.swap.max"
      )

      machine.succeeds(<<~'SH')
        cat > /tmp/proactive-holder.py <<'PY'
        import time

        size = 1024 * 1024 * 1024
        buf = bytearray(size)
        for i in range(0, size, 4096):
            buf[i] = 1

        print("ready", flush=True)
        time.sleep(600)
        PY
      SH

      machine.succeeds(<<~SH)
        sh -eu -c '
          : > /tmp/proactive-holder.out
          python3 /tmp/proactive-holder.py >/tmp/proactive-holder.out 2>&1 &
          pid=$!
          echo "$pid" > /tmp/proactive-holder.pid
          echo "$pid" > #{cgroup}/cgroup.procs
          for i in $(seq 1 300); do
            grep -q "^ready$" /tmp/proactive-holder.out && exit 0
            kill -0 "$pid" 2>/dev/null || { cat /tmp/proactive-holder.out >&2; exit 1; }
            sleep 0.1
          done
          cat /tmp/proactive-holder.out >&2 || true
          exit 1
        '
      SH

      machine.wait_until_succeeds("test $(cat #{cgroup}/memory.current) -gt #{900 * 1024 * 1024}")
      machine.succeeds("sleep 5")

      machine.all_succeed(
        "sv down damon-reclaim",
        "printf N > /sys/module/damon_reclaim/parameters/enabled"
      )
      machine.wait_until_succeeds("test \"$(cat /sys/module/damon_reclaim/parameters/enabled)\" = N")

      machine.succeeds(<<~'SH')
        sh -eu -c '
          admin=/sys/kernel/mm/damon/admin
          kd="$admin/kdamonds/0"
          ctx="$kd/contexts/0"
          target="$ctx/targets/0"
          scheme="$ctx/schemes/0"
          region="$target/regions/0"
          filters="$scheme/filters"

          echo 1 > "$admin/kdamonds/nr_kdamonds"
          echo 1 > "$kd/contexts/nr_contexts"
          echo paddr > "$ctx/operations"

          echo 5000 > "$ctx/monitoring_attrs/intervals/sample_us"
          echo 100000 > "$ctx/monitoring_attrs/intervals/aggr_us"
          echo 0 > "$ctx/monitoring_attrs/intervals/update_us"
          echo 10 > "$ctx/monitoring_attrs/nr_regions/min"
          echo 1000 > "$ctx/monitoring_attrs/nr_regions/max"

          echo 1 > "$ctx/targets/nr_targets"
          echo 1 > "$target/regions/nr_regions"

          python3 - <<'PY' > /tmp/damon-target-region
import re

best = None
with open("/proc/iomem") as f:
    for line in f:
        m = re.match(r"^([0-9a-fA-F]+)-([0-9a-fA-F]+) : System RAM$", line.strip())
        if not m:
            continue
        start = int(m.group(1), 16)
        end = int(m.group(2), 16) + 1
        size = end - start
        if best is None or size > best[0]:
            best = (size, start, end)

if best is None:
    raise SystemExit("failed to find System RAM region")

print(best[1])
print(best[2])
PY

          start=$(sed -n "1p" /tmp/damon-target-region)
          end=$(sed -n "2p" /tmp/damon-target-region)
          echo "$start" > "$region/start"
          echo "$end" > "$region/end"

          echo 1 > "$ctx/schemes/nr_schemes"
          echo pageout > "$scheme/action"
          echo 0 > "$scheme/apply_interval_us"
          echo 4096 > "$scheme/access_pattern/sz/min"
          echo 1073741824 > "$scheme/access_pattern/sz/max"
          echo 0 > "$scheme/access_pattern/nr_accesses/min"
          echo 0 > "$scheme/access_pattern/nr_accesses/max"
          echo 10 > "$scheme/access_pattern/age/min"
          echo 4294967295 > "$scheme/access_pattern/age/max"

          echo 0 > "$scheme/quotas/ms"
          echo 1073741824 > "$scheme/quotas/bytes"
          echo 1000 > "$scheme/quotas/reset_interval_ms"

          echo none > "$scheme/watermarks/metric"
          echo 5000000 > "$scheme/watermarks/interval_us"
          echo 1000 > "$scheme/watermarks/high"
          echo 1000 > "$scheme/watermarks/mid"
          echo 0 > "$scheme/watermarks/low"

          echo 2 > "$filters/nr_filters"
          echo anon > "$filters/0/type"
          echo N > "$filters/0/matching"
          echo memcg > "$filters/1/type"
          echo N > "$filters/1/matching"
          echo /proactive-test > "$filters/1/memcg_path"

          echo on > "$kd/state"
        '
      SH

      machine.wait_until_succeeds(
        "sh -eu -c 'echo update_schemes_stats > /sys/kernel/mm/damon/admin/kdamonds/0/state; test $(cat /sys/kernel/mm/damon/admin/kdamonds/0/contexts/0/schemes/0/stats/sz_applied) -gt 0'",
        timeout: 180
      )
      machine.wait_until_succeeds("test $(cat #{cgroup}/memory.swap.current) -gt #{normal_swap_bytes}", timeout: 180)
      machine.wait_until_succeeds("test $(awk '/^proactive / {print $2}' #{cgroup}/memory.swap.events) -gt 0", timeout: 180)

      machine.all_succeed(
        "echo off > /sys/kernel/mm/damon/admin/kdamonds/0/state",
        "sleep 1"
      )
      machine.wait_until_succeeds("test \"$(cat /sys/kernel/mm/damon/admin/kdamonds/0/state)\" = off")

      proactive_swap_bytes =
        machine.succeeds("cat #{cgroup}/memory.swap.current")[1].strip.to_i

      meminfo = parse_meminfo(read_in_cgroup(cgroup, "cat /proc/meminfo"))
      sysinfo = parse_sysinfo(read_in_cgroup(cgroup, "sysinfo-to-json"))
      swaps = read_in_cgroup(cgroup, "cat /proc/swaps").strip.split("\n")

      expect(proactive_swap_bytes).to be > 0
      expect(meminfo["SwapTotal"]).to eq(normal_swap_kb + (proactive_swap_bytes / 1024))
      expect(meminfo["SwapFree"]).to eq(normal_swap_kb)

      expect(sysinfo["totalswap"]).to eq(normal_swap_bytes + proactive_swap_bytes)
      expect(sysinfo["freeswap"]).to eq(normal_swap_bytes)

      expect(swaps.length).to eq(3)
      expect(swaps[0]).to start_with("Filename")

      virtual = swaps[1].split
      expect(virtual[0]).to eq("virtual")
      expect(virtual[1]).to eq("virtual")
      expect(virtual[2].to_i).to eq(normal_swap_bytes)
      expect(virtual[3].to_i).to eq(0)
      expect(virtual[4].to_i).to eq(-1)

      virtual_system = swaps[2].split
      expect(virtual_system[0]).to eq("virtual-system")
      expect(virtual_system[1]).to eq("virtual")
      expect(virtual_system[2].to_i).to eq(proactive_swap_bytes)
      expect(virtual_system[3].to_i).to eq(proactive_swap_bytes)
      expect(virtual_system[4].to_i).to eq(-2)
    '';
  }
)
