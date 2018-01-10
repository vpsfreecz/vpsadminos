module OsCtld
  class Commands::Container::Assets < Commands::Assets
    handle :ct_assets

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      # Datasets
      add(:dataset, ct.dataset, "Container's rootfs")

      # Directories and files
      add(:directory, ct.lxc_dir, "LXC configuration")
      add(:file, ct.lxc_config_path, "LXC base config")
      add(:file, ct.lxc_config_path('network'), "LXC network config")
      add(:file, ct.lxc_config_path('prlimits'), "LXC resource limits")
      add(:file, ct.lxc_config_path('mounts'), "LXC mounts")
      add(
        :file,
        File.join(ct.lxc_dir, '.bashrc'),
        'Shell configuration file for osctl ct su'
      )

      add(:file, ct.config_path, "Container config for osctld")
      add(:file, ct.log_path, "LXC log file")

      ok(assets)
    end
  end
end
