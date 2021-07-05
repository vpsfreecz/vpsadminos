module OsCtld
  class Container::HookScript
    # Hook name
    # @return [Symbol]
    attr_reader :name

    # Absolute path to the script
    # @return [String]
    attr_reader :abs_path

    # Relative path to the script from the container's hook directory
    # @return [String]
    attr_reader :rel_path

    # Base file name
    # @return [String]
    attr_reader :base_name

    # @param abs_path [String]
    # @param rel_path [String]
    def initialize(name, abs_path, rel_path)
      @name = name
      @abs_path = abs_path
      @rel_path = rel_path
      @base_name = File.basename(rel_path)
    end
  end
end
