require 'json'
require 'vpsadminos-converter/vz6/migrator/base'

module VpsAdminOS::Converter
  class Vz6::Migrator::Simfs < Vz6::Migrator::Base
    def sync(&block)
      self.progress_handler = block
      do_sync
      state.set_step(:sync)
      state.save
    end

    def transfer(&block)
      self.progress_handler = block

      # Stop the container
      running = vz_ct.running?
      syscmd("vzctl stop #{vz_ct.ctid}")

      # Second sync
      do_sync

      # Transfer to dst
      transfer_container(running)
    end

    def cleanup(cmd_opts)
      syscmd("vzctl destroy #{vz_ct.ctid}") if cmd_opts[:delete]
      state.destroy
    end

    def cancel(cmd_opts)
      cancel_remote(cmd_opts[:force])
      state.destroy
    end

    protected
    def src_rootfs
      target_ct.rootfs
    end

    def dst_rootfs
      @dst_rootfs ||= JSON.parse(
        root_sshcmd("osctl -j ct show #{target_ct.id}")[:output].strip
      )['rootfs']
    end

    def do_sync
      progress(:step, 'Synchronizing /')
      rsync("#{src_rootfs}/", "#{dst_rootfs}/", valid_rcs: [23, 24])
    end

    def rsync(src, dst, cmd_opts = {})
      syscmd(
        "rsync -rlptgoDHX --numeric-ids --inplace --delete-after --exclude .zfs/ "+
        "-e \"ssh -p #{opts[:port]}\" "+
        "#{src} #{opts[:dst]}:#{dst}",
        cmd_opts
      )
    end

    def root_sshcmd(cmd)
      args = [
        'ssh',
        '-o', 'StrictHostKeyChecking=no',
        '-T',
        '-p', opts[:port].to_s,
        '-l', 'root',
        opts[:dst],
        cmd
      ]

      syscmd(args.join(' '))
    end
  end
end
