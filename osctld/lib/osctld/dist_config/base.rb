require 'fileutils'
require 'libosctl'

module OsCtld
  class DistConfig::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File
    include Utils::SwitchUser

    def self.distribution(n = nil)
      if n
        DistConfig.register(n, self)

      else
        n
      end
    end

    attr_reader :ctrc, :ct, :distribution, :version

    # @param ctrc [Container::RunConfiguration]
    def initialize(ctrc)
      @ctrc = ctrc
      @ct = ctrc.ct
      @distribution = ctrc.distribution
      @version = ctrc.version
    end

    # Gracefully stop the container
    # @param opts [Hash]
    # @option opts [:stop, :shutdown, :kill] :mode
    # @option opts [Integer] :timeout
    def stop(opts)
      ContainerControl::Commands::Stop.run!(
        ct,
        opts[:mode],
        timeout: opts[:timeout],
      )
    end

    # Set container hostname
    #
    # Note that the implementation is responsible for calling
    # {#update_etc_hosts} when the hostname is changed.
    #
    # @param opts [Hash] options
    # @option opts [OsCtl::Lib::Hostname] :original previous hostname
    def set_hostname(opts)
      raise NotImplementedError
    end

    # Update hostname in `/etc/hosts`, optionally removing configuration of old
    # hostname.
    #
    # @param opts [Hash] options
    # @param opts [OsCtl::Lib::Hostname, nil] :old_hostname
    def update_etc_hosts(opts = {})
      path = File.join(ctrc.rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)

      if opts[:old_hostname]
        hosts.replace(opts[:old_hostname], ct.hostname)
      else
        hosts.set(ct.hostname)
      end
    end

    # Remove the osctld-generated notice from /etc/hosts
    def unset_etc_hosts(opts = {})
      path = File.join(ctrc.rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)
      hosts.unmanage
    end

    def network(_opts)
      raise NotImplementedError
    end

    # Called when a new network interface is added to a container
    # @param opts [Hash]
    # @option opts [NetInterface::Base] :netif
    def add_netif(opts)

    end

    # Called when a network interface is removed from a container
    # @param opts [Hash]
    # @option opts [NetInterface::Base] :netif
    def remove_netif(opts)

    end

    # Called when an existing network interface is renamed
    # @param opts [Hash]
    # @option opts [NetInterface::Base] :netif
    # @option opts [String] :original_name
    def rename_netif(opts)

    end

    def dns_resolvers(_opts)
      writable?(File.join(ctrc.rootfs, 'etc', 'resolv.conf')) do |path|
        File.open("#{path}.new", 'w') do |f|
          ct.dns_resolvers.each { |v| f.puts("nameserver #{v}") }
        end

        File.rename("#{path}.new", path)
      end
    end

    # @param opts [Hash] options
    # @option opts [String] user
    # @option opts [String] password
    def passwd(opts)
      ret = ct_syscmd(
        ct,
        %w(chpasswd),
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        run: true,
        valid_rcs: :all
      )

      return true if ret.success?
      log(:warn, ct, "Unable to set password: #{ret.output}")
    end

    # Return path to `/bin` or an alternative, where a shell is looked up
    # @return [String]
    def bin_path(_opts)
      '/bin'
    end

    protected
    # Check if the file at `path` si writable by its user
    #
    # If the file doesn't exist, we take it as writable. If a block is given,
    # it is called if `path` is writable.
    #
    # @yieldparam path [String]
    def writable?(path)
      begin
        return if (File.stat(path).mode & 0200) != 0200

      rescue Errno::ENOENT
        # pass
      end

      yield(path) if block_given?
      true
    end
  end
end
