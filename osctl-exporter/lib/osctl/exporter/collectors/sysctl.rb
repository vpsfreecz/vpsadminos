require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::Sysctl < Collectors::Base
    def setup
      @kernel_keys_maxkeys = registry.gauge(
        :sysctl_kernel_keys_maxkeys,
        docstring: 'Value of /proc/sys/kernel/keys/maxkeys'
      )
      @kernel_keys_maxbytes = registry.gauge(
        :sysctl_kernel_keys_maxbytes,
        docstring: 'Value of /proc/sys/kernel/keys/maxbytes'
      )
      @kernel_pty_max = registry.gauge(
        :sysctl_kernel_pty_max,
        docstring: 'Value of /proc/sys/kernel/pty/max'
      )
      @kernel_pty_reserve = registry.gauge(
        :sysctl_kernel_pty_reserve,
        docstring: 'Value of /proc/sys/kernel/pty/reserve'
      )
      @kernel_pty_nr = registry.gauge(
        :sysctl_kernel_pty_nr,
        docstring: 'Value of /proc/sys/kernel/pty/nr'
      )
    end

    def collect(_client)
      @kernel_keys_maxkeys.set(File.read('/proc/sys/kernel/keys/maxkeys').strip.to_i)
      @kernel_keys_maxbytes.set(File.read('/proc/sys/kernel/keys/maxbytes').strip.to_i)
      @kernel_pty_max.set(File.read('/proc/sys/kernel/pty/max').strip.to_i)
      @kernel_pty_reserve.set(File.read('/proc/sys/kernel/pty/reserve').strip.to_i)
      @kernel_pty_nr.set(File.read('/proc/sys/kernel/pty/nr').strip.to_i)
    end
  end
end
