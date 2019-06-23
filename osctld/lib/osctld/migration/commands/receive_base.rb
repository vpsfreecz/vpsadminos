require 'osctld/migration/commands/base'

module OsCtld
  class Migration::Commands::ReceiveBase < Migration::Commands::Base
    handle :receive_base

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct

      ct.manipulate(self, block: true) do
        error!('this container is not staged') if ct.state != :staged

        if !ct.send_log || !ct.send_log.can_continue?(:base)
          error!('invalid send sequence')
        end

        ds = OsCtl::Lib::Zfs::Dataset.new(dataset_name(ct), base: ct.dataset.name)
        error!('dataset does not exist') unless ds.exist?

        client.send({status: true, response: 'continue'}.to_json + "\n", 0)
        io = client.recv_io

        pid = Process.spawn('zfs', 'recv', '-F', ds.name, in: io)
        Process.wait(pid)

        if $?.exitstatus == 0
          ct.exclusively do
            ct.send_log.state = :base
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
