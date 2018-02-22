module OsCtl::Repo::Cli
  class App
    include GLI::App

    def self.run
      cli = new
      cli.setup
      exit(cli.run(ARGV))
    end

    def setup
      Thread.abort_on_exception = true

      program_desc 'Create and use vpsAdminOS template repositories'
      version OsCtl::Repo::VERSION
      subcommand_option_handling :normal
      preserve_argv true
      arguments :strict

      desc 'Create a new empty repository in the current directory'
      command :init do |c|
        c.action &Command.run(Repo, :init)
      end

      desc 'Add file into the repository'
      arg_name '<vendor> <variant> <arch> <distribution> <version>'
      command :add do |c|
        c.desc 'Tag'
        c.flag :tag, must_match: %w(stable latest testing), multiple: true

        c.desc 'Rootfs archive'
        c.flag :archive

        c.desc 'Rootfs stream'
        c.flag :stream

        c.action &Command.run(Repo, :add)
      end

      desc "Set default vendor or default vendor's variant"
      arg_name '<vendor> [variant]'
      command :default do |c|
        c.action &Command.run(Repo, :set_default)
      end

      desc 'Fetch file from the repository and store it in a local cache'
      arg_name '<repo> <vendor> <variant> <arch> <distribution> <version>|<tag> tar|zfs'
      command :fetch do |c|
        c.desc 'Cache directory'
        c.flag :cache, required: true

        c.action &Command.run(Repo, :fetch)
      end

      desc 'Find a file within the repository and write its contents to stdout'
      arg_name '<repo> <vendor> <variant> <arch> <distribution> <version>|<tag> tar|zfs'
      command :get do |c|
        c.desc 'Cache directory'
        c.flag :cache

        c.action &Command.run(Repo, :get)
      end
    end
  end
end
