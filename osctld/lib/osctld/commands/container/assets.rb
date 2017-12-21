module OsCtld
  class Commands::Container::Assets < Commands::Assets
    handle :ct_assets

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      # Datasets
      add(:dataset, ct.dataset, "Container's rootfs")

      # Directories and files
      add(:directory, ct.lxc_dir, "LXC configuration")
      add(:file, ct.lxc_config_path, "LXC base config")
      add(:file, ct.lxc_config_path('network'), "LXC network config")

      add(:file, ct.config_path, "Container config for osctld")

      ok(assets)
    end
  end
end
