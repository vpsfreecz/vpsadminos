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

      machine.all_succeed(
        "dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none",
        "chmod 600 /swapfile",
        "mkswap /swapfile",
        "swapon /swapfile"
      )
      machine.wait_until_succeeds("grep -q '^/swapfile' /proc/swaps")

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

        size = 768 * 1024 * 1024
        buf = bytearray(size)
        for i in range(0, size, 4096):
            buf[i] = 1

        print("ready", flush=True)
        time.sleep(600)
        PY
      SH

      machine.succeeds(<<~SH)
        sh -eu -c '
          python3 /tmp/proactive-holder.py >/tmp/proactive-holder.out 2>&1 &
          pid=$!
          echo "$pid" > /tmp/proactive-holder.pid
          echo "$pid" > #{cgroup}/cgroup.procs
          for i in $(seq 1 100); do
            grep -q "^ready$" /tmp/proactive-holder.out && exit 0
            sleep 0.1
          done
          exit 1
        '
      SH

      machine.wait_until_succeeds("test $(cat #{cgroup}/memory.current) -gt #{700 * 1024 * 1024}")

      machine.succeeds(<<~'SH')
        sh -eu -c '
          params=/sys/module/damon_reclaim/parameters
          avail_kb=$(awk "/MemAvailable:/ {print \$2}" /proc/meminfo)
          target_bytes=$((avail_kb * 1024 + 512 * 1024 * 1024))
          echo 100000 > "$params/min_age"
          echo 1000 > "$params/quota_ms"
          echo 1073741824 > "$params/quota_sz"
          echo 1000 > "$params/quota_reset_interval_ms"
          echo "$target_bytes" > "$params/quota_free_mem_bytes"
          echo N > "$params/skip_anon"
          echo Y > "$params/commit_inputs"
        '
      SH

      machine.wait_until_succeeds("test $(cat #{cgroup}/memory.swap.current) -gt 0", timeout: 180)
      machine.wait_until_succeeds("test $(awk '/^proactive / {print $2}' #{cgroup}/memory.swap.events) -gt 0", timeout: 180)

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
