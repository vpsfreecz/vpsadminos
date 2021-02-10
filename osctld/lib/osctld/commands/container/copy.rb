require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Copy < Commands::Logged
    handle :ct_copy

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!("container not found")
    end

    def execute(ct)
      target_pool = opts[:target_pool] ? DB::Pools.find(opts[:target_pool]) : ct.pool
      error!('pool not found') unless target_pool

      if target_pool == ct.pool
        target_user = nil
        target_group = nil

      else
        target_user = DB::Users.find(opts[:target_user] || ct.user.name, target_pool)
        error!('target user not found') unless target_user

        target_group = DB::Groups.find(opts[:target_group] || ct.group.name, target_pool)
        error!('target group not found') unless target_group
      end

      if DB::Containers.contains?(opts[:target_id], target_pool)
        error!("container #{target_pool.name}:#{opts[:target_id]} already exists")
      end

      new_ct = ct.exclusively do
        ct.dup(
          opts[:target_id],
          pool: target_pool,
          user: target_user,
          group: target_group,
          dataset: opts[:target_dataset],
          network_interfaces: opts[:network_interfaces],
        )
      end

      builder = Container::Builder.new(new_ct.new_run_conf, cmd: self)
      error!(builder.errors.join('; ')) unless builder.valid?

      manipulate([ct, new_ct]) do
        unless builder.register
          error!("container #{new_ct.pool.name}:#{new_ct.id} already exists")
        end

        begin
          copy_datasets_from(builder, ct)
          new_ct.save_config
          builder.setup_ct_dir
          builder.setup_lxc_home
          builder.setup_lxc_configs
          builder.setup_log_file
          builder.setup_user_hook_script_dir
          builder.monitor
          new_ct.state = :complete

        rescue
          progress('Error occurred, cleaning up')
          builder.cleanup(dataset: !opts[:target_dataset])
          raise
        end
      end

      call_cmd!(Commands::User::LxcUsernet)
      ok
    end

    protected
    def copy_datasets_from(builder, ct)
      snaps = []
      src_datasets = ct.datasets
      dst_datasets = [builder.ctrc.dataset] + ct.dataset.descendants.map do |ds|
        OsCtl::Lib::Zfs::Dataset.new(
          File.join(builder.ctrc.dataset.name, ds.relative_name),
          base: builder.ctrc.dataset.name,
        )
      end

      # Create datasets
      dst_datasets.each { |ds| builder.create_dataset(ds, mapping: true) }

      # Copy data
      snaps << builder.copy_datasets(src_datasets, dst_datasets)

      if ct.running? && opts[:consistent]
        call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)

        snaps << builder.copy_datasets(src_datasets, dst_datasets, from: snaps.last)

        call_cmd(
          Commands::Container::Start,
          id: ct.id,
          pool: ct.pool.name,
          force: true,
          wait: false,
        ) if opts[:restart].nil? || opts[:restart]
      end

      # Cleanup snapshots
      (src_datasets + dst_datasets).each do |ds|
        snaps.each { |s| zfs(:destroy, nil, "#{ds}@#{s}") }
      end
    end
  end
end
