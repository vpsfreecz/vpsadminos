require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Runscript < Commands::Base
    handle :ct_runscript

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      error!('container not running') if !ct.running? && !opts[:run]

      # Ensure the container is mounted
      ct.mount

      client.send("#{{ status: true, response: 'continue' }.to_json}\n", 0)

      st = ContainerControl::Commands::Runscript.run!(
        ct,
        script: opts[:script],
        args: opts[:arguments] || [],
        run: opts[:run],
        network: opts[:network],
        stdin: client.recv_io,
        stdout: client.recv_io,
        stderr: client.recv_io
      )
      ok(exitstatus: st)
    rescue ContainerControl::Error => e
      error(e.message)
    end
  end
end
