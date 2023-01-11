require 'osctld/commands/base'
require 'libosctl'

module OsCtld
  class Commands::TrashBin::DatasetAdd < Commands::Base
    handle :trash_bin_dataset_add

    def execute
      ds = OsCtl::Lib::Zfs::Dataset.new(opts[:dataset])
      error!("#{ds.name} is a pool, provide a dataset") if ds.is_pool?

      pool = DB::Pools.find(ds.pool)
      error!("pool #{ds.pool} not installed in osctld") if pool.nil?

      begin
        pool.trash_bin.add_dataset(ds)
      rescue SystemCommandFailed => e
        error!("unable to add dataset to the trash-bin: #{e.message}")
      end

      ok
    end
  end
end
