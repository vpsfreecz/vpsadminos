# frozen_string_literal: true

class OsVmSpecMachine < OsVm::Machine
  def qemu_command(kernel_params: [])
    ['qemu-kvm', *qemu_boot_options(kernel_params), *qemu_disk_options, *qemu_virtiofs_options]
  end

  def service_check_command(name)
    "sv check #{name}"
  end
end

module OsvmTestHelpers
  def deep_merge(base, overrides)
    base.merge(overrides) do |_key, old_value, new_value|
      if old_value.is_a?(Hash) && new_value.is_a?(Hash)
        deep_merge(old_value, new_value)
      else
        new_value
      end
    end
  end

  def base_vpsadminos_config_hash
    {
      'spin' => 'vpsadminos',
      'qemu' => '/nix/store/qemu',
      'virtiofsd' => '/nix/store/virtiofsd',
      'bootMode' => 'direct',
      'kernel' => '/boot/kernel',
      'initrd' => '/boot/initrd',
      'kernelParams' => ['panic=1'],
      'toplevel' => '/run/current-system',
      'squashfs' => '/images/system.squashfs',
      'disks' => [],
      'memory' => 512,
      'cpus' => 2,
      'cpu' => {
        'cores' => 1,
        'threads' => 2,
        'sockets' => 1
      },
      'sharedFileSystems' => {
        'extra' => '/srv/extra'
      },
      'networks' => [
        {
          'type' => 'user'
        }
      ],
      'tags' => %w[smoke fast],
      'labels' => {
        'role' => 'test'
      }
    }
  end

  def base_nixos_config_hash
    {
      'spin' => 'nixos',
      'qemu' => '/nix/store/qemu',
      'virtiofsd' => '/nix/store/virtiofsd',
      'bootMode' => 'direct',
      'kernel' => '/boot/kernel',
      'initrd' => '/boot/initrd',
      'kernelParams' => [],
      'toplevel' => '/run/current-system',
      'diskImage' => '/images/root.img',
      'disks' => [],
      'memory' => 512,
      'cpus' => 2,
      'cpu' => {
        'cores' => 1,
        'threads' => 2,
        'sockets' => 1
      },
      'sharedFileSystems' => {},
      'networks' => [
        {
          'type' => 'user'
        }
      ],
      'tags' => [],
      'labels' => {}
    }
  end

  def machine_config_hash(overrides = {}, spin: 'vpsadminos', **extra)
    base =
      case spin
      when 'vpsadminos'
        base_vpsadminos_config_hash
      when 'nixos'
        base_nixos_config_hash
      else
        raise ArgumentError, "unknown spin #{spin.inspect}"
      end

    deep_merge(base, overrides.merge(extra.transform_keys(&:to_s)))
  end

  def build_machine_config(overrides = {}, spin: 'vpsadminos', **extra)
    OsVm::MachineConfig.from_config(machine_config_hash(overrides, spin:, **extra))
  end

  def build_machine(dir:, name: 'test', config: build_machine_config, hash_base: 'spec', interactive_console: false)
    OsVmSpecMachine.new(
      name,
      config,
      File.join(dir, 'tmp'),
      File.join(dir, 'sock'),
      default_timeout: 10,
      hash_base:,
      interactive_console:
    )
  end

  def build_vpsadminos_machine(dir:, name: 'test', config: build_machine_config)
    OsVm::VpsadminosMachine.new(
      name,
      config,
      File.join(dir, 'tmp'),
      File.join(dir, 'sock'),
      default_timeout: 10,
      hash_base: 'spec'
    )
  end

  def build_nixos_machine(dir:, name: 'test', config: build_machine_config({}, spin: 'nixos'))
    OsVm::NixosMachine.new(
      name,
      config,
      File.join(dir, 'tmp'),
      File.join(dir, 'sock'),
      default_timeout: 10,
      hash_base: 'spec'
    )
  end

  def reset_osvm_singletons
    mac_generator = OsVm::MacAddressGenerator.instance
    mac_generator.instance_variable_set(:@registry, Set.new)

    port_reservation = OsVm::PortReservation.instance
    port_reservation.instance_variable_set(:@ports, (10_000..30_000).to_a)
    port_reservation.instance_variable_set(:@allocations, {})
  end
end

RSpec.configure do |config|
  config.include OsvmTestHelpers

  config.before do
    reset_osvm_singletons
  end
end
