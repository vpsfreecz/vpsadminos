require 'osctld/dist_config/network/base'

module OsCtld
  # ifupdown configures network using /etc/network/interfaces
  class DistConfig::Network::Ifupdown < DistConfig::Network::Base
    def usable?
      File.exist?(File.join(rootfs, 'etc/network/interfaces'))
    end

    def configure(netifs)
      base = File.join(rootfs, 'etc', 'network')
      config = File.join(base, 'interfaces')
      return unless writable?(config)

      vars = {
        netifs:,
        head: nil,
        interfacesd: Dir.exist?(File.join(base, 'interfaces.d')),
        tail: nil
      }

      %i[head tail].each do |v|
        f = File.join(base, "interfaces.#{v}")

        begin
          # Ignore large files
          if File.size(f) > 10 * 1024 * 1024
            log(:warn, "/etc/network/interfaces.#{v} found, but is too large")
            next
          end

          vars[v] = File.read(f)
        rescue Errno::ENOENT
          next
        end
      end

      OsCtld::ErbTemplate.render_to_if_changed(
        'dist_config/network/ifupdown/interfaces',
        vars,
        config
      )
    end
  end
end
