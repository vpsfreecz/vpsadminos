{
  distribution,
  version,
  setupScript,
}:
import ../../make-test.nix (
  { pkgs }:
  {
    name = "incus-${distribution}-${version}";

    description = ''
      Test Incus on ${distribution} ${version}
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'json'
      require 'shellwords'

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

      def wait_for_ct_job(ct, job, check_cmd:, timeout:)
        deadline = Time.now + timeout

        loop do
          st, output = ct_execute(ct, "test -f #{job[:status_path]} && cat #{job[:status_path]}", timeout: 30)

          if st == 0
            rc = output.strip

            if rc != '0'
              _, log_output = ct_execute(ct, "cat #{job[:log_path]} 2>/dev/null || true", timeout: 30)
              fail "#{job[:name]} failed with status #{rc}, log: #{log_output.inspect}"
            end

            return
          end

          st, = machine.execute(check_cmd, timeout: 30)

          if st == 0
            ct_execute(
              ct,
              "test -f #{job[:pid_path]} && kill $(cat #{job[:pid_path]}) 2>/dev/null || true",
              timeout: 30
            )
            return
          end

          if Time.now > deadline
            _, log_output = ct_execute(ct, "cat #{job[:log_path]} 2>/dev/null || true", timeout: 30)
            fail "timed out waiting for #{job[:name]}, log: #{log_output.inspect}"
          end

          sleep(2)
        end
      end

      def latest_debian_image(ct)
        _, output = machine.succeeds(
          "osctl ct exec #{ct} incus image list images: debian --format json",
          timeout: 300
        )

        candidates = JSON.parse(output).filter_map do |image|
          next unless image['type'] == 'container'

          aliases = Array(image['aliases']).filter_map do |al|
            al.is_a?(Hash) ? al['name'] : nil
          end
          numeric_aliases = aliases.filter_map do |name|
            match = %r{\Adebian/(\d+)\z}.match(name)
            next if match.nil?

            { alias: name, release: match[1].to_i }
          end

          alias_name =
            if numeric_aliases.empty?
              aliases.find { |name| %r{\Adebian/[^/]+\z}.match?(name) }
            else
              numeric_aliases.max_by { |v| v[:release] }.fetch(:alias)
            end
          next if alias_name.nil?

          release =
            numeric_aliases.empty? ? -1 : numeric_aliases.max_by { |v| v[:release] }.fetch(:release)

          {
            alias: alias_name,
            sort_key: [
              release,
              image['uploaded_at'].to_s,
              alias_name,
            ],
          }
        end

        if candidates.empty?
          fail "unable to find a Debian container image, incus image list output: #{output.inspect}"
        end

        candidates.max_by { |candidate| candidate[:sort_key] }.fetch(:alias)
      end

      machine.start
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online

      machine.succeeds("osctl user new --map 0:100000:524288 incusct")

      machine.all_succeed(
        "osctl ct new --distribution ${distribution} --version ${version} incusct",
        "osctl ct unset start-menu incusct",
        "osctl ct set nesting incusct",
        "osctl ct netif new bridge --link lxcbr0 incusct eth0",

        # TODO: why is this needed?
        "osctl ct set dns-resolver incusct 1.1.1.1",

        "osctl ct start incusct",
      )

      machine.wait_until_container_online('incusct')

      ${setupScript}

      # Nested Incus needs a dedicated ID-mapped range for containers.
      ct_shell(
        'incusct',
        <<~SH
          printf '%s\n' 'root:100000:65536' > /etc/subuid
          printf '%s\n' 'root:100000:65536' > /etc/subgid
        SH
      )

      ct_shell(
        'incusct',
        <<~SH
          systemctl stop incus.service incus.socket 2>/dev/null || true
          systemctl enable --now incus.socket || systemctl enable --now incus.service
        SH
      )

      machine.wait_until_succeeds(
        "osctl ct exec incusct sh -c 'systemctl is-active --quiet incus.socket || systemctl is-active --quiet incus.service'",
        timeout: 120
      )

      ct_shell('incusct', <<~SH, timeout: 300)
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

      debian_image = latest_debian_image('incusct')
      init_job = ct_background('incusct', 'incus-init', "incus init images:#{debian_image} i1")

      wait_for_ct_job(
        'incusct',
        init_job,
        check_cmd: "osctl ct exec incusct incus info i1",
        timeout: 900
      )

      start_job = ct_background('incusct', 'incus-start', 'incus start i1')

      wait_for_ct_job(
        'incusct',
        start_job,
        check_cmd: "osctl ct exec incusct sh -c \"incus info i1 | grep -q 'Status: RUNNING'\"",
        timeout: 300
      )

      machine.wait_until_succeeds(
        "osctl ct exec incusct sh -c \"incus info i1 | grep -q 'Status: RUNNING'\"",
        timeout: 300
      )

      _, output = machine.succeeds("osctl ct exec incusct incus info i1")

      if /Status: RUNNING/ !~ output
        fail "incus container not running, incus info output: #{output.inspect}"
      end

      if /Type: container/ !~ output
        fail "expected type container, incus info output: #{output.inspect}"
      end

      machine.succeeds("osctl ct exec incusct incus exec i1 -- true", timeout: 300)
    '';
  }
)
