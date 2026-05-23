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
    # @return [Array<String, Hash<String, String>>]
    def get_image_path(repos, tpl)
      unavailable = {}

      repos.each do |repo|
        osctl_repo = OsCtlRepo.new(repo)

        begin
          %i[zfs tar].each do |format|
            path = osctl_repo.get_image_path(tpl, format)
            return [path, unavailable] if path
          end
        rescue ImageNotFound
          next
        rescue ImageRepositoryUnavailable => e
          unavailable[repo.name] = e.message
          next
        end
      end

      [nil, unavailable]
    end

    # @param repos [Array<Repository>]
    # @param tpl [Hash]
    # @return [String]
    def get_image_path!(repos, tpl)
      if repos.empty?
        error!('no enabled repositories are available for container images')
      end

      path, unavailable = get_image_path(repos, tpl)
      return path if path

      if unavailable.any?
        error!(image_unavailable_message(tpl, unavailable))
      end

      error!(image_not_found_message(tpl, repos))
    end

    def with_repository_image_path!(repos, tpl)
      if repos.empty?
        error!('no enabled repositories are available for container images')
      end

      unavailable = {}

      repos.each do |repo|
        osctl_repo = OsCtlRepo.new(repo)

        begin
          repo.with_cache_lock do
            %i[zfs tar].each do |format|
              path = osctl_repo.get_image_path(tpl, format)
              return yield(path) if path
            end
          end
        rescue ImageNotFound
          next
        rescue ImageRepositoryUnavailable => e
          unavailable[repo.name] = e.message
          next
        end
      end

      if unavailable.any?
        error!(image_unavailable_message(tpl, unavailable))
      end

      error!(image_not_found_message(tpl, repos))
    end

    def with_image_path(pool, type:, path:, image:, &block)
      case type
      when 'image'
        block.call(path)
      when 'remote'
        progress('Fetching image')
        with_repository_image_path!(get_repositories(pool), image) { |tpl_path| block.call(tpl_path) }
      else
        error!('invalid type')
      end
    end

    def image_not_found_message(tpl, repos)
      "container image #{image_spec(tpl)} not found in repositories: " \
        "#{repos.map(&:name).join(', ')}"
    end

    def image_unavailable_message(tpl, unavailable)
      "unable to fetch container image #{image_spec(tpl)}; repositories " \
        "unavailable: #{format_unavailable_repositories(unavailable)}"
    end

    def format_unavailable_repositories(unavailable)
      unavailable.map do |name, message|
        if message && !message.empty?
          "#{name} (#{message})"
        else
          name
        end
      end.join(', ')
    end

    def image_spec(tpl)
      "#{tpl[:distribution]}:#{tpl[:version]} " \
        "(arch=#{tpl[:arch]}, vendor=#{tpl[:vendor]}, " \
        "variant=#{tpl[:variant]})"
    end

    # Remove accounting cgroups to reset counters
    def remove_accounting_cgroups(ct)
      tries = 0

      begin
        %w[cpuacct cpuset memory].each do |subsys|
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
