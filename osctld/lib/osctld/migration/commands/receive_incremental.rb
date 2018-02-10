module OsCtld
  class Migration::Commands::ReceiveIncremental < Migration::Commands::Base
    handle :receive_incremental

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.exclusively do
        error!('this container is not staged') if ct.state != :staged

        if !ct.migration_log || !ct.migration_log.can_continue?(:incremental)
          error!('invalid migration sequence')
        end
      end

      ds = Zfs::Dataset.new(dataset_name(ct), base: ct.dataset.name)
      # don't check its existence now to save time

      client.send({status: true, response: 'continue'}.to_json + "\n", 0)
      io = client.recv_io

      pid = Process.spawn('zfs', 'recv', '-F', ds.name, in: io)
      Process.wait(pid)

      if $?.exitstatus == 0
        ct.exclusively do
          ct.migration_log.state = :incremental
          ct.migration_log.snapshots << [ds.name, opts[:snapshot]]
          ct.save_config
        end
        ok
      else
        error("unable to receive stream, zfs recv exited with #{$?.exitstatus}")
      end
    end

    protected
    def dataset_name(ct)
      if opts[:dataset] == '/'
        ct.dataset.name
      else
        File.join(ct.dataset.name, opts[:dataset])
      end
    end
  end
end
