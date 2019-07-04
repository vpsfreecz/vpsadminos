require 'osctld/send_receive/commands/base'

module OsCtld
  class SendReceive::Commands::ReceiveIncremental < SendReceive::Commands::Base
    handle :receive_incremental

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.state != :staged

        ct.exclusively do
          if !ct.send_log || !ct.send_log.can_receive_continue?(:incremental)
            error!('invalid send sequence')
          end
        end

        ds = OsCtl::Lib::Zfs::Dataset.new(dataset_name(ct), base: ct.dataset.name)
        # don't check its existence now to save time

        client.send({status: true, response: 'continue'}.to_json + "\n", 0)
        io = client.recv_io

        pid = Process.spawn('zfs', 'recv', '-F', ds.name, in: io)
        Process.wait(pid)

        if $?.exitstatus == 0
          ct.exclusively do
            ct.send_log.state = :incremental
            ct.send_log.snapshots << [ds.name, opts[:snapshot]] if opts[:snapshot]
            ct.save_config
          end
          ok
        else
          error("unable to receive stream, zfs recv exited with #{$?.exitstatus}")
        end
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
