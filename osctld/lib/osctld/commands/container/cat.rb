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

      errors =
        ContainerControl::Commands::WithMountns.run!(
          ct,
          ns_pid: ct.init_pid,
          # Passing out_w as stdout will keep the file descriptor open
          # on fork. It will however not be set as $stdout as WithMountns
          # does not handle it, the write therefore still goes to out_w.
          stdout: out_w,
          block: proc do
            ret = {}

            opts[:files].each do |file|
              File.open(file) do |io|
                ::IO.copy_stream(io, out_w)
              end
            rescue SystemCallError => e
              ret[file] = e.message
            end

            ret
          end
        )

      out_w.close

      ok(errors:)
    rescue ContainerControl::Error => e
      error(e.message)
    end
  end
end
