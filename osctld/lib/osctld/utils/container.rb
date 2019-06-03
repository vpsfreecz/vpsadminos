require 'zlib'

module OsCtld
  module Utils::Container
    # @param pool [Pool]
    # @return [Array<Repository>]
    def get_repositories(pool)
      if opts[:repository]
        repo = DB::Repositories.find(opts[:repository], pool)
        error!('repository not found') unless repo
        [repo]

      else
        DB::Repositories.get.select do |repo|
          repo.enabled? && repo.pool == pool
        end
      end
    end

    # @param repos [Array<Repository>]
    # @param tpl [Hash]
    # @option tpl [String] :distribution
    # @option tpl [String] :version
    # @option tpl [String] :arch
    # @option tpl [String] :vendor
    # @option tpl [String] :variant
    # @return [String, nil]
    def get_template_path(repos, tpl)
      repos.each do |repo|
        osctl_repo = OsCtlRepo.new(repo)

        begin
          %i(zfs tar).each do |format|
            path = osctl_repo.get_template_path(tpl, format)
            return path if path
          end
        rescue TemplateNotFound, TemplateRepositoryUnavailable
          next
        end
      end

      nil
    end
  end
end
