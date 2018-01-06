module OsCtld
  class Commands::Container::MountList < Commands::Base
    handle :ct_mount_list

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        ok(ct.mounts.map(&:export))
      end
    end
  end
end
