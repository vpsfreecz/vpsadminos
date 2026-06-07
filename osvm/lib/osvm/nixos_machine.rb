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
      [
        "#{config.qemu}/bin/qemu-kvm",
        '-name', "os-vm-#{name}",
        '-m', config.memory.to_s,
        '-cpu', 'host',
        '-smp', "cpus=#{config.cpus},cores=#{config.cpu.cores},threads=#{config.cpu.threads},sockets=#{config.cpu.sockets}",
        '--no-reboot',
        '-device', 'ahci,id=ahci'
      ] + config.networks.map(&:qemu_options).flatten + qemu_boot_media_options + qemu_shell_options + [
        '-nographic'
      ] + qemu_boot_options(kernel_params) + qemu_disk_options + qemu_virtiofs_options + config.extra_qemu_options
    end

    def qemu_disk_options
      ret = []

      if config.disk_image
        ret << '-drive' << "id=diskroot,file=#{root_disk_path},if=none,format=raw"
        ret << '-device' << 'ide-hd,drive=diskroot,bus=ahci.0'
      end

      config.disks.each_with_index do |disk, i|
        idx = config.disk_image ? i + 1 : i
        ret << '-drive' << "id=disk#{idx},file=#{disk_path(disk.device)},if=none,format=raw"
        ret << '-device' << "ide-hd,drive=disk#{idx},bus=ahci.#{idx}"
      end

      ret
    end

    def prepare_disks
      super

      return unless config.disk_image

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
