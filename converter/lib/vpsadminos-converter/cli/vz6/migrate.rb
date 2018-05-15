require 'ruby-progressbar'
require 'tempfile'
require 'vpsadminos-converter/cli/vz6/base'

module VpsAdminOS::Converter
  class Cli::Vz6::Migrate < Cli::Vz6::Base
    def stage
      require_args!('ctid', 'dst')

      vz_ct, target_ct = convert_ct(args[0])
      migrator = Vz6::Migrator.create(vz_ct, target_ct, {
        dst: args[1],
        port: opts[:port],
        zfs: opts[:zfs],
        zfs_dataset: opts['zfs-dataset'],
        zfs_subdir: opts['zfs-subdir'],
        zfs_compressed_send: opts['zfs-compressed-send'],
      })
      migrator.stage

      print_convert_status(vz_ct)
      puts
      puts 'Migration stage successful'
      puts 'Continue with vz6 migrate sync, or abort with vz6 migrate cancel'
    end

    def sync
      require_args!('ctid')
      migrator = Vz6::Migrator.load(args[0])
      fail 'invalid migration sequence' unless migrator.can_proceed?(:sync)

      migrator.sync(&method(:progress))

    ensure
      progressbar_done
    end

    def transfer
      require_args!('ctid')
      migrator = Vz6::Migrator.load(args[0])
      fail 'invalid migration sequence' unless migrator.can_proceed?(:transfer)

      migrator.transfer(&method(:progress))

    ensure
      progressbar_done
    end

    def cleanup
      require_args!('ctid')
      migrator = Vz6::Migrator.load(args[0])
      fail 'invalid migration sequence' unless migrator.can_proceed?(:cleanup)

      migrator.cleanup(opts)
    end

    def cancel
      require_args!('ctid')
      migrator = Vz6::Migrator.load(args[0])
      fail 'invalid migration sequence' unless migrator.can_proceed?(:cancel)

      migrator.cancel(opts)
    end

    def now
      require_args!('ctid', 'dst')

      puts '* Staging migration'
      stage

      unless opts[:proceed]
        STDOUT.write('Do you wish to continue? [y/N]: ')
        STDOUT.flush

        if STDIN.readline.strip.downcase != 'y'
          puts '* Cancelling migration'
          cancel
          return
        end
      end

      puts '* Performing initial synchronization'
      sync

      puts '* Transfering container to the destination'
      transfer

      puts '* Cleaning up'
      cleanup
    end

    protected
    def progress(type, value)
      case type
      when :step
        progressbar_done
        puts "> #{value}"

      when :transfer
        progressbar_update(value[0], value[1])
      end
    end

    def progressbar_update(total, current)
      @pb ||= ProgressBar.create(
        title: 'Copying',
        total: nil,
        format: "%E %t #{(total / 1024.0).round(2)} GB: [%B] %p%% %r MB/s",
        throttle_rate: 0.2,
        starting_at: 0,
        autofinish: false,
        output: STDOUT,
      )
      @pb.total = current > total ? current : total
      @pb.progress = current
    end

    def progressbar_done
      return unless @pb
      @pb.finish
      @pb = nil
    end
  end
end
