require 'libosctl'
require 'osctld/devices/manager'

module OsCtld
  class Devices::GroupManager < Devices::Manager
    include OsCtl::Lib::Utils::Log

    def init(opts = {})
      sync do
        super
        inherit_all_from(group.parent, opts) unless group.root?

        log(:info, group, "Configuring cgroup #{group.cgroup_path} for devices")
        if CGroup.mkpath('devices', group.cgroup_path.split('/'))
          apply(parents: false)
        end
      end
    end

    # Add device to make it available to child groups
    # @param device [Device]
    def provide(device)
      sync do
        dev = get(device)

        if dev
          # Check if we have compatible modes
          return if dev.mode.compatible?(device.mode)

          # Broader access mode is required
          dev.mode.complement(device.mode)

          # Propagate the mode change to parent groups
          group.parent.devices.provide(device) unless group.root?

          # Apply cgroup
          # Since the mode was complemented, we don't have to deny existing
          # access modes, only allow new ones
          apply(parents: false)

          # Save it
          group.save_config

          return
        end

        # Device does not exist, ask the parent to provide it and create it
        group.parent.devices.provide(device) unless group.root?

        dev = device.clone
        dev.inherit = false
        do_add(dev)
        apply(parents: false)
        group.save_config
      end
    end

    def add(device, parent = nil)
      sync do
        super

        if device.inherit?
          group.descendants.each { |grp| grp.devices.inherit(device) }

          group.containers.each do |ct|
            ct.devices.inherit(device)
          end
        end
      end
    end

    def inherit(device, opts = {})
      sync do
        super

        group.containers.each do |ct|
          ct.devices.inherit(device)
        end
      end
    end

    def remove(device)
      sync do
        super

        group.containers.each do |ct|
          ct.devices.remove(device)
        end
      end
    end

    # Remove device from self and all descendants
    # @param device [Device]
    def remove_recursive(device)
      sync do
        group.descendants.reverse_each do |grp|
          dev = grp.devices.get(device)
          grp.devices.remove(dev) if dev
        end

        remove(device)
      end
    end

    # @param opts [Hash]
    # @option opts [Boolean] :parents
    # @option opts [Boolean] :descendants
    # @option opts [Boolean] :containers
    def chmod(device, mode, opts = {})
      sync do
        # Parents
        if opts[:parents]
          dev = device.clone
          dev.mode = mode

          group.parent.devices.provide(dev)
        end

        # Self
        changes = super

        # Descendants
        if opts[:descendants]
          group.descendants.each do |grp|
            dev = grp.devices.get(device)
            grp.devices.chmod(dev, mode, containers: true) if dev
          end
        end

        if opts[:containers]
          group.containers.each do |ct|
            dev = ct.devices.get(device)
            ct.devices.chmod(dev, mode, group_changes: changes) if dev
          end
        end
      end
    end

    def inherit_promoted(device)
      sync do
        pdev = group.parent.devices.get(device) unless group.root?

        if pdev && pdev.inherit?
          # We can keep the device and descendants unchanged
          device.inherited = true

          # Parent group can have broader access mode, so we need to expand it
          if device.mode != pdev.mode
            changes = device.chmod(pdev.mode.clone)
            do_apply_changes(changes)

            # Update descendants that inherit the device as well
            do_update_inherited_descendants(device, pdev.mode, changes)
          end

          group.save_config
          return
        end

        # Parent does not provide the device, remove it
        if used_by_descendants?(device)
          raise DeviceInUse,
                'the device would be removed, but child groups or containers '+
                'are using it'
        end

        remove_recursive(device)
      end
    end

    def update_inherited_mode(device, mode, changes)
      sync do
        # Update self
        super

        # Update descendants that inherit the device as well
        do_update_inherited_descendants(device, mode, changes)
      end
    end

    def set_inherit(device)
      sync do
        device.inherit = true
        inherit_recursive(device)
        owner.save_config
      end
    end

    def unset_inherit(device)
      sync do
        unless can_unset_inherit?(device)
          raise DeviceInUse,
                'unsetting inheritance would break device access requirements'
        end

        device.inherit = false
        uninherit_recursive(device)
        owner.save_config
      end
    end

    # Add the device to all direct child groups and containers, then let the
    # child groups do the same
    def inherit_recursive(device)
      sync do
        # Add the device to direct children
        group.descendants.each do |grp|
          next if grp.parent != group || grp.devices.include?(device)

          # Add from the top down
          grp.devices.inherit(device)
          grp.devices.apply(parents: false)
          grp.devices.inherit_recursive(device)
        end

        # Add the device to containers
        group.containers.each do |ct|
          # grp.devices.inherit will also pass the device to all containers
          ct.devices.apply
        end
      end
    end

    # Remove the device from all direct child groups and containers, then let
    # the child groups do the same
    def uninherit_recursive(device)
      sync do
        # Remove the device from direct children
        group.descendants.each do |grp|
          next if grp.parent != group || grp.devices.used?(device)

          # Remove from the bottom up
          grp.devices.uninherit_recursive(device)
          grp.devices.remove(device)
        end

        # Remove the device from containers
        group.containers.each do |ct|
          next if ct.devices.used?(device)
          ct.devices.remove(device)
        end
      end
    end

    # Apply cgroup parameters of the group and all its parents
    def apply(parents: true, descendants: false, containers: false)
      sync do
        if parents
          group.parents.each do |grp|
            grp.devices.apply(parents: false)
          end
        end

        super()

        if descendants
          group.descendants.each do |grp|
            grp.devices.apply(parents: false, descendants: false, containers: containers)
          end
        end

        if containers
          group.containers.each do |ct|
            ct.devices.apply
          end
        end
      end
    end

    def check_descendants!(device, mode: nil)
      sync do
        # Check child groups and their containers
        group.descendants.each do |grp|
          check_descendant_mode!(grp, device, mode || device.mode)

          grp.containers.each do |ct|
            check_descendant_mode!(ct, device, mode || device.mode)
          end
        end

        # Check containers in self
        group.containers.each do |ct|
          check_descendant_mode!(ct, device, mode || device.mode)
        end
      end
    end

    # @param device [Device]
    # @return [Boolean]
    def used_by_descendants?(device)
      sync do
        group.descendants.each do |grp|
          return true if grp.devices.used?(device)

          grp.containers.each do |ct|
            return true if ct.devices.used?(device)
          end
        end

        group.containers.each do |ct|
          return true if ct.devices.used?(device)
        end

        false
      end
    end

    protected
    alias_method :group, :owner

    def check_descendant_mode!(entity, device, mode)
      dev = entity.devices.get(device)
      return if !dev || mode.compatible?(dev.mode)

      raise DeviceDescendantRequiresMode.new(entity, dev.mode)
    end

    def do_update_inherited_descendants(device, mode, changes)
      # Update access modes in child groups that inherit this device
      group.children.each do |grp|
        cdev = grp.devices.get(device)
        next unless cdev.inherited?

        grp.devices.update_inherited_mode(cdev, mode.clone, changes)
      end

      # Update access modes in child containers that inherit this device
      group.containers.each do |ct|
        cdev = ct.devices.get(device)
        next unless cdev.inherited?

        ct.devices.update_inherited_mode(cdev, mode.clone, changes)
      end
    end

    # Check if the inheritance can be disabled
    #
    # We have to forbid disabling the inheritance if a container has the device
    # promoted, but its group does not. Thus, the device cannot be deleted from
    # the group, because the container needs it. The same applies for promoted
    # group devices.
    def can_unset_inherit?(device)
      # Check my containers
      group.containers.each do |ct|
        return false if ct.devices.used?(device)
      end

      # Check all descendants and their containers
      group.descendants.each do |grp|
        # Find the group's device
        dev = grp.devices.get(device)

        # Find the device of the parent
        parent = grp.parent

        # Skip the parent group check, if the parent is actually the changed
        # group, i.e. self.
        if parent != group
          pdev = parent.devices.get(device)

          # If the parent's device is promoted, we don't have to deal with this
          # group, as it will not be affected.
          next if !pdev.inherited?

          return false if grp.devices.used?(device)
        end

        # If the group's device is promoted, its containers are safe
        next unless dev.inherited?

        grp.containers.each do |ct|
          return false if ct.devices.used?(device)
        end
      end

      true
    end
  end
end
