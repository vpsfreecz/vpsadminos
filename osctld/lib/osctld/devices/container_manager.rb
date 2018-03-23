module OsCtld
  class Devices::ContainerManager < Devices::Manager
    include OsCtl::Lib::Utils::Log

    # @param opts [Hash]
    def init(opts = {})
      super
      inherit_all_from(ct.group, opts)

      log(:info, ct, "Configuring cgroup #{ct.cgroup_path} for devices")
      create
    end

    # Create cgroups and apply device settings
    def create
      rel_group_cgroup_paths.zip(abs_group_cgroup_paths).each do |rel, abs|
        next if !rel[1] || !abs[1]

        rel_path = rel[0]
        abs_path = abs[0]

        CGroup.mkpath('devices', rel_path.split('/'))
        clear_devices(abs_path)
        apply_devices(ct.group.devices, abs_path)
      end

      rel_ct_cgroup_paths.zip(abs_ct_cgroup_paths).each do |rel, abs|
        next if !rel[1] || !abs[1]

        rel_path = rel[0]
        abs_path = abs[0]

        CGroup.mkpath('devices', rel_path.split('/'))
        clear_devices(abs_path)
        apply_devices(self, abs_path)
      end

      abs_ct_chowned_cgroup_paths.each do |abs, req|
        next if !req && !Dir.exist?(abs)
        File.chown(ct.user.ugid, ct.user.ugid, abs)
      end
    end

    # @param opts [Hash]
    # @option opts [Boolean] :parents
    # @option opts [Hash] :group_changes
    def chmod(device, mode, opts = {})
      # Parents
      if opts[:parents]
        dev = device.clone
        dev.mode = mode

        ct.group.devices.provide(dev)
      end

      # <group>/<user>
      if opts[:group_changes] # for recursive chmod from the group down
        abs_group_cgroup_paths.each do |cgpath, req|
          next if !req && !Dir.exist?(cgpath)
          do_apply_changes(opts[:group_changes], path: cgpath)
        end

      else # when chmodding the container itself
        abs_group_cgroup_paths.each do |cgpath, req|
          next if !req && !Dir.exist?(cgpath)
          apply_devices(ct.group.devices, cgpath)
        end
      end

      # Container cgroups
      changes = device.chmod(mode)
      device.inherited = false if opts[:promote] && device.inherited?
      ct.save_config

      abs_ct_cgroup_paths.each do |cgpath, req|
        next if !req && !Dir.exist?(cgpath)
        do_apply_changes(changes, path: cgpath)
      end
    end

    def inherit_promoted(device)
      pdev = ct.group.devices.get(device)

      if pdev.inherit?
        # We can keep the device and descendants unchanged
        device.inherited = true

        # Parent group can have broader access mode, so we need to expand it
        if device.mode != pdev.mode
          changes = device.chmod(pdev.mode.clone)

          abs_all_cgroup_paths.each do |cgpath, req|
            next if !req && !Dir.exist?(cgpath)
            do_apply_changes(changes, path: cgpath)
          end
        end

        ct.save_config
        return
      end

      # Parent does not provide the device, remove it
      remove(device)
    end

    def update_inherited_mode(device, mode, changes)
      abs_all_cgroup_paths.each do |cgpath, req|
        next if !req && !Dir.exist?(cgpath)
        do_apply_changes(changes, path: cgpath)
      end
    end

    # Apply the container's device cgroup settings
    def apply(_opts = {})
      # group
      ct.group.devices.apply

      abs_group_cgroup_paths.each do |cgpath, req|
        next if !req && !Dir.exist?(cgpath)
        apply_devices(ct.group.devices, cgpath)
      end

      # container groups
      abs_ct_cgroup_paths.each do |cgpath, req|
        next if !req && !Dir.exist?(cgpath)
        apply_devices(self, cgpath)
      end
    end

    # Check that all devices are provided by parents, or raise an exception
    # @param group [Group, nil] which group to use as the container's parent,
    #                           defaults to the container's group
    def check_all_available!(group = nil)
      devices.each { |dev| check_availability!(dev, group || ct.group) }
    end

    # Ensure that all required devices are provided by parent groups
    def ensure_all
      devices.each { |dev| ct.group.devices.provide(dev) }
    end

    # Remove devices that aren't provided by the parent, or have insufficient
    # access mode
    def remove_missing
      devices.delete_if do |dev|
        pdev = ct.group.devices.get(dev)
        pdev.nil? || !pdev.mode.compatible?(dev.mode)
      end
    end

    def check_descendants!(*_)
      # Containers do not have any descendants
    end

    protected
    alias_method :ct, :owner

    # @param devices [Devices::Manager]
    # @param path [String] absolute cgroup path
    def apply_devices(devices, path)
      devices.each do |dev|
        CGroup.set_param(File.join(path, 'devices.allow'), [dev.to_s])
      end
    end

    # @param path [String] absolute cgroup path
    def clear_devices(path)
      CGroup.set_param(File.join(path, 'devices.deny'), ['a'])
    end

    # Returns a list of relative paths of the container's group cgroups.
    #
    # These cgroups share the settings of the container's group.
    #
    # @return [Array]
    def rel_group_cgroup_paths
      [
        # <group>/<user>
        [ct.group.full_cgroup_path(ct.user), true],
      ]
    end

    # Returns a list of all relative cgroup paths that need to be configured for
    # this container, from the top down.
    #
    # The returned array contains pairs: `[String, Boolean]`. The `String`
    # is the path itself, while the `Boolean` determines whether this path
    # should be created. Paths that do not need to be created are configured
    # only if they already exist. This is used only for the `./lxc/<ct>` cgroup,
    # which LXC wants to create by itself.
    #
    # @return [Array]
    def rel_ct_cgroup_paths
      [
        # <group>/<user>/<ct>
        [ct.base_cgroup_path, true],

        # <group>/<user>/<ct>/user-owned
        [ct.cgroup_path, true],

        # <group>/<user>/<ct>/user-owned/lxc
        [File.join(ct.cgroup_path, 'lxc'), true],

        # <group>/<user>/<ct>/user-owned/lxc/<ct>
        [File.join(ct.cgroup_path, 'lxc', ct.id), false],
      ]
    end

    # Returns a list of absolute paths of the container's group cgroups
    # @return [Array]
    def abs_group_cgroup_paths
      to_abs_paths(rel_group_cgroup_paths)
    end

    # Returns a list of all absolute cgroup paths that need to be configured for
    # this container, from the top down.
    # @return [Array]
    def abs_ct_cgroup_paths
      to_abs_paths(rel_ct_cgroup_paths)
    end

    # Returns a list of the container's absolute cgroup paths that are to be
    # chowned to the user.
    # @return [Array]
    def abs_ct_chowned_cgroup_paths
      to_abs_paths([
        # <group>/<user>/<ct>/user-owned
        [ct.cgroup_path, true],

        # <group>/<user>/<ct>/user-owned/lxc
        [File.join(ct.cgroup_path, 'lxc'), true],

        # <group>/<user>/<ct>/user-owned/lxc/<ct>
        [File.join(ct.cgroup_path, 'lxc', ct.id), false],
      ])
    end

    # @return [Array]
    def abs_all_cgroup_paths
      abs_group_cgroup_paths + abs_ct_cgroup_paths
    end

    def to_abs_paths(rel_paths)
      rel_paths.map do |path, req|
        [File.join(CGroup::FS, CGroup.real_subsystem('devices'), path), req]
      end
    end
  end
end
