module OsCtld
  class Commands::Container::Exec < Commands::Base
    handle :ct_exec

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running

        client.send({status: true, response: 'continue'}.to_json + "\n", 0)

        ct_control(ct, :ct_exec, {
          id: ct.id,
          cmd: opts[:cmd],
          stdin: client.recv_io,
          stdout: client.recv_io,
          stderr: client.recv_io,
        })
      end
    end
  end
end
