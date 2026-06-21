require 'libosctl'
require 'json'
require 'osctld/dist_config/helpers/common'

module OsCtld
  # Base class for per-distribution configurators
  #
  # Configurators are used to manipulate the container's root filesystem. It is
  # called from a forked process with a container-specific mount namespace, but
  # retaining access to all osctld memory.
  class DistConfig::Configurator
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::File
    include DistConfig::Helpers::Common

    # @return [String]
    attr_reader :ctid

    # @return [String]
    attr_reader :rootfs

    # @return [String]
    attr_reader :distribution

    # @return [String]
    attr_reader :version

    # @param ctid [String]
    # @param rootfs [String]
    # @param distribution [String]
    # @param version [String]
    def initialize(ctid, rootfs, distribution, version)
      @ctid = ctid
      @rootfs = rootfs
      @distribution = distribution
      @version = version
      @network_backend = instantiate_network_class
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def set_hostname(new_hostname, old_hostname: nil)
      raise NotImplementedError
    end

    # @param new_hostname [OsCtl::Lib::Hostname]
    # @param old_hostname [OsCtl::Lib::Hostname, nil]
    def update_etc_hosts(new_hostname, old_hostname: nil)
      path = File.join(rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)

      if old_hostname
        hosts.replace(old_hostname, new_hostname)
      else
        hosts.set(new_hostname)
      end
    end

    def unset_etc_hosts
      path = File.join(rootfs, 'etc', 'hosts')
      return unless writable?(path)

      hosts = EtcHosts.new(path)
      hosts.unmanage
    end

    # Configure networking
    # @param netifs [Array<NetInterface::Base>]
    def network(netifs)
      network_backend && network_backend.configure(netifs)
    end

    # Called when a new network interface is added to a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def add_netif(netifs, netif)
      network_backend && network_backend.add_netif(netifs, netif)
    end

    # Called when a network interface is removed from a container
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    def remove_netif(netifs, netif)
      network_backend && network_backend.remove_netif(netifs, netif)
    end

    # Called when an existing network interface is renamed
    # @param netifs [Array<NetInterface::Base>]
    # @param netif [NetInterface::Base]
    # @param old_name [String]
    def rename_netif(netifs, netif, old_name)
      network_backend && network_backend.rename_netif(netifs, netif, old_name)
    end

    # Configure DNS resolvers
    # @param resolvers [Array<String>]
    def dns_resolvers(resolvers)
      writable?(File.join(rootfs, 'etc', 'resolv.conf')) do |path|
        File.open("#{path}.new", 'w') do |f|
          resolvers.each { |v| f.puts("nameserver #{v}") }
          f.puts('options edns0')
        end

        File.rename("#{path}.new", path)
      end

      network_manager_dns_none
    end

    def unset_dns_resolvers
      network_manager_dns_default
    end

    def container_runtime_defaults
      return unless container_runtime_defaults_distribution?

      docker_cgroupfs_default
      podman_cgroupfs_default
    end

    def log_type
      ctid
    end

    RUNTIME_DEFAULT_DISTRIBUTIONS = %w[
      almalinux
      arch
      centos
      debian
      fedora
      rocky
      ubuntu
    ].freeze

    def self.container_runtime_defaults_distribution?(distribution)
      RUNTIME_DEFAULT_DISTRIBUTIONS.include?(distribution)
    end

    protected

    DOCKER_CGROUP_DRIVER_OPT = 'native.cgroupdriver=cgroupfs'.freeze
    DOCKER_CGROUPNS_MODE_KEY = 'default-cgroupns-mode'.freeze
    DOCKER_CGROUPNS_MODE = 'host'.freeze
    PODMAN_CGROUP_MANAGER_KEY = /\A\s*["']?cgroup_manager["']?\s*=/
    PODMAN_DOTTED_CGROUP_MANAGER_KEY =
      /\A\s*["']?engine["']?\s*\.\s*["']?cgroup_manager["']?\s*=/
    PODMAN_CGROUPFS_DROPIN = '10-vpsadminos-cgroupfs.conf'.freeze
    PODMAN_CGROUPFS_CONFIG = "[engine]\ncgroup_manager = \"cgroupfs\"\n".freeze
    NETWORK_MANAGER_DNS_LEGACY_CONFIG = "[main]\ndns=none\n".freeze
    NETWORK_MANAGER_DNS_CONFIG = <<~CONFIG.freeze
      # Generated and managed by osctld. Do not edit.
      [main]
      dns=none
    CONFIG

    def container_runtime_defaults_distribution?
      self.class.container_runtime_defaults_distribution?(distribution)
    end

    def docker_cgroupfs_default
      path = File.join(rootfs, 'etc', 'docker', 'daemon.json')
      return unless writable?(path)

      config = read_docker_daemon_config(path)
      return if config.nil?

      exec_opts = Array(config.fetch('exec-opts', []))
      cgroup_driver = exec_opts.find { |opt| opt.start_with?('native.cgroupdriver=') }

      unless cgroup_driver
        config['exec-opts'] = exec_opts + [DOCKER_CGROUP_DRIVER_OPT]
        cgroup_driver = DOCKER_CGROUP_DRIVER_OPT
      end

      config[DOCKER_CGROUPNS_MODE_KEY] ||= DOCKER_CGROUPNS_MODE if cgroup_driver == DOCKER_CGROUP_DRIVER_OPT
      write_json_config(path, config)
    end

    def read_docker_daemon_config(path)
      if File.exist?(path)
        JSON.parse(File.read(path))
      else
        {}
      end
    rescue JSON::ParserError => e
      log(:warn, "Unable to parse #{path}: #{e.message}")
      nil
    end

    def write_json_config(path, config)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(config)}\n")
    end

    def podman_cgroupfs_default
      path = File.join(
        rootfs,
        'etc',
        'containers',
        'containers.conf.d',
        PODMAN_CGROUPFS_DROPIN
      )

      if podman_cgroup_manager_configured?(generated_path: path)
        if File.file?(path) && File.binread(path) == PODMAN_CGROUPFS_CONFIG
          File.unlink(path)
        end
        return
      end

      # The reserved path is either our already-correct seed or an unknown
      # administrator/image file which must not be overwritten.
      return if File.exist?(path)
      return unless writable?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, PODMAN_CGROUPFS_CONFIG)
    end

    def podman_cgroup_manager_configured?(generated_path:)
      config_dir = File.join(rootfs, 'etc', 'containers')
      paths = [File.join(config_dir, 'containers.conf')]
      paths.concat(Dir.glob(File.join(config_dir, 'containers.conf.d', '*.conf')))

      paths.any? do |path|
        path != generated_path && File.file?(path) && podman_config_sets_cgroup_manager?(path)
      end
    end

    def podman_config_sets_cgroup_manager?(path)
      section = nil

      File.foreach(path) do |line|
        if (match = line.match(/\A\s*\[\s*([^\]]+)\s*\]\s*(?:#.*)?\z/))
          section = match[1].strip.gsub(/\A["']|["']\z/, '')
          next
        end

        return true if section == 'engine' && line.match?(PODMAN_CGROUP_MANAGER_KEY)
        return true if section.nil? && line.match?(PODMAN_DOTTED_CGROUP_MANAGER_KEY)
      end

      false
    rescue SystemCallError => e
      log(:warn, "Unable to inspect #{path}: #{e.message}")
      true
    end

    def network_manager_dns_none
      path = File.join(rootfs, 'etc', 'NetworkManager', 'conf.d', '10-osctl-dns.conf')
      return unless Dir.exist?(File.dirname(path))

      state = network_manager_dns_config_state(path)
      return if %i[current custom].include?(state)
      return unless writable?(path)

      File.write(path, NETWORK_MANAGER_DNS_CONFIG)
    end

    def network_manager_dns_default
      path = File.join(rootfs, 'etc', 'NetworkManager', 'conf.d', '10-osctl-dns.conf')
      return unless %i[current legacy].include?(network_manager_dns_config_state(path))
      return unless writable?(path)

      File.unlink(path)
    end

    def network_manager_dns_config_state(path)
      stat = File.lstat(path)
      return :custom unless stat.file?

      content = File.binread(path)
      return :current if content == NETWORK_MANAGER_DNS_CONFIG
      return :legacy if content == NETWORK_MANAGER_DNS_LEGACY_CONFIG

      :custom
    rescue Errno::ENOENT
      :absent
    rescue SystemCallError => e
      log(:warn, "Unable to inspect #{path}: #{e.message}")
      :custom
    end

    # @return [DistConfig::Network::Base, nil]
    attr_reader :network_backend

    # Return a class which is used for network configuration
    #
    # The class should be a subclass of {DistConfig::Network::Base}.
    #
    # If an array of classes is returned, they are instantiated and the first
    # class for which {DistConfig::Network::Base#usable?} returns true is used.
    # An exception is raised if no class is found to be usable.
    #
    # If `nil` is returned, you are expected to implement {#network} and other
    # methods for network configuration yourself.
    #
    # @return [Class, Array<Class>, nil]
    def network_class
      raise NotImplementedError
    end

    # @return [DistConfig::Network::Base, nil]
    def instantiate_network_class
      klass = network_class

      if klass.nil?
        log(:debug, 'Using distribution-specific network configuration')
        nil

      elsif klass.is_a?(Array)
        klass.each do |k|
          inst = k.new(self)

          if inst.usable?
            log(:debug, "Using #{k} for network configuration")
            return inst
          end
        end

        log(:warn, "No network class usable for #{self.class}")
        nil

      else
        log(:debug, "Using #{network_class} for network configuration")
        network_class.new(self)
      end
    end
  end
end
