module OsCtld
  class Devices::ContainerManager < Devices::Manager
    include OsCtl::Lib::Utils::Log

    # @param opts [Hash]
    # @option opts [Boolean] :mknod create device nodes?
    def init(opts = {})
      super()
      inherit_all_from(ct.group, opts)

      log(:info, ct, "Configuring cgroup #{ct.cgroup_path} for devices")

      ### Create cgroups & configure parameters
      # <group>/<user>
      CGroup.mkpath('devices', ct.group.full_cgroup_path(ct.user).split('/'))
      apply_group_user_params

      # <group>/<user>/<ct>
      CGroup.mkpath('devices', ct.cgroup_path.split('/'))
      apply_group_user_ct_params

      # NOTE: if the devices cgroup would be chowned to the user, we would also
      # need to handle cgroup <group>/<user>/<ct>/lxc and lxc/<ct>!
    end

    def add(device, parent = nil)
      super
      DistConfig.run(ct, :create_devnode, device) if device.name
    end

    # @param opts [Hash]
    # @option opts [Boolean] :mknod create device nodes?
    def inherit(device, opts = {})
      super

      if device.name && (!opts.has_key?(:mknod) || opts[:mknod])
        DistConfig.run(ct, :create_devnode, device)
      end
    end

    def remove(device)
      super
      return unless device.name

      devnode = File.join(ct.rootfs, device.name)
      return unless File.exist?(devnode)

      File.unlink(devnode)
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
        do_apply_changes(
          opts[:group_changes],
          path: File.join(ct.group.abs_cgroup_path('devices'), ct.user.name)
        )

      else # when chmodding the container itself
        apply_group_user_params
      end

      # <group>/<user>/<ct>
      super
    end

    def inherit_promoted(device)
      pdev = ct.group.devices.get(device)

      if pdev.inherit?
        # We can keep the device and descendants unchanged
        device.inherited = true

        # Parent group can have broader access mode, so we need to expand it
        if device.mode != pdev.mode
          changes = device.chmod(pdev.mode.clone)

          # <group>/<user>
          do_apply_changes(
            changes,
            path: File.join(ct.group.abs_cgroup_path('devices'), ct.user.name)
          )

          # <group>/<user>/<ct>
          do_apply_changes(changes)
        end

        ct.save_config
        return
      end

      # Parent does not provide the device, remove it
      remove(device)
    end

    def update_inherited_mode(device, mode, changes)
      # <group>/<user>
      do_apply_changes(
        changes,
        path: File.join(ct.group.abs_cgroup_path('devices'), ct.user.name)
      )

      # <group>/<user>/<ct>
      super
    end

    # Apply the container's device cgroup settings
    def apply(_opts = {})
      clear

      # group
      ct.group.devices.apply

      # <group>/<user>
      apply_group_user_params

      # <group>/<user>/<ct>
      apply_group_user_ct_params
    end

    # Check that all devices are provided by parents, or raise an exception
    def check_all_available!
      devices.each { |dev| check_availability!(dev, ct.group) }
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
        pdev.nil? || !pdev.mode.compatible?(dev)
      end
    end

    def check_descendants!(*_)
      # Containers do not have any descendants
    end

    protected
    alias_method :ct, :owner

    # Apply parameters to cgroup `<group>/<user>`
    def apply_group_user_params
      ct.group.devices.each do |dev|
        CGroup.set_param(
          File.join(
            ct.group.abs_cgroup_path('devices'),
            ct.user.name,
            'devices.allow'
          ),
          [dev.to_s]
        )
      end
    end

    # Apply parameters to cgroup `<group>/<user>/<ct>`
    def apply_group_user_ct_params
      devices.each { |dev| do_allow_dev(dev) }
    end
  end
end
