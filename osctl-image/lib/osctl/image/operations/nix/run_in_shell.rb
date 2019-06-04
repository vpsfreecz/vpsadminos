require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Nix::RunInShell < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [String]
    attr_reader :expression

    # @return [Array<String>]
    attr_reader :command

    # @param expression [String] nix file
    # @param command [Array<String>]
    # @param opts [Hash] see {OsCtl::Lib::Utils::System#syscmd}
    # @option opts [String] :name temporary executable name
    # @option opts [String] :expression nix file
    def initialize(expression, command, opts = {})
      @expression = expression
      @command = command
      @name = opts.delete(:name) || 'nix-shell-run'
      @opts = opts
    end

    # @return [OsCtl::Lib::SystemCommandResult]
    # @raise [OsCtl::Lib::SystemCommandError]
    def execute
      exe = create_executable
      syscmd("nix-shell --run #{exe.path} #{expression}", opts)
    ensure
      exe.unlink
    end

    protected
    attr_reader :name, :expression, :opts

    def create_executable
      tmp = Tempfile.new(name, '/tmp')
      tmp.write(<<EOF
#!/bin/sh
exec #{command.join(' ')}
EOF
)
      tmp.close
      File.chmod(0700, tmp.path)
      tmp
    end
  end
end
