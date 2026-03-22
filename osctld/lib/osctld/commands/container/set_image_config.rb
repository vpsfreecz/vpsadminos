require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::SetImageConfig < Commands::Logged
    handle :ct_set_image_config

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        error!('container is running') if ct.running?

        tpl = opts[:image]
        image = {
          distribution: tpl[:distribution] || ct.distribution,
          version: tpl[:version] || ct.version,
          arch: tpl[:arch] || ct.arch,
          vendor: tpl[:vendor] || ct.vendor,
          variant: tpl[:variant] || ct.variant
        }

        if opts[:type] == 'image'
          tpl_path = opts[:path]
        elsif opts[:type] == 'remote'
          progress('Fetching image')
          tpl_path = get_image_path!(get_repositories(ct.pool), image)
        else
          error!('invalid type')
        end

        # Apply new image configuration
        progress('Applying configuration')
        fh = File.open(tpl_path, 'r')
        importer = Container::Importer.new(ct.pool, fh, ct_id: ct.id, image_file: tpl_path)
        importer.load_metadata
        ct.patch_config(importer.get_container_config)
        fh.close

        # If changed, update also distribution/version/arch info
        if tpl[:distribution] || tpl[:version] || tpl[:arch]
          ct.set(distribution: {
            name: image[:distribution],
            version: image[:version],
            arch: image[:arch],
            vendor: image[:vendor],
            variant: image[:variant]
          })
        end

        ok
      end
    end
  end
end
