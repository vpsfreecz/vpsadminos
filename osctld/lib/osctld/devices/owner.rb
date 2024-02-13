module OsCtld
  # Virtual interface with methods that a device owner must implement
  class Devices::Owner
    # @return [Devices::Manager]
    def devices; end

    # @return [Pool]
    def pool; end

    # @return [String]
    def ident; end

    def save_config; end
  end
end
