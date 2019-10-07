require 'osctl/exportfs/cli/command'

module OsCtl::ExportFS::Cli
  class Export < Command
    def list
      servers.each do |s|
        cfg = s.open_config
        cfg.exports.each do |ex|
          puts "server  = #{s.name}"
          puts "dir     = #{ex.dir}"
          puts "as      = #{ex.as}"
          puts "host    = #{ex.host}"
          puts "options = #{ex.options}"
          puts
        end
      end
    end

    def add
      require_args!('server')

      ex = OsCtl::ExportFS::Export.new(
        dir: opts[:directory],
        as: opts[:as],
        host: opts[:host],
        options: opts[:options],
      )

      OsCtl::ExportFS::Operations::Export::Add.run(
        OsCtl::ExportFS::Server.new(args[0]),
        ex
      )
    end

    def remove
      require_args!('server')

      OsCtl::ExportFS::Operations::Export::Remove.run(
        OsCtl::ExportFS::Server.new(args[0]),
        opts[:as],
        opts[:host],
      )
    end

    protected
    def servers
      if args[0]
        [OsCtl::ExportFS::Server.new(args[0])]
      else
        OsCtl::ExportFS::Operations::Server::List.run
      end
    end
  end
end
