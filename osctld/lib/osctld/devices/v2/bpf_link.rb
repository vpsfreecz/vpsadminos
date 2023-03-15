require 'libosctl'

module OsCtld
  # Encapsulates BPF program link to a cgroup
  class Devices::V2::BpfLink
    # Create link instance from file name
    # @param pool_name [String]
    # @param name [String] link file name
    # @return [Devices::V2::BpfLink]
    def self.from_name(pool_name, name)
      if /\Adevcg\-([^\-]+)\-on\-([^\Z]+)\Z/ !~ name
        raise ArgumentError, "#{name}.inspect is not valid link name"
      end

      new($1, pool_name, OsCtl::Lib::StringEscape.unescape_path($2))
    end

    # @return [String]
    attr_reader :prog_name

    # @return [String]
    attr_reader :pool_name

    # @return [String]
    attr_reader :cgroup_path

    # @return [String]
    attr_reader :name

    # @param prog_name [String]
    # @param pool_name [String]
    # @param cgroup_path [String]
    def initialize(prog_name, pool_name, cgroup_path)
      @prog_name = prog_name
      @pool_name = pool_name
      @cgroup_path = cgroup_path
      @name = "devcg-#{prog_name}-on-#{OsCtl::Lib::StringEscape.escape_path(cgroup_path)}"
    end
  end
end
