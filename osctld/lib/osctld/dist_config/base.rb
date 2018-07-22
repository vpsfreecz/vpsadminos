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
      writable?(File.join(ct.rootfs, 'etc', 'resolv.conf')) do |path|
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
        'chpasswd',
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        valid_rcs: :all
      )

      return true if ret[:exitstatus] == 0
      log(:warn, ct, "Unable to set password: #{ret[:output]}")
    end

    # Return path to `/bin` or an alternative, where a shell is looked up
    # @return [String]
    def bin_path(_opts)
      '/bin'
    end

    protected
    # Update hostname in /etc/hosts, optionally removing configuration of old
    # hostname.
    # @param old_hostname [String, nil]
    def update_etc_hosts(old_hostname = nil)
      hosts = File.join(ct.rootfs, 'etc', 'hosts')
      return unless writable?(hosts)

      regenerate_file(hosts, 0644) do |new, old|
        old.each_line do |line|
          if (/^127\.0\.0\.1\s/ =~ line || /^::1\s/ =~ line) \
             && !includes_hostname?(line, ct.hostname)

            if old_hostname && includes_hostname?(line, old_hostname)
              new.puts(replace_host(line, old_hostname, ct.hostname))

            else
              new.puts(add_host(line.strip, ct.hostname))
            end

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

    # Add `hostname` to `line` from `/etc/hosts`
    #
    # The hostname is put into the first position.
    #
    # @param line [String]
    # @param hostname [String]
    def add_host(line, hostname)
      return if line !~ /^([^\s]+)(\s+)/

      i = $~.end(2)
      "#{$1}#{$2}#{hostname} #{line[i..-1]}"
    end

    # Remove `hostname` from `line` read from `/etc/hosts`
    #
    # @param line [String]
    # @param hostname [String]
    def replace_host(line, old_hostname, new_hostname)
      line.sub(/(\s)#{Regexp.escape(old_hostname)}(\s|$)/, "\\1#{new_hostname}\\2")
    end

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
