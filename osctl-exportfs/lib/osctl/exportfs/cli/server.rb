require 'osctl/exportfs/cli/command'
require 'libosctl'

module OsCtl::ExportFS::Cli
  class Server < Command
    FIELDS = %i[server state netif address].freeze
    DEFAULT_NFSD_SWITCHES = {
      'nfsd-tcp' => true,
      'nfsd-udp' => false,
      'nfsd-syslog' => false
    }.freeze

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS
      sort = opts[:sort] && opts[:sort].split(',').map(&:to_sym)

      if sort
        sort.each do |v|
          cols << v unless cols.include?(v)
        end
      end

      fmt_opts = {
        layout: :columns,
        cols:,
        sort:
      }

      fmt_opts[:header] = false if opts['hide-header']

      OsCtl::Lib::Cli::OutputFormatter.print(
        OsCtl::ExportFS::Operations::Server::List.run.map do |s|
          cfg = s.open_config

          {
            server: s.name,
            state: s.running? ? 'running' : 'stopped',
            netif: cfg.netif,
            address: cfg.address
          }
        end,
        **fmt_opts
      )
    end

    def create
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Create.run(
        args[0],
        options: server_options(preserve_defaults: true)
      )
    end

    def delete
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Delete.run(args[0])
    end

    def set
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Configure.run(
        OsCtl::ExportFS::Server.new(args[0]),
        server_options(preserve_defaults: false)
      )
    end

    def start
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.start
    end

    def stop
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.stop
    end

    def restart
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.restart
    end

    def spawn
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Spawn.run(args[0])
    end

    def attach
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Attach.run(args[0])
    end

    protected

    def server_options(preserve_defaults:)
      {
        address: opts['address'],
        netif: opts['netif'],
        nfsd: {
          port: opts['nfsd-port'],
          nproc: opts['nfsd-nproc'],
          tcp: nfsd_switch_value('nfsd-tcp', preserve_defaults:),
          udp: nfsd_switch_value('nfsd-udp', preserve_defaults:),
          versions: parse_nfs_versions(opts['nfs-versions']),
          syslog: nfsd_switch_value('nfsd-syslog', preserve_defaults:)
        },
        mountd_port: opts['mountd-port'],
        lockd_port: opts['lockd-port'],
        statd_port: opts['statd-port']
      }
    end

    def nfsd_switch_value(name, preserve_defaults:)
      if preserve_defaults
        return opts[name] if option_specified?(name)

        return DEFAULT_NFSD_SWITCHES.fetch(name)
      end

      return nil unless option_specified?(name)

      opts[name]
    end

    def option_specified?(name)
      ARGV.include?("--#{name}") || ARGV.include?("--no-#{name}")
    end

    def parse_nfs_versions(opt)
      return if opt.nil?

      ret = opt.split(',')
      choices = OsCtl::ExportFS::Config::Nfsd::VERSIONS

      ret.each do |v|
        unless choices.include?(v)
          raise "invalid NFS version '#{v}', possible values are: #{choices.join(', ')}"
        end
      end

      ret
    end
  end
end
