require 'gli'
require 'vpsadminos-converter/vz6'

module VpsAdminOS::Converter::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Convert OpenVZ containers into vpsAdminOS'
      version VpsAdminOS::Converter::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict

      desc 'Log file'
      flag 'log-file'

      desc 'Convert containers from OpenVZ Legacy'
      command :vz6 do |vz|
        vz.desc 'Export OpenVZ container into vpsAdminOS-compatible archive'
        vz.arg_name '<ctid> <file>'
        vz.command :export do |c|
          c.desc 'Stop the container during the export'
          c.switch :consistent, default_value: true

          c.desc 'Compression'
          c.flag %i(c compression), must_match: %w(auto off gzip),
                  default_value: 'gzip'

          vz6_opts(c)

          c.action &Command.run(Vz6::Export, :export)
        end

        vz.desc 'Migrate OpenVZ container onto vpsAdminOS node'
        vz.command :migrate do |m|
          m.desc 'Step 1., copy configs to target node'
          m.arg_name '<id> <dst>'
          m.command :stage do |c|
            c.desc 'SSH port'
            c.flag %i(p port), type: Integer

            vz6_opts(c)

            c.action &Command.run(Vz6::Migrate, :stage)
          end

          m.desc 'Step 2., do an initial copy of container rootfs'
          m.arg_name '<id>'
          m.command :sync do |c|
            c.action &Command.run(Vz6::Migrate, :sync)
          end

          m.desc 'Step 3., transfer the container to target node'
          m.arg_name '<id>'
          m.command :transfer do |c|
            c.action &Command.run(Vz6::Migrate, :transfer)
          end

          m.desc 'Step 4., cleanup the container on the source node'
          m.arg_name '<id>'
          m.command :cleanup do |c|
            c.desc 'Delete the container'
            c.switch %i(d delete), default_value: false

            c.action &Command.run(Vz6::Migrate, :cleanup)
          end

          m.desc 'Cancel ongoing migration in mid-step'
          m.arg_name '<id>'
          m.command :cancel do |c|
            c.desc 'Cancel the migration on the local node, even if remote fails'
            c.switch %i(f force), negatable: false

            c.action &Command.run(Vz6::Migrate, :cancel)
          end

          m.desc 'Migrate container at once (equals to steps 1-4 in succession)'
          m.arg_name '<id> <dst>'
          m.command :now do |c|
            c.desc 'SSH port'
            c.flag %i(p port), type: Integer

            c.desc 'Delete the container after migration'
            c.switch %i(d delete), default_value: false

            c.desc 'Proceed with the migration or ask after successful staging'
            c.switch %i(y proceed)

            vz6_opts(c)

            c.action &Command.run(Vz6::Migrate, :now)
          end
        end
      end

      desc 'Read man page'
      command :man do |c|
        c.action do
          manpath = File.realpath(File.join(
            File.dirname(__FILE__),
            '..', '..', '..', 'man'
          ))
          system("man -M #{manpath} vpsadminos-convert")
        end
      end
    end

    protected
    def vz6_opts(c)
      c.desc "Use when the container's private area is on a ZFS dataset"
      c.switch :zfs

      c.desc "Dataset with the container's private area"
      c.flag 'zfs-dataset'

      c.desc "Directory in the container's dataset with the rootfs"
      c.flag 'zfs-subdir'

      c.desc 'Enable ZFS compressed send (zfs send -c)'
      c.switch 'zfs-compressed-send', negatable: false

      c.desc 'Network interface type'
      c.flag 'netif-type', must_match: %w(bridge routed), default_value: 'bridge'

      c.desc 'Network interface name within the container'
      c.flag 'netif-name', default_value: 'eth0'

      c.desc 'Network interface hwaddr (MAC)'
      c.flag 'netif-hwaddr'

      c.desc 'Bridge name (for bridged network interface)'
      c.flag 'bridge-link', default_value: 'lxcbr0'

      c.desc 'Route via network (for routed network interface)'
      c.flag 'route-via', multiple: true

      c.desc 'Interconnecting address for the host (on routed network interface)'
      c.flag 'route-host-addr', multiple: true

      c.desc 'Interconnecting address for the container (on routed network interface)'
      c.flag 'route-ct-addr', multiple: true

      c.desc 'Overrides options to conform to vpsAdmin settings, see the manual'
      c.switch :vpsadmin, negatable: false
    end
  end
end
