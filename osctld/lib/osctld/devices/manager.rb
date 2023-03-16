module OsCtld
  class Devices::Manager
    # Get manager class group/container on cgroup v1/v2
    # @param owner [Devices::Owner]
    # @return [Class]
    def self.class_for(owner)
      mod =
        if CGroup.v1?
          Devices::V1
        else
          Devices::V2
        end

      case owner
      when Group
        mod::GroupManager
      when Container
        mod::ContainerManager
      else
        fail "unsupported device owner #{owner.inspect}"
      end
    end

    # @param owner [Devices::Owner]
    # @return [Devices::Manager]
    def self.new_for(owner, **kwargs)
      class_for(owner).new(owner, **kwargs)
    end

    # @param owner [Devices::Owner]
    # @param cfg [Hash]
    def self.load(owner, cfg)
      new_for(owner, devices: cfg.map { |v| Devices::Device.load(v) })
    end

    # @param owner [Devices::Owner]
    # @param devices [Array<Devices::Device>]
    def initialize(owner, devices: [])
      @owner = owner
      @devices = devices
      @configurator = configurator_class.new(owner)
    end

    # Initialize device list
    # @param opts [Hash] can be used by subclasses
    def init(**opts)
      sync do
        if parent
          parent.devices.each do |parent_dev|
            next if !parent_dev.inherit? || include?(parent_dev)

            dev = parent_dev.clone
            dev.inherited = true
            do_add(dev)
          end
        end

        configurator.init(devices)
      end
    end

    # Add new device
    # @param type [:char, :block]
    # @param major [Integer, Symbol]
    # @param minor [Integer, Symbol]
    # @param mode [String]
    # @param opts [Hash]
    # @option opts [String] :name
    # @option opts [Boolean] :inherit should the child groups/containers
    #                                 inherit this device?
    # @option opts [Boolean] :inherited was this device inherited from the
    #                                   parent group?
    def add_new(type, major, minor, mode, **opts)
      add(Devices::Device.new(type, major.to_s, minor.to_s, mode, **opts))
    end

    # Add new device and ensure that parent groups provide it
    # @param device [Devices::Device]
    def add(device)
      sync do
        parent.devices.provide(device) if parent
        do_add(device)

        add_to_changeset
        configurator.add_device(device)

        if device.inherit?
          inherit_recursive(device)
        end
      end
    end

    # Inherit device from a parent
    # @param device [Devices::Device]
    # @param opts [Hash] can be used by subclasses
    def inherit(device, **opts)
      sync do
        dev = device.clone
        dev.inherited = true
        do_add(dev)

        add_to_changeset
        configurator.add_device(dev)

        children.each do |child|
          child.devices.inherit(dev)
        end
      end
    end

    # Add device to make it available to child groups
    # @param device [Devices::Device]
    def provide(device)
      sync do
        dev = get(device)

        if dev
          # Check if we have compatible modes
          return if dev.mode.compatible?(device.mode)

          # Broader access mode is required
          dev.mode.complement(device.mode)

          # Propagate the mode change to parent groups
          parent.devices.provide(device) if parent

          # Apply cgroup
          # Since the mode was complemented, we don't have to deny existing
          # access modes, only allow new ones
          add_to_changeset
          configurator.add_device(dev)

          # Save it
          owner.save_config

          return
        end

        # Device does not exist, ask the parent to provide it and create it
        parent.devices.provide(device) if parent

        dev = device.clone
        dev.inherit = false
        do_add(dev)
        add_to_changeset
        configurator.add_device(dev)
        owner.save_config
      end
    end

    # Remove device from self
    # @param device [Devices::Device]
    def remove(device)
      sync do
        children.each do |child|
          child_dev = child.devices.get(device)
          next if child_dev.nil?

          child.devices.remove(child_dev)
        end

        devices.delete(device)
        owner.save_config

        add_to_changeset
        configurator.remove_device(device)
      end
    end

    # @param device [Devices::Device]
    # @param mode [Devices::Mode]
    # @param parents [Boolean]
    # @param promote [Boolean]
    # @param descendants [Boolean]
    # @param parent_changes [Hash]
    def chmod(device, mode, parents: false, promote: false, descendants: false, **opts)
      sync do
        if parents && parent
          dev = device.clone
          dev.mode = mode
          parent.devices.provide(dev)
        end

        changes = device.chmod(mode)
        device.inherited = false if promote && device.inherited?
        owner.save_config

        add_to_changeset
        configurator.apply_changes(changes)

        if descendants
          children.each do |child|
            dev = child.devices.get(device)
            next if dev.nil?

            child.devices.chmod(dev, mode, descendants: true, parent_changes: changes)
          end
        end
      end
    end

    # Promote device, i.e. remove its inherited status and save it in config
    # @param device [Devices::Device]
    def promote(device)
      device.inherited = false
      owner.save_config
    end

    # Inherit a promoted device
    # @param device [Devices::Device]
    def inherit_promoted(device)
      sync do
        parent_dev = parent.devices.get(device) if parent

        if parent_dev && parent_dev.inherit?
          # We can keep the device and descendants unchanged
          device.inherited = true

          # Parent group can have broader access mode, so we need to expand it
          if device.mode != parent_dev.mode
            add_to_changeset
            changes = device.chmod(parent_dev.mode.clone)
            configurator.apply_changes(changes)

            # Update descendants that inherit the device as well
            children.each do |child|
              child_dev = child.devices.get(device)
              next unless child_dev.inherited?

              child.devices.update_inherited_mode(child_dev, parent_dev.mode.clone, changes)
            end
          end

          owner.save_config
          return
        end

        # Parent does not provide the device, remove it
        if used_by_descendants?(device)
          raise DeviceInUse,
                'the device would be removed, but child groups or containers '+
                'are using it'
        end

        remove(device)
      end
    end

    # Called when the access mode of the device in the parent group changes
    #
    # This method should update the mode and pass the information to its own
    # descendants.
    #
    # @param device [Devices::Device]
    # @param mode [Devices::Mode]
    # @param changes [Hash]
    def update_inherited_mode(device, mode, changes)
      sync do
        device.mode = mode
        owner.save_config

        add_to_changeset
        configurator.apply_changes(changes)

        children.each do |child|
          child_dev = child.devices.get(device)
          next unless child_dev.inherited?

          child.devices.update_inherited_mode(child_dev, mode.clone, changes)
        end
      end
    end

    # Mark device as inheritable
    # @param device [Devices::Device]
    def set_inherit(device)
      sync do
        device.inherit = true
        inherit_recursive(device)
        owner.save_config
      end
    end

    # Remove inheritable mark
    # @param device [Devices::Device]
    def unset_inherit(device)
      sync do
        check_unset_inherit!(device)

        device.inherit = false
        uninherit_recursive(device)
        owner.save_config
      end
    end

    # Add the device to all descendants
    def inherit_recursive(device)
      sync do
        children.each do |child|
          next if child.devices.include?(device)

          # Add from the top down
          child.devices.inherit(device)
          child.devices.inherit_recursive(device)
        end
      end
    end

    # Remove the device from all descendats
    def uninherit_recursive(device)
      sync do
        children.each do |child|
          next if child.devices.used?(device)

          # Remove from the bottom up
          child.devices.uninherit_recursive(device)
          child.devices.remove(device)
        end
      end
    end

    # Configure devices in cgroup
    # @param opts [Hash]
    def apply(parents: false, descendants: false)
      sync do
        if parents
          parent.devices.apply(parents: true) if parent
        end

        configurator.reconfigure(devices)

        if descendants
          children.each do |child|
            child.devices.apply(descendants: true)
          end
        end
      end
    end

    # Replace configured devices by a new set
    #
    # `new_devices` has to contain devices that are to be promoted. Devices
    # that were promoted but are no longer in `new_devices` will be removed.
    # Devices that are inherited from parent groups are promoted if they're
    # in `new_devices`, otherwire they're left alone.
    #
    # Note that this method does not enforce nor manage proper parent/descendant
    # dependencies. It is possible to add a device which is not provided by
    # parents or to remove a device that is needed by descendants.
    #
    # @param new_devices [Array<Devices::Device>]
    def replace(new_devices)
      sync do
        to_add = []
        to_inherit = []
        to_promote = []
        to_chmod = []

        # Find devices to promote, chmod and remove/inherit
        devices.each do |cur_dev|
          found = new_devices.detect { |new_dev| new_dev == cur_dev }

          if found.nil?
            to_inherit << cur_dev unless cur_dev.inherited?

          elsif found.inherited?
            if found.mode == cur_dev.mode
              to_promote << cur_dev
            else
              to_chmod << [cur_dev, found.mode]
            end

          elsif found.mode != cur_dev.mode
            to_chmod << [cur_dev, found.mode]
          end
        end

        # Find devices to add
        new_devices.each do |new_dev|
          found = devices.detect { |cur_dev| cur_dev == new_dev }
          to_add << new_dev if found.nil?
        end

        # Apply changes
        to_add.each { |dev| add(dev) }
        to_promote.each { |dev| promote(dev) }
        to_chmod.each do |dev, mode|
          chmod(dev, mode, promote: true, descendants: true)
        end
        to_inherit.each { |dev| inherit_promoted(dev) }

        apply(descendants: true)
      end
    end

    # Check whether the device is available in parents
    # @param device [Devices::Device]
    def check_availability!(device, mode: nil)
      sync do
        tmp = self

        loop do
          p = tmp.parent
          break if p.nil?

          dev = p.devices.detect { |v| v == device }

          if dev.nil?
            raise DeviceNotAvailable.new(device, grp)
          elsif !dev.mode.compatible?(mode || device.mode)
            raise DeviceModeInsufficient.new(device, p, dev.mode)
          end
        end
      end
    end

    # Check whether descendants do not have broader mode requirements
    def check_descendants!(device, mode: nil)
      sync do
        children.each do |child|
          child.devices.check_descendant_mode!(device, mode || device.mode)
        end
      end
    end

    # @param device [Device]
    # @return [Boolean]
    def used_by_descendants?(device)
      sync do
        children.each do |child|
          if child.devices.used?(device) || child.devices.used_by_descendants?(device)
            return true
          end
        end
      end

      false
    end

    # Find device by `type` and `major` and `minor` numbers
    # @param type [Symbol] `:char`, `:block`
    # @param major [String]
    # @param minor [String]
    # @return [Devices::Device, nil]
    def find(type, major, minor)
      sync do
        devices.detect do |dev|
          dev.type == type && dev.major == major && dev.minor == minor
        end
      end
    end

    # Find and return device
    #
    # The point of this method is to return the manager's own device's instance.
    # Devices equality is tested by comparing its type and major and minor
    # numbers, but its devnode name or mode can be different.
    # @return [Devices::Device, nil]
    def get(device)
      sync do
        i = devices.index(device)
        i ? devices[i] : nil
      end
    end

    # Check if we have a particular device
    # @param device [Device]
    # @return [Boolean]
    def include?(device)
      sync { devices.include?(device) }
    end

    # Check if device exists and is inherited
    # @param device [Device]
    # @return [Boolean]
    def inherited?(device)
      sync do
        dev = devices.detect { |v| v == device }
        next(false) unless dev
        dev.inherited?
      end
    end

    # Check if device exists and is used, not just inherited
    # @param device [Device]
    # @return [Boolean]
    def used?(device)
      sync do
        dev = devices.detect { |v| v == device }
        next(false) unless dev
        !dev.inherited?
      end
    end

    # @yieldparam [Devices::Device]
    def each(&block)
      sync { devices.each(&block) }
    end

    # @yieldparam [Devices::Device]
    def detect(&block)
      sync { devices.detect(&block) }
    end

    # @yieldparam [Devices::Device]
    def select(&block)
      sync { devices.select(&block) }
    end

    # @return [Devices::Manager, nil]
    def parent
      raise NotImplementedError
    end

    # @return [Array<Devices::Manager>]
    def children
      raise NotImplementedError
    end

    # @return [Class]
    def configurator_class
      raise NotImplementedError
    end

    # @return [any]
    def changeset_sort_key
      raise NotImplementedError
    end

    # Export devices to clients
    # @return [Array<Hash>]
    def export
      sync { devices.map { |dev| dev.export } }
    end

    # Dump device configuration into the config
    # @return [Array<Hash>]
    def dump
      sync { devices.reject(&:inherited?).map { |dev| dev.dump } }
    end

    def dup(new_owner)
      sync do
        ret = super()
        ret.instance_variable_set('@owner', new_owner)
        ret.instance_variable_set('@devices', devices.map(&:clone))
        ret.instance_variable_set('@configurator', configurator.dup(new_owner))
        ret
      end
    end

    protected
    attr_reader :owner, :devices, :configurator

    def do_add(device)
      devices << device
    end

    # Check if the inheritance can be disabled
    #
    # We have to forbid disabling the inheritance if any grandchild has the device
    # promoted, but its parent does not. Thus, the device cannot be deleted from
    # self, because the grandchild needs it.
    def check_unset_inherit!(device, check_owner: nil)
      if check_owner.nil?
        children.each do |child|
          if child.devices.inherited?(device)
            # Since our child inherits the device, his descendants must not use it
            check_unset_inherit!(device, check_owner: child)
          end
        end

      else
        check_owner.devices.children.each do |child|
          if child.devices.used?(device)
            raise DeviceInheritNeeded, child
          else
            check_unset_inherit!(device, check_owner: child)
          end
        end
      end
    end

    def check_descendant_mode!(device, mode)
      dev = get(device)
      return if !dev || mode.compatible?(dev.mode)

      raise DeviceDescendantRequiresMode.new(owner, dev.mode)
    end

    def add_to_changeset
      Devices::ChangeSet.add(owner.pool, self, changeset_sort_key)
    end

    def sync(&block)
      Devices::Lock.sync(owner.pool, &block)
    end
  end
end
