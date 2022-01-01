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
    def get_image_path(repos, tpl)
      repos.each do |repo|
        osctl_repo = OsCtlRepo.new(repo)

        begin
          %i(zfs tar).each do |format|
            path = osctl_repo.get_image_path(tpl, format)
            return path if path
          end
        rescue ImageNotFound, ImageRepositoryUnavailable
          next
        end
      end

      nil
    end

    # Remove accounting cgroups to reset counters
    def remove_accounting_cgroups(ct)
      tries = 0

      begin
        %w(blkio cpuacct memory).each do |subsys|
          CGroup.rmpath(subsys, ct.base_cgroup_path)
        end
      rescue SystemCallError => e
        ct.log(:warn, "Error occurred while pruning cgroups: #{e.message}")

        return if tries >= 5
        tries += 1
        sleep(0.5)
        retry
      end
    end
  end
end
