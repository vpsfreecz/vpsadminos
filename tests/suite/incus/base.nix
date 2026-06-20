{
  distribution,
  tests,
}:
import ../../make-test.nix (
  { pkgs }:
  let
    common = ''
      require 'json'
      require 'shellwords'

      def ensure_machine
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      def cleanup_container(ct)
        return unless machine.running?

        begin
          machine.succeeds("osctl ct del -f --prune #{ct}")
        rescue OsVm::CommandFailed
          # Best effort cleanup after failed setup.
        end

        begin
          machine.succeeds("osctl user del #{ct}")
        rescue OsVm::CommandFailed
          # The user may have been removed with the container.
        end

        begin
          machine.succeeds('osctl repository images prune')
        rescue OsVm::CommandFailed
          # Best effort cleanup after failed setup.
        end
      end

      def ct_shell(ct, script, timeout: 600)
        machine.succeeds(
          "osctl ct exec #{ct} sh -c #{Shellwords.escape(script)}",
          timeout:
        )
      end

      def ct_execute(ct, script, timeout: 600)
        machine.execute(
          "osctl ct exec #{ct} sh -c #{Shellwords.escape(script)}",
          timeout:
        )
      end

      def ct_background(ct, name, script)
        status_path = "/tmp/#{name}.status"
        log_path = "/tmp/#{name}.log"
        pid_path = "/tmp/#{name}.pid"

        ct_shell(
          ct,
          <<~SH
            rm -f #{status_path} #{log_path} #{pid_path}
            nohup sh -c #{Shellwords.escape("#{script} > #{log_path} 2>&1; printf '%s\\n' $? > #{status_path}")} >/dev/null 2>&1 &
            echo $! > #{pid_path}
          SH
        )

        { name:, status_path:, log_path:, pid_path: }
      end

      def ct_job_failure_output(ct, job, diagnostic_cmd:)
        _, log_output = ct_execute(ct, "cat #{job[:log_path]} 2>/dev/null || true", timeout: 30)
        return log_output if diagnostic_cmd.nil?

        _, diagnostic_output = ct_execute(ct, "#{diagnostic_cmd} 2>&1 || true", timeout: 30)
        "#{log_output}\n--- diagnostic output ---\n#{diagnostic_output}"
      end

      def wait_for_ct_job(ct, job, check_cmd: nil, timeout:, diagnostic_cmd: nil)
        deadline = Time.now + timeout

        loop do
          st, output = ct_execute(ct, "test -f #{job[:status_path]} && cat #{job[:status_path]}", timeout: 30)

          if st == 0
            rc = output.strip

            if rc != '0'
              log_output = ct_job_failure_output(ct, job, diagnostic_cmd:)
              fail "#{job[:name]} failed with status #{rc}, log: #{log_output.inspect}"
            end

            return
          end

          unless check_cmd.nil?
            st, = machine.execute(check_cmd, timeout: 30)

            if st == 0
              ct_execute(
                ct,
                "test -f #{job[:pid_path]} && kill $(cat #{job[:pid_path]}) 2>/dev/null || true",
                timeout: 30
              )
              return
            end
          end

          if Time.now > deadline
            log_output = ct_job_failure_output(ct, job, diagnostic_cmd:)
            fail "timed out waiting for #{job[:name]}, log: #{log_output.inspect}"
          end

          sleep(2)
        end
      end

      def wait_for_ct_job_completion(ct, job, timeout:)
        wait_for_ct_job(ct, job, timeout:)
      end

      def latest_debian_image(ct)
        _, output = machine.succeeds(
          "osctl ct exec #{ct} incus image list images: debian --format json",
          timeout: 300
        )

        aliases = JSON.parse(output).filter_map do |image|
          next unless image['type'] == 'container'

          Array(image['aliases']).filter_map do |al|
            al.is_a?(Hash) ? al['name'] : nil
          end
        end.flatten

        # Avoid future/testing aliases when they are published before becoming
        # stable releases.
        stable_alias = %w[
          debian/13
          debian/trixie
          debian/12
          debian/bookworm
          debian/11
          debian/bullseye
        ].find { |name| aliases.include?(name) }

        if stable_alias.nil?
          fail "unable to find a supported stable Debian container image, incus image list output: #{output.inspect}"
        end

        stable_alias
      end

      def create_incus_container(ct, distribution, version, map_base)
        machine.succeeds("osctl user new --no-standalone --map 0:#{map_base}:524288 #{ct}")

        machine.all_succeed(
          "osctl ct new --user #{ct} --distribution #{distribution} --version #{version} #{ct}",
          "osctl ct unset start-menu #{ct}",
          "osctl ct set nesting #{ct}",
          "osctl ct netif new bridge --link lxcbr0 #{ct} eth0",

          # TODO: why is this needed?
          "osctl ct set dns-resolver #{ct} 1.1.1.1",

          "osctl ct start #{ct}",
        )

        machine.wait_until_container_online(ct)
      end

      def check_incus(ct, pre_start: nil)
        # Nested Incus needs a dedicated ID-mapped range for containers.
        ct_shell(
          ct,
          <<~SH
            printf '%s\n' 'root:100000:65536' > /etc/subuid
            printf '%s\n' 'root:100000:65536' > /etc/subgid
          SH
        )

        ct_shell(
          ct,
          <<~SH
            systemctl stop incus.service incus.socket 2>/dev/null || true
            systemctl enable --now incus.socket || systemctl enable --now incus.service
          SH
        )

        machine.wait_until_succeeds(
          "osctl ct exec #{ct} sh -c 'systemctl is-active --quiet incus.socket || systemctl is-active --quiet incus.service'",
          timeout: 120
        )

        ct_shell(ct, <<~SH, timeout: 300)
          cat <<'EOF' | incus admin init --preseed
          storage_pools:
          - name: default
            driver: dir
          profiles:
          - name: default
            devices:
              root:
                path: /
                pool: default
                type: disk
          EOF
        SH

        debian_image = latest_debian_image(ct)
        init_job = ct_background(ct, 'incus-init', "incus init images:#{debian_image} i1")

        wait_for_ct_job_completion(ct, init_job, timeout: 900)

        pre_start&.call

        start_job = ct_background(ct, 'incus-start', 'incus start i1')

        wait_for_ct_job(
          ct,
          start_job,
          check_cmd: "osctl ct exec #{ct} sh -c \"incus info i1 | grep -q 'Status: RUNNING'\"",
          timeout: 300,
          diagnostic_cmd: 'incus info --show-log i1'
        )

        machine.wait_until_succeeds(
          "osctl ct exec #{ct} sh -c \"incus info i1 | grep -q 'Status: RUNNING'\"",
          timeout: 300
        )

        _, output = machine.succeeds("osctl ct exec #{ct} incus info i1")

        if /Status: RUNNING/ !~ output
          fail "incus container not running, incus info output: #{output.inspect}"
        end

        if /Type: container/ !~ output
          fail "expected type container, incus info output: #{output.inspect}"
        end

        machine.succeeds("osctl ct exec #{ct} incus exec i1 -- true", timeout: 300)
      end
    '';
  in
  {
    name = "incus-${distribution}";

    description = ''
      Test Incus on ${distribution}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScripts = builtins.listToAttrs (
      map (test: {
        name = test.version;
        value = {
          expectFailure = test.expectFailure or false;
          description = ''
            Test Incus on ${distribution} ${test.version}
          '';
          script = common + ''
            ct = get_container_id('incus')

            begin
              ensure_machine
              create_incus_container(ct, '${distribution}', '${test.version}', ${toString test.mapBase})
              ${test.setup}
              pre_start = proc do
                ${test.preStart or ""}
              end
              check_incus(ct, pre_start:)
            ensure
              cleanup_container(ct)
            end
          '';
        };
      }) tests
    );
  }
)
