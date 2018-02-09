module OsCtld
  class Commands::Dataset::List < Commands::Base
    handle :ct_dataset_list

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        ok(ct.dataset.list(properties: opts[:properties]).map(&:export))
      end
    end
  end
end
