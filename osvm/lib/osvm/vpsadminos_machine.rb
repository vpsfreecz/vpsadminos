require 'json'

module OsVm
  # vpsAdminOS-specific machine driver
  class VpsadminosMachine < Machine
    # osctl command without `osctl`, output is returned as JSON
    # @param cmd [String]
    # @return [Hash]
    def osctl_json(cmd)
      status, output = succeeds("osctl -j #{cmd}")
      JSON.parse(output)
    end

    # Wait for zpool
    # @param name [String]
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_zpool(name, timeout: @default_timeout)
      wait_until_succeeds("zpool list #{name}", timeout:)
      self
    end

    # Wait for pool to be imported into osctld
    # @param name [String]
    # @param timeout [Integer]
    # @return [Machine]
    def wait_for_osctl_pool(name, timeout: 20 * 60, poll_timeout: 60)
      last_state = nil
      last_error = nil
      timeout_message = lambda do
        message = "Timeout occurred while waiting for pool #{name.inspect} to become active"
        message += ", last state: #{last_state.inspect}" if last_state
        message += ", last error: #{last_error.message.inspect}" if last_error
        message
      end
      deadline = monotonic_deadline(timeout)

      remaining_time!(deadline, timeout_message.call)
      start(deadline:, timeout_message: timeout_message.call) unless running?
      wait_for_boot(
        timeout: remaining_time!(deadline, timeout_message.call),
        deadline:,
        timeout_message: timeout_message.call
      )

      loop do
        status = nil
        cur_timeout = remaining_time!(deadline, timeout_message.call)

        begin
          status, output = execute(
            "osctl pool show -H -o state #{name}",
            timeout: [poll_timeout, cur_timeout].min,
            deadline:,
            timeout_message: timeout_message.call
          )
          last_state = output.strip
          last_error = nil
        rescue TimeoutError => e
          last_error = e
          raise UnrecoverableTimeoutError, timeout_message.call if e.is_a?(UnrecoverableTimeoutError)
        end

        remaining_time!(deadline, timeout_message.call)
        return self if status == 0 && last_state == 'active'

        sleep_with_deadline(1, deadline, timeout_message.call)
      end
    end

    # Wait for osctl container to exist and be in a given state
    # @param id [String]
    # @param state [String]
    # @return [Machine]
    def wait_for_osctl_container(id, state: 'running', timeout: @default_timeout)
      t1 = Time.now
      cur_timeout = timeout

      loop do
        status, output = wait_until_succeeds(
          "osctl ct show -H -o state #{id}",
          timeout: cur_timeout
        )

        return self if output.strip == state

        cur_timeout = timeout - (Time.now - t1)

        if cur_timeout <= 0
          raise TimeoutError, "Timeout occurred while waiting for container #{id.inspect} to become #{state}"
        end

        sleep(1)
      end

      self
    end

    # Wait until container's network is operational, including DNS
    # @param ctid [String]
    # @return [Machine]
    def wait_until_container_online(ctid, timeout: @default_timeout)
      wait_until_succeeds(
        "osctl ct exec #{ctid} sh -c 'ping -c 1 check-online.vpsadminos.org || curl --head https://check-online.vpsadminos.org || wget -O - https://check-online.vpsadminos.org || getent hosts check-online.vpsadminos.org'",
        timeout:
      )
      self
    end

    protected

    def service_check_command(name)
      "sv check #{name}"
    end

    def qemu_command(kernel_params: [])
      [
        "#{config.qemu}/bin/qemu-kvm",
        '-name', "os-vm-#{name}",
        '-m', config.memory.to_s,
        '-cpu', 'host',
        '-smp', "cpus=#{config.cpus},cores=#{config.cpu.cores},threads=#{config.cpu.threads},sockets=#{config.cpu.sockets}",
        '--no-reboot',
        '-device', 'ahci,id=ahci'
      ] + config.networks.map(&:qemu_options).flatten + qemu_boot_media_options \
        + qemu_shell_options + [
          '-nographic'
        ] + qemu_boot_options(kernel_params) + qemu_disk_options + qemu_virtiofs_options + config.extra_qemu_options
    end

    def qemu_boot_media_options
      ret = super
      return ret if config.squashfs.nil?

      ret + [
        '-drive', "index=0,id=drive1,file=#{config.squashfs},readonly=on,media=cdrom,format=raw,if=virtio"
      ]
    end
  end
end
