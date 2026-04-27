require 'osctld/commands/container/local_transfer/base'

module OsCtld
  class Commands::Container::LocalTransfer::Config < Commands::Container::LocalTransfer::Base
    def execute(ct)
      target_pool = resolve_target_pool(ct)
      target_user, target_group = resolve_target_user_group(ct, target_pool)

      if DB::Containers.contains?(opts[:target_id], target_pool)
        error!("container #{target_pool.name}:#{opts[:target_id]} already exists")
      end

      new_ct = ct.exclusively do
        if ct.transfer_in_progress?
          error!('this container already has a transfer in progress')
        end

        ct.dup(
          opts[:target_id],
          pool: target_pool,
          user: target_user,
          group: target_group,
          dataset: opts[:target_dataset],
          network_interfaces: opts[:network_interfaces]
        )
      end

      builder = Container::Builder.new(new_ct.new_run_conf, cmd: self)
      error!(builder.errors.join('; ')) unless builder.valid?

      manipulate([ct, new_ct]) do
        unless builder.register
          error!("container #{new_ct.pool.name}:#{new_ct.id} already exists")
        end

        begin
          dataset_map = build_dataset_map(ct, new_ct)

          create_target_datasets(builder, dataset_map)
          new_ct.save_config
          builder.setup_ct_dir
          builder.setup_lxc_home
          builder.setup_lxc_configs
          builder.setup_log_file
          builder.setup_user_hook_script_dir
          builder.monitor

          ct.open_local_transfer_log(
            :source,
            operation:,
            target_pool: new_ct.pool.name,
            target_id: new_ct.id,
            target_dataset: new_ct.dataset.name,
            target_dataset_custom: !opts[:target_dataset].nil?,
            target_user: new_ct.user.name,
            target_group: new_ct.group.name,
            network_interfaces: opts[:network_interfaces],
            datasets: dataset_map
          )
        rescue StandardError
          progress('Error occurred, cleaning up')
          builder.cleanup(dataset: !opts[:target_dataset])
          raise
        end
      end

      call_cmd!(Commands::User::LxcUsernet) if opts[:network_interfaces]
      ok
    end

    protected

    def resolve_target_pool(ct)
      target_pool = opts[:target_pool] ? DB::Pools.find(opts[:target_pool]) : ct.pool
      error!('pool not found') unless target_pool

      target_pool
    end

    def resolve_target_user_group(ct, target_pool)
      return [nil, nil] if target_pool == ct.pool

      target_user = DB::Users.find(opts[:target_user] || ct.user.name, target_pool)
      error!('target user not found') unless target_user

      target_group = DB::Groups.find(opts[:target_group] || ct.group.name, target_pool)
      error!('target group not found') unless target_group

      [target_user, target_group]
    end

    def create_target_datasets(builder, dataset_map)
      dataset_map.each do |pair|
        builder.create_dataset(
          OsCtl::Lib::Zfs::Dataset.new(pair.target, base: builder.ctrc.dataset.name),
          mapping: builder.ctrc.map_mode == 'zfs'
        )
      end
    end
  end
end
