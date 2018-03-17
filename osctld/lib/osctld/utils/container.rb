require 'zlib'

module OsCtld
  module Utils::Container
    def from_stream(builder)
      if opts[:template][:path]
        File.open(opts[:template][:path]) do |f|
          gz = Zlib::GzipReader.new(f)
          recv_stream(builder, gz)
          gz.close
        end

        builder.shift_dataset
        distribution, version, arch = builder.get_distribution_info(opts[:template][:path])

        builder.configure(
          opts[:distribution] || distribution,
          opts[:version] || version,
          opts[:arch] || arch
        )

      else
        client.send({status: true, response: 'continue'}.to_json + "\n", 0)
        recv_stream(builder, client.recv_io)

        builder.shift_dataset
        builder.configure(opts[:distribution], opts[:version], opts[:arch])
      end
    end

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
          builder.from_repo_template(repo, tpl[:template])

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

    def recv_stream(builder, io)
      builder.from_stream do |recv|
        recv.write(io.read(16*1024)) until io.eof?
      end
    end
  end
end
