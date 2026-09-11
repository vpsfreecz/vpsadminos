module OsVm
  # NixOS-specific machine driver
  class NixosMachine < Machine
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

      if config.root_disk
        ret << '-drive' << "id=diskroot,file=#{root_disk_path},if=none,format=raw"
        ret << '-device' << 'ide-hd,drive=diskroot,bus=ahci.0'
      end

      config.disks.each_with_index do |disk, i|
        idx = config.root_disk ? i + 1 : i
        ret << '-drive' << "id=disk#{idx},file=#{disk_path(disk.device)},if=none,format=raw"
        ret << '-device' << "ide-hd,drive=disk#{idx},bus=ahci.#{idx}"
      end

      ret
    end

    def root_disk_path
      disk_path(config.root_disk.device)
    end
  end
end
