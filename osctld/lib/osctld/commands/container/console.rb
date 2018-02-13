require 'base64'

module OsCtld
  class Commands::Container::Console < Commands::Base
    handle :ct_console

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running && opts[:tty] != 0

        client.send({status: true, response: 'continue'}.to_json + "\n", 0)

        Console.client(ct, opts[:tty], client)
        next handled

        # cant hold inclusive lock though... stop woudnt work (uses exclusive)
      end
    end
  end
end
