module OsCtld
  module Utils::Devices
    def list(groupable, opts)
      ok(groupable.devices.export)
    end

    # @param entity [Group, Container]
    def add(entity)
      dev = Devices::Device.import(opts)
      error!('device already exists') if entity.devices.include?(dev)
      check_mode!

      Devices::Lock.sync(entity.pool) do
        if !opts[:parents]
          entity.devices.check_availability!(dev)
        end

        entity.devices.add(dev)
        entity.save_config
      end

      ok

    rescue DeviceNotAvailable, DeviceModeInsufficient => e
      error(e.message)
    end

    # @param entity [Group, Container]
    def chmod(entity)
      dev = entity.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
      error!('device not found') unless dev
      check_mode! unless opts[:mode].empty?

      new_mode = Devices::Mode.new(opts[:mode])

      Devices::Lock.sync(entity.pool) do
        # Check parents for device & mode
        if !opts[:parents]
          entity.devices.check_availability!(dev, mode: new_mode)
        end

        # Check if descendants do not require broader access mode
        if !opts[:recursive]
          entity.devices.check_descendants!(dev, mode: new_mode)
        end

        entity.devices.chmod(
          dev,
          new_mode,
          promote: true,
          parents: opts[:parents],
          descendants: opts[:recursive],
          containers: opts[:recursive]
        )
      end

      ok

    rescue DeviceModeInsufficient, DeviceDescendantRequiresMode => e
      error(e.message)
    end

    def promote(entity)
      dev = entity.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
      error!('device not found') unless dev
      error!('device is already promoted') unless dev.inherited?

      Devices::Lock.sync(entity.pool) do
        entity.devices.promote(dev)
      end

      ok
    end

    def inherit(entity)
      dev = entity.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
      error!('device not found') unless dev
      error!('device is already inherited') if dev.inherited?

      Devices::Lock.sync(entity.pool) do
        entity.devices.inherit_promoted(dev)
      end

      ok

    rescue DeviceInUse => e
      error(e.message)
    end

    def set_inherit(entity)
      dev = entity.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
      error!('device not found') unless dev
      error!('inherit is already set') if dev.inherit?
      error!('only promoted devices can be manipulated') if dev.inherited?

      Devices::Lock.sync(entity.pool) do
        entity.devices.set_inherit(dev)
      end

      ok
    end

    def unset_inherit(entity)
      dev = entity.devices.find(opts[:type].to_sym, opts[:major], opts[:minor])
      error!('device not found') unless dev
      error!('inherit is not set') unless dev.inherit?
      error!('only promoted devices can be manipulated') if dev.inherited?

      Devices::Lock.sync(entity.pool) do
        entity.devices.unset_inherit(dev)
      end

      ok

    rescue DeviceInUse => e
      error(e.message)
    end

    def replace(entity)
      devices = opts[:devices].map { |v| Devices::Device.import(v) }

      Devices::Lock.sync(entity.pool) do
        entity.devices.replace(devices)
      end

      ok

    rescue DeviceNotAvailable, DeviceModeInsufficient => e
      error(e.message)
    end

    protected
    def check_mode!
      if /^[rwm]{1,3}$/ !~ opts[:mode] || /(.)\1+/ =~ opts[:mode]
        error!(
          'invalid mode, allowed characters are: r for read, w for write, '+
          'm for mknod'
        )
      end
    end
  end
end
