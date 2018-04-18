module OsCtld
  class Mount::Manager
    include Lockable

    # Load mounts from config
    # @param ct [Container]
    # @param cfg [Array<Hash>]
    def self.load(ct, cfg)
      manager = new(ct)
      cfg.each { |v| manager << Mount::Entry.load(ct, v) }
      manager
    end

    # @param ct [Container]
    def initialize(ct)
      init_lock
      @ct = ct
      @entries = []
    end

    # @param mnt [Mount::Entry]
    def add(mnt)
      exclusively do
        entries << mnt
      end

      ct.save_config
      ct.configure_mounts
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

    protected
    attr_reader :ct, :entries
  end
end
