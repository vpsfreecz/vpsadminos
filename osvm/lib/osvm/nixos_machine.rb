module OsVm
  # NixOS-specific machine driver
  class NixosMachine < Machine
    def destroy_disks
      FileUtils.rm_f(root_disk_path)
      super
    end

    protected

    def service_check_command(name)
      "systemctl is-active --quiet #{name}"
    end

    def poweroff_command
      'poweroff'
    end

    def qemu_command(kernel_params: [])
      all_kernel_params = base_kernel_params(kernel_params)

      [
        "#{config.qemu}/bin/qemu-kvm",
        '-name', "os-vm-#{name}",
        '-m', config.memory.to_s,
        '-cpu', 'host',
        '-smp', "cpus=#{config.cpus},cores=#{config.cpu.cores},threads=#{config.cpu.threads},sockets=#{config.cpu.sockets}",
        '--no-reboot',
        '-device', 'ahci,id=ahci'
      ] + config.networks.map(&:qemu_options).flatten + [
        '-chardev', "socket,id=shell,path=#{shell_socket_path}",
        '-device', 'virtio-serial',
        '-device', 'virtconsole,chardev=shell',
        '-kernel', config.kernel,
        '-initrd', config.initrd,
        '-append', all_kernel_params.join(' '),
        '-nographic'
      ] + qemu_disk_options + qemu_virtiofs_options + config.extra_qemu_options
    end

    def qemu_disk_options
      ret = []

      ret << '-drive' << "id=diskroot,file=#{root_disk_path},if=none,format=raw"
      ret << '-device' << 'ide-hd,drive=diskroot,bus=ahci.0'

      config.disks.each_with_index do |disk, i|
        idx = i + 1
        ret << '-drive' << "id=disk#{idx},file=#{disk_path(disk.device)},if=none,format=raw"
        ret << '-device' << "ide-hd,drive=disk#{idx},bus=ahci.#{idx}"
      end

      ret
    end

    def prepare_disks
      super

      # Copy the NixOS disk image into a writable location for the VM.
      # Always refresh to ensure a clean state between runs.
      FileUtils.rm_f(root_disk_path)
      FileUtils.cp(config.disk_image, root_disk_path)
      begin
        File.chmod(0o644, root_disk_path)
      rescue StandardError
        # ignore chmod failures
      end
    end

    def root_disk_path
      @root_disk_path ||= disk_path("#{name}-root.img")
    end
  end
end
