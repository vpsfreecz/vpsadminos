require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::ImageList < Commands::Base
    handle :repo_image_list

    def execute
      repo = DB::Repositories.find(opts[:name], opts[:pool])
      error!('repository not found') unless repo

      osctl_repo = OsCtlRepo.new(repo)

      ok(osctl_repo.list_images.select(&method(:filter)).map(&:dump))
    end

    protected

    def filter(t)
      %i[vendor variant arch distribution version].each do |v|
        return false if opts[v] && opts[v] != t.send(v)
      end

      return false if opts[:tag] && !t.tags.include?(opts[:tag])
      return false if opts[:cached] === true && !t.cached?
      return false if opts[:cached] === false && t.cached?

      true
    end
  end
end
