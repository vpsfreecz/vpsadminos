module OsCtld
  class Mount::Manager
    include Lockable
    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    # Load mounts from config
    # @param ct [Container]
    # @param cfg [Array<Hash>]
    def self.load(ct, cfg)
      new(ct, entries: cfg.map { |v| Mount::Entry.load(ct, v) })
    end

    attr_reader :shared_dir

    # @param ct [Container]
    def initialize(ct, entries: [])
      init_lock
      @ct = ct
      @entries = entries
      @shared_dir = Mount::SharedDir.new(ct)
    end

    # @param mnt [Mount::Entry]
    def add(mnt)
      exclusively do
        entries << mnt
      end

      ct.save_config
      ct.configure_mounts

      return unless mnt.automount?

      ct.exclusively do
        next unless ct.current_state == :running
        shared_dir.propagate(mnt)
      end
    end

    # @param mnt [Mount::Entry]
    def <<(mnt)
      add(mnt)
    end

    # @param mountpoint [String]
    def find_at(mountpoint)
      inclusively do
        entries.detect { |m| m.mountpoint == mountpoint }
      end
    end

    # @param mountpoint [String]
    def delete_at(mountpoint)
      exclusively do
        mnt = entries.detect { |m| m.mountpoint == mountpoint }
        next unless mnt

        ct.exclusively do
          next unless ct.current_state == :running
          unmount(mnt)
        end

        entries.delete(mnt)
      end

      ct.save_config
      ct.configure_mounts
    end

    def each(&block)
      inclusively do
        entries.each(&block)
      end
    end

    include Enumerable

    # Dump mounts into config
    def dump
      map(&:dump)
    end

    # Return all mount entries, including internal entries
    # @return [Array<Mount::Entry>]
    def all_entries
      inclusively do
        [Mount::Entry.new(
          shared_dir.path,
          shared_dir.mountpoint,
          'none',
          'bind,create=dir,ro',
          true
        )] + entries.select(&:automount?)
      end
    end

    # Mount the directory inside the container
    #
    # WARNING: this method can mount the directory multiple times! It is the
    # caller's responsibility to ensure that the container is running.
    #
    # @param mountpoint [String]
    def activate(mountpoint)
      mnt = find_at(mountpoint)
      raise MountNotFound, mountpoint unless mnt

      shared_dir.propagate(mnt)
    end

    # Unmount the directory from the container
    # @param mountpoint [String]
    def deactivate(mountpoint)
      mnt = find_at(mountpoint)
      raise MountNotFound, mountpoint unless mnt

      unmount(mnt)
    end

    protected
    attr_reader :ct, :entries

    def unmount(mnt)
      ret = ct_control(ct, :unmount, id: ct.id, mountpoint: mnt.mountpoint)
      raise UnmountError unless ret[:status]
    end
  end
end
