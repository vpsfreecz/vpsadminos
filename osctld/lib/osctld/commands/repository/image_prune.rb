require 'osctld/commands/base'

module OsCtld
  class Commands::Repository::ImagePrune < Commands::Base
    handle :repo_image_prune

    def execute
      repositories.each do |repo|
        status, files = repo.prune_images(older_than_days: opts[:older_than_days])
        error!("failed to prune repository #{repo.ident}") unless status

        files.each do |file|
          progress("Deleted #{file}")
        end
      end

      ok
    end

    protected

    def repositories
      if opts[:repositories]&.any?
        opts[:repositories].map do |name|
          DB::Repositories.find(name, opts[:pool]) || error!("repository #{name} not found")
        end
      elsif opts[:pool]
        DB::Repositories.get.select { |repo| repo.pool.name == opts[:pool] }
      else
        DB::Repositories.get
      end
    end
  end
end
