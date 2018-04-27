require 'fileutils'

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

    attr_reader :ct, :distribution, :version

    def initialize(ct)
      @ct = ct
      @distribution = ct.distribution
      @version = ct.version
    end

    # @param opts [Hash] options
    # @option opts [String] original previous hostname
    def set_hostname(opts)
      raise NotImplementedError
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
      path = File.join(ct.rootfs, 'etc', 'resolv.conf')

      File.open("#{path}.new", 'w') do |f|
        ct.dns_resolvers.each { |v| f.puts("nameserver #{v}") }
      end

      File.rename("#{path}.new", path)
    end

    # @param opts [Hash] options
    # @option opts [String] user
    # @option opts [String] password
    def passwd(opts)
      ret = ct_syscmd(
        ct,
        'chpasswd',
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        valid_rcs: :all
      )

      return true if ret[:exitstatus] == 0
      log(:warn, ct, "Unable to set password: #{ret[:output]}")
    end

    protected
    # Update hostname in /etc/hosts, optionally removing configuration of old
    # hostname.
    # @param old_hostname [String, nil]
    def update_etc_hosts(old_hostname = nil)
      regenerate_file(File.join(ct.rootfs, 'etc', 'hosts'), 0644) do |new, old|
        old.each_line do |line|
          if (/^127\.0\.0\.1\s/ =~ line || /^::1\s/ =~ line) \
             && !includes_hostname?(line, ct.hostname)

            if old_hostname && includes_hostname?(line, old_hostname)
              line.sub!(/\s#{Regexp.escape(old_hostname)}/, '')
            end

            new.puts("#{line.rstrip} #{ct.hostname}")

          else
            new.write(line)
          end
        end
      end
    end

    # Check if a line of string contains specific hostname
    # @param line [String]
    # @param hostname [String]
    def includes_hostname?(line, hostname)
      /\s#{Regexp.escape(hostname)}(\s|$)/ =~ line
    end
  end
end
