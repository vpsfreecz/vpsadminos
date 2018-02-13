require 'gli'
require_relative 'vz6'

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

          c.desc "Use when the container's private area is on a ZFS dataset"
          c.switch :zfs

          c.desc "Dataset with the container's private area"
          c.flag 'zfs-dataset'

          c.desc "Directory in the container's dataset with the rootfs"
          c.flag 'zfs-subdir'

          c.desc 'Enable ZFS compressed send (zfs send -c)'
          c.switch 'zfs-compressed-send', negatable: false

          c.desc 'Assumes --zfs --zfs-dataset vz/private/%{veid} --zfs-subdir private'
          c.switch :vpsadmin, negatable: false

          c.action &Command.run(Vz6, :export)
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
  end
end
