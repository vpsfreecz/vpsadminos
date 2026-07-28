require 'osctld/dist_config/distributions/base'
require 'osctld/dist_config/nixos_resolver_file'
require 'osctld/dist_config/resolver'

module OsCtld
  class DistConfig::Distributions::NixOS < DistConfig::Distributions::Base
    distribution :nixos

    DNS_UPDATE = '/run/current-system/sw/bin/vpsadminos-dns-update'.freeze

    class Configurator < DistConfig::Configurator
      def network(netifs)
        tpl_base = 'dist_config/network/nixos'

        %w[add del].each do |operation|
          cmds = netifs.map do |netif|
            OsCtld::ErbTemplate.render(
              File.join(tpl_base, netif.type.to_s),
              { netif:, op: operation }
            )
          end

          writable?(File.join(rootfs, "ifcfg.#{operation}")) do |path|
            File.write(path, cmds.join("\n"))
          end
        end
      end

      protected

      def network_class
        nil
      end
    end

    def post_mount(opts)
      super
      resolvers = ct.dns_resolvers
      resolvers_unset = resolvers.nil? || (resolvers.is_a?(Array) && resolvers.empty?)
      return if ct.impermanence.nil? && resolvers_unset

      ContainerControl::Commands::WithMountns.run!(
        ct,
        ns_pid: opts[:ns_pid],
        mnt_ns: opts[:mnt_ns],
        root_dir: opts[:root_dir],
        block: proc do
          configure_impermanence_init

          unless resolvers_unset
            DistConfig::NixOSResolverFile.new.write(
              DistConfig::Resolver.render(resolvers)
            )
          end

          true
        end
      )
    end

    protected

    def configure_impermanence_init
      return unless ct.impermanence

      # If /sbin/init already exists, it means we're *not* in impermanence mode
      # right now, even if it is enabled. While in impermanence mode, we start
      # with an empty dataset. Existing /sbin/init suggests custom
      # `osctl ct boot` is active.
      return if File.exist?('/sbin/init')

      begin
        Dir.mkdir('/sbin')
      rescue Errno::EEXIST
        # pass
      end

      File.symlink('/nix/var/nix/profiles/system/init', '/sbin/init')
    end

    public

    def set_hostname(_opts = {})
      log(:warn, 'Unable to apply hostname to NixOS container')
    end

    def update_etc_hosts(_opts = {})
      # not supported
    end

    def unset_etc_hosts(_opts = {})
      # not supported
    end

    def dns_resolvers(_opts = {})
      return unless ct.running?

      ct_syscmd(
        ct,
        [DNS_UPDATE],
        stdin: DistConfig::Resolver.render(ct.dns_resolvers)
      )
    end

    def unset_dns_resolvers(_opts = {})
      return unless ct.running?

      ct_syscmd(ct, [DNS_UPDATE, '--clear'])
    end

    def bin_path(_opts)
      raise "#{ct.ident} not running" unless ct.running?

      ContainerControl::Commands::WithMountns.run!(
        ct,
        ns_pid: ct.init_pid,
        block: proc do
          File.realpath('/nix/var/nix/profiles/system/sw/bin')
        rescue Errno::ENOENT
          '/bin'
        end
      )
    end
  end
end
