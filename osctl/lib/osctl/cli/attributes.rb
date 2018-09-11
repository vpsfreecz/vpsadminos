module OsCtl
  module Cli::Attributes
    # @param cmd [Symbol] osctld command to use
    # @param opts [Hash] options for the osctld command
    # @param name [String] attribute name
    # @param value [String] attribute value
    def do_set_attr(cmd, opts, name, value)
      if /^[^:]+:.+$/ !~ name
        raise GLI::BadCommandLine,
              "attribute name is not in the required format '<vendor>:<key>'"
      end

      osctld_fmt(cmd, opts.merge(attrs: {name => value}))
    end

    # @param cmd [Symbol] osctld command to use
    # @param opts [Hash] options for the osctld command
    # @param name [String] attribute name
    def do_unset_attr(cmd, opts, name)
      osctld_fmt(cmd, opts.merge(attrs: [name]))
    end
  end
end
