module OsCtld
  SystemCommandFailed = OsCtl::Lib::Exceptions::SystemCommandFailed

  class CommandFailed < StandardError ; end
  class GroupNotFound < StandardError ; end
  class CGroupSubsystemNotFound < StandardError ; end
  class CGroupParameterNotFound < StandardError ; end

  class CGroupFileNotFound < StandardError
    def initialize(path, value)
      super("Unable to set #{path}=#{value}: parameter not found")
    end
  end

  class TemplateNotFound < StandardError ; end
  class TemplateRepositoryUnavailable < StandardError ; end

  class DeviceNotAvailable < StandardError
    def initialize(dev, grp)
      super("device '#{dev}' not available in group '#{grp.name}'")
    end
  end

  class DeviceModeInsufficient < StandardError
    def initialize(dev, grp, mode)
      super("group '#{grp.name}' provides only mode '#{mode}' for device '#{dev}'")
    end
  end

  class DeviceDescendantRequiresMode < StandardError
    # @param entity [Group, Container]
    # @param mode [Devices::Device::Mode]
    def initialize(entity, mode)
      if entity.is_a?(Group)
        super("child group '#{entity.name}' requires broader device access mode '#{mode}'")

      elsif entity.is_a?(Container)
        super("container '#{entity.id}' requires broader device access mode '#{mode}'")
      end
    end
  end

  class DeviceInUse < StandardError ; end

  class MountNotFound < StandardError ; end

  class MountInvalid < StandardError ; end

  class UnmountError < StandardError ; end

  class HookFailed < StandardError
    # @param hook [Container::Hook::Base]
    # @param exitstatus [Integer]
    def initialize(hook, exitstatus)
      super("hook #{hook.class.hook_name} at #{hook.hook_path} exited with #{exitstatus}")
    end
  end

  class IdMappingError < StandardError
    # @param idmap [IdMap]
    # @param id [Integer]
    def initialize(idmap, id)
      super("unable to map id #{id} using #{idmap.to_s}")
    end
  end
end
