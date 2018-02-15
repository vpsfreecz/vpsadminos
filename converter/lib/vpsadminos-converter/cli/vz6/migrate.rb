require 'ruby-progressbar'
require 'tempfile'

module VpsAdminOS::Converter
  class Cli::Vz6::Migrate < Cli::Vz6::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include OsCtl::Lib::Utils::Migration

    attr_reader :state

    def stage
      require_args!('ctid', 'dst')

      begin
        load_state

      rescue Errno::ENOENT
        # ok

      else
        fail "migration of CT #{state.ctid} has already been started"
      end

      vz_ct, target_ct = convert_ct(args[0])

      # TODO: perform checks for later stages, if the migration can succeed or not

      f = Tempfile.open("ct-#{target_ct.id}-skel")
      export_skel(target_ct, f)
      f.seek(0)

      m_opts = {
        port: opts[:port] || 22,
        dst: args[1],
      }

      ssh = migrate_ssh_cmd(
        nil,
        m_opts,
        ['receive', 'skel']
      )

      IO.popen("exec #{ssh.join(' ')}", 'r+') do |io|
        io.write(f.readpartial(16*1024)) until f.eof?
      end

      f.close
      f.unlink

      fail 'stage failed' if $?.exitstatus != 0

      Cli::Vz6::State.create(vz_ct, target_ct, m_opts, opts)

      print_convert_status(vz_ct)
      puts
      puts 'Migration stage successful'
      puts 'Continue with vz6 migrate sync, or abort with vz6 migrate cancel'
    end

    def sync
      require_args!('ctid')
      load_state
      fail 'invalid migration sequence' unless state.can_proceed?(:sync)

      if state.cli_opts[:zfs]
        if state.cli_opts['zfs-subdir'] != 'private'
          fail 'nothing but zfs-subdir=private not implemented'
        end

        snap = "converter-migrate-base-#{Time.now.to_i}"
        zfs(:snapshot, '-r', "#{state.target_ct.dataset}@#{snap}")

        state.set_step(:sync)
        state.snapshots << snap
        state.save

        state.target_ct.datasets.each do |ds|
          send_dataset(state.target_ct, ds, snap)
        end

      else
        fail 'non-ZFS not implemented yet'
      end
    end

    def transfer
      require_args!('ctid')
      load_state
      fail 'invalid migration sequence' unless state.can_proceed?(:transfer)

      if state.cli_opts[:zfs]
        if state.cli_opts['zfs-subdir'] != 'private'
          fail 'nothing but zfs-subdir=private not implemented'
        end

        # Stop the container
        running = state.vz_ct.running?
        syscmd("vzctl stop #{state.vz_ct.ctid}")

        # Final sync
        snap = "converter-migrate-incr-#{Time.now.to_i}"
        zfs(:snapshot, '-r', "#{state.target_ct.dataset}@#{snap}")

        state.snapshots << snap
        state.save

        state.target_ct.datasets.each do |ds|
          send_dataset_incr(state.target_ct, ds, snap, state.snapshots[-2])
        end

        # Transfer to dst
        puts 'Starting on the target node'
        ret = system(
          *migrate_ssh_cmd(
            nil,
            state.m_opts,
            ['receive', 'transfer', state.target_ct.id] + (running ? ['start'] : [])
          )
        )

        fail 'transfer failed' if ret.nil? || $?.exitstatus != 0

        state.set_step(:transfer)
        state.save

      else
        fail 'non-ZFS not implemented yet'
      end
    end

    def cleanup
      require_args!('ctid')
      load_state
      fail 'invalid migration sequence' unless state.can_proceed?(:cleanup)

      if state.cli_opts[:zfs]
        state.target_ct.datasets.each do |ds|
          state.snapshots.each do |snap|
            zfs(:destroy, nil, "#{ds}@#{snap}")
          end
        end

        if state.cli_opts[:delete]
          syscmd("vzctl destroy #{state.vz_ct.ctid}")
          zfs(:destroy, '-r', state.target_ct.dataset)
        end

      else
        fail 'non-ZFS not implemented yet'
      end

      state.destroy
    end

    def cancel
      require_args!('ctid')
      load_state
      fail 'invalid migration sequence' unless state.can_proceed?(:cancel)

      ret = system(
        *migrate_ssh_cmd(
          nil,
          state.m_opts,
          ['receive', 'cancel', state.target_ct.id]
        )
      )

      if ret.nil? || $?.exitstatus != 0 && !opts[:force]
        fail 'cancel failed'
      end

      state.destroy
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
    def export_skel(ct, io)
      exporter = Exporter::Base.new(ct, io)
      exporter.dump_metadata('skel')
      exporter.dump_configs
      exporter.close
    end

    def load_state
      @state = Cli::Vz6::State.load(args[0])
    end

    def send_dataset(ct, ds, base_snap)
      puts "Syncing #{ds.relative_name}"

      snaps = ds.snapshots
      send_snapshot(ct, ds, base_snap, snaps.first.snapshot)
      send_snapshot(
        ct,
        ds,
        base_snap,
        snaps.last.snapshot,
        snaps.first.snapshot
      ) if snaps.count > 1
    end

    def send_dataset_incr(ct, ds, incr_snap, from_snap)
      puts "Syncing #{ds.relative_name}"
      send_snapshot(ct, ds, incr_snap, incr_snap, from_snap)
    end

    def send_snapshot(ct, ds, base_snap, snap, from_snap = nil)
      stream = OsCtl::Lib::Zfs::Stream.new(
        ds,
        snap,
        from_snap,
        compressed: state.cli_opts['zfs-compressed-send']
      )
      stream.progress do |total, changed|
        progressbar_update(stream.size, total)
      end

      r, send = stream.spawn
      pid = Process.spawn(
        *migrate_ssh_cmd(
          nil,
          state.m_opts,
          [
            'receive', from_snap ? 'incremental' : 'base',
            ct.id, ds.relative_name
          ] + (base_snap == snap ? [base_snap] : [])
        ),
        in: r
      )
      r.close
      stream.monitor(send)

      _, status = Process.wait2(pid)
      progressbar_done

      fail 'sync failed' if status.exitstatus != 0
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
