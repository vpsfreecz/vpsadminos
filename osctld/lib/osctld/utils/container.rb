require 'zlib'

module OsCtld
  module Utils::Container
    def from_remote_template(builder, tpl)
      # TODO: this check is done too late -- the dataset has already been created
      #       and the repo may not exist
      if opts[:repository]
        repo = DB::Repositories.find(opts[:repository], builder.pool)
        error!('repository not found') unless repo
        repos = [repo]

      else
        repos = DB::Repositories.get.select do |repo|
          repo.enabled? && repo.pool == builder.pool
        end
      end

      # Rootfs (private/) has to be set up both before and after
      # template application. Before, to prepare the directory for tar -x,
      # after to ensure correct permission.
      builder.setup_rootfs

      repo = repos.detect do |repo|
        begin
          builder.from_repo_template(repo, tpl)

        rescue TemplateNotFound
          next

        rescue TemplateRepositoryUnavailable
          progress("Repository #{repo.name} is unreachable")
          next
        end

        true
      end

      error!('template not found') unless repo

      builder.setup_rootfs
    end
  end
end
