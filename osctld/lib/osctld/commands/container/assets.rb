module OsCtld
  class Commands::Container::Assets < Commands::Base
    handle :ct_assets

    include Utils::Assets

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ok(list_and_validate_assets(ct))
    end
  end
end
