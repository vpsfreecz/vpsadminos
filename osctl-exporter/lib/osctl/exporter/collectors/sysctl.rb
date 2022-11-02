require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::Sysctl < Collectors::Base
    def setup
      @sysctl_kernel_keys_maxkeys = registry.gauge(
        :sysctl_kernel_keys_maxkeys,
        docstring: 'Value of /proc/sys/kernel/keys/maxkeys',
      )
      @sysctl_kernel_keys_maxbytes = registry.gauge(
        :sysctl_kernel_keys_maxbytes,
        docstring: 'Value of /proc/sys/kernel/keys/maxbytes',
      )
      @sysctl_kernel_pty_max = registry.gauge(
        :sysctl_kernel_pty_max,
        docstring: 'Value of /proc/sys/kernel/pty/max',
      )
      @sysctl_kernel_pty_reserve = registry.gauge(
        :sysctl_kernel_pty_reserve,
        docstring: 'Value of /proc/sys/kernel/pty/reserve',
      )
      @sysctl_kernel_pty_nr = registry.gauge(
        :sysctl_kernel_pty_nr,
        docstring: 'Value of /proc/sys/kernel/pty/nr',
      )
    end

    def collect(client)
      @sysctl_kernel_keys_maxkeys.set(File.read('/proc/sys/kernel/keys/maxkeys').strip.to_i)
      @sysctl_kernel_keys_maxbytes.set(File.read('/proc/sys/kernel/keys/maxbytes').strip.to_i)
      @sysctl_kernel_pty_max.set(File.read('/proc/sys/kernel/pty/max').strip.to_i)
      @sysctl_kernel_pty_reserve.set(File.read('/proc/sys/kernel/pty/reserve').strip.to_i)
      @sysctl_kernel_pty_nr.set(File.read('/proc/sys/kernel/pty/nr').strip.to_i)
    end
  end
end
