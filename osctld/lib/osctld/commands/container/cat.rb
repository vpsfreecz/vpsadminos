require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Cat < Commands::Base
    handle :ct_cat

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      error!('container not found') unless ct
      error!('container not running') if !ct.running? || ct.init_pid.nil?

      # Ensure the container is mounted
      ct.mount

      client.send("#{{ status: true, response: 'continue' }.to_json}\n", 0)

      out_w = client.recv_io

      errors = ContainerControl::Commands::Cat.run!(ct, files: opts[:files], stdout: out_w)

      out_w.close

      ok(errors:)
    rescue ContainerControl::Error => e
      error(e.message)
    ensure
      out_w&.close unless out_w&.closed?
    end
  end
end
