module OsCtld
  class Devices::Manager
    def self.load(owner, cfg)
      new(owner, devices: cfg.map { |v| Devices::Device.load(v) })
    end

    # @param owner [Group, Container]
    # @param devices [Array<Devices::Device>]
    def initialize(owner, devices: [])
      @owner = owner
      @devices = devices
      @cleared = false
    end

    # Initialize device list
    # @param opts [Hash] can be used by subclasses
    def init(opts = {})

    end

    # Inherit all inheritable devices from parent group
    # @param parent [Group]
    # @param opts [Hash] options passed to {#inherit}
    def inherit_all_from(parent, opts = {})
      parent.devices.each do |dev|
        next if !dev.inherit? || include?(dev)
        inherit(dev, opts)
      end
    end

    def add_new(type, major, minor, mode, opts = {})
      add(Devices::Device.new(type, major, minor, mode, opts))
    end

    # Add new device and ensure that parent groups provide it
    # @param device [Device]
    # @param parent [Group, nil]
    def add(device, parent = nil)
      parent.devices.provide(device) if parent
      do_add(device)
    end

    # Inherit device from a parent group
    # @param device [Device]
    # @param opts [Hash] can be used by subclasses
    def inherit(device, opts = {})
      dev = device.clone
      dev.inherited = true
      do_add(dev)
    end

    # Remove device from self
    # @param device [Device]
    def remove(device)
      devices.delete(device)
      owner.save_config

      begin
        do_deny_dev(device)

      rescue CGroupFileNotFound
        # does not matter
      end
    end

    # @param device [Devices::Device]
    # @param mode [Devices::Mode]
    # @param opts [Hash]
    # @option opts [Boolean] :promote
    # @option opts [Boolean] :parents
    # @return [Hash] changes
    def chmod(device, mode, opts = {})
      changes = device.chmod(mode)
      device.inherited = false if opts[:promote] && device.inherited?
      owner.save_config

      do_apply_changes(changes)
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
      raise NotImplementedError
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
      device.mode = mode
      owner.save_config
      do_apply_changes(changes)
    end

    # Mark device as inheritable
    # @param device [Devices::Device]
    def set_inherit(device)
      device.inherit = true
      owner.save_config
    end

    # Remove inheritable mark
    # @param device [Devices::Device]
    def unset_inherit(device)
      device.inherit = false
      owner.save_config
    end

    # Configure devices in cgroup
    # @param opts [Hash]
    def apply(opts = {})
      clear
      devices.each { |dev| do_allow_dev(dev) }
    end

    # Check whether the device is available in parent groups
    def check_availability!(device, group, mode: nil)
      ([group] + group.parents.reverse).each do |grp|
        dev = grp.devices.detect { |v| v == device }
        raise DeviceNotAvailable.new(device, grp) unless dev

        unless dev.mode.compatible?(mode || device.mode)
          raise DeviceModeInsufficient.new(device, grp, dev.mode)
        end
      end
    end

    # Check whether descendants do not have broader mode requirements
    def check_descendants!(device, mode: nil)
      raise NotImplementedError
    end

    # Find device by `type` and `major` and `minor` numbers
    # @param type [Symbol] `:char`, `:block`
    # @param major [String]
    # @param minor [String]
    # @return [Devices::Device, nil]
    def find(type, major, minor)
      devices.detect do |dev|
        dev.type == type && dev.major == major && dev.minor == minor
      end
    end

    # Find and return device
    #
    # The point of this method is to return the manager's own device's instance.
    # Devices equality is tested by comparing its type and major and minor
    # numbers, but its devnode name or mode can be different.
    # @return [Devices::Device, nil]
    def get(device)
      i = devices.index(device)
      i ? devices[i] : nil
    end

    # Check if we have a particular device
    # @param device [Device]
    # @return [Boolean]
    def include?(device)
      devices.include?(device)
    end

    # Check if device exists and is used, not just inherited
    # @param device [Device]
    # @return [Boolean]
    def used?(device)
      dev = devices.detect { |v| v == device }
      return false unless dev
      !dev.inherited?
    end

    def each(&block)
      devices.each(&block)
    end

    def detect(&block)
      devices.detect(&block)
    end

    def select(&block)
      devices.select(&block)
    end

    # Export devices to clients
    # @return [Array<Hash>]
    def export
      devices.map { |dev| dev.export }
    end

    # Dump device configuration into the config
    # @return [Array<Hash>]
    def dump
      devices.reject(&:inherited?).map { |dev| dev.dump }
    end

    def dup(new_owner)
      ret = super()
      ret.instance_variable_set('@owner', new_owner)
      ret.instance_variable_set('@devices', devices.map(&:clone))
      ret
    end

    protected
    attr_reader :owner, :devices

    def clear
      return if @cleared

      do_deny_all
      @cleared = true
    end

    def do_deny_all
      CGroup.set_param(
        File.join(owner.abs_cgroup_path('devices'), 'devices.deny'),
        ['a']
      )
    end

    def do_deny_dev(device)
      CGroup.set_param(
        File.join(owner.abs_cgroup_path('devices'), 'devices.deny'),
        [device.to_s]
      )
    end

    def do_allow_dev(device)
      CGroup.set_param(
        File.join(owner.abs_cgroup_path('devices'), 'devices.allow'),
        [device.to_s]
      )
    end

    # @param changes [Hash<Symbol, String>]
    # @param path [String, nil]
    def do_apply_changes(changes, path: nil)
      path ||= owner.abs_cgroup_path('devices')

      changes.each do |action, value|
        case action
        when :allow
          CGroup.set_param(
            File.join(path, 'devices.allow'),
            [value]
          )

        when :deny
          CGroup.set_param(
            File.join(path, 'devices.deny'),
            [value]
          )
        end
      end
    end

    def do_add(device)
      devices << device
    end
  end
end
