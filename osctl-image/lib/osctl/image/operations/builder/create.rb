require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'

module OsCtl::Image
  class Operations::Builder::Create < Operations::Base
    # @return [Builder]
    attr_reader :builder

    # @return [String]
    attr_reader :base_dir

    # @return [String, nil]
    attr_reader :vpsadminos_dir

    # @return [String]
    attr_reader :setup_id

    def initialize(builder, base_dir, vpsadminos_dir: nil)
      super()
      @builder = builder
      @base_dir = base_dir
      @vpsadminos_dir = vpsadminos_dir
      @setup_id = SecureRandom.hex(4)
    end

    def execute
      client = OsCtldClient.new
      client.batch do
        client.create_container_from_repo(
          builder.ctid,
          builder.distribution,
          builder.version,
          builder.arch,
          builder.vendor,
          builder.variant
        )

        # When the command above returns, the CT is still in an unknown state,
        # so network interfaces cannot be added... this should be fixed
        # in osctld, so that it returns after the ct is in a correct state
        sleep(3)

        client.set_container_attr(
          builder.ctid,
          'org.vpsadminos.osctl-image:type',
          'builder'
        )

        client.set_container_attr(
          builder.ctid,
          'org.vpsadminos.osctl-image:builder-name',
          builder.name
        )

        client.set_container_nesting(builder.ctid)
        client.unset_container_start_menu(builder.ctid)

        client.add_netif_bridge(builder.ctid, 'eth0', 'lxcbr0')
        client.set_container_dns_resolvers(builder.ctid, [
                                             '1.1.1.1',
                                             '8.8.8.8'
                                           ])

        client.start_container(builder.ctid)

        # Give the container some time to start
        sleep(5)

        builder.load_attrs(client)

        client.bind_mount(builder.ctid, base_dir, builder_base_dir, map_ids: false)
        client.activate_mount(builder.ctid, builder_base_dir)

        if vpsadminos_dir
          client.bind_mount(
            builder.ctid,
            vpsadminos_dir,
            builder_vpsadminos_dir,
            map_ids: false
          )
          client.activate_mount(builder.ctid, builder_vpsadminos_dir)
        end

        Operations::Builder::WaitForNetwork.run(builder)

        rc = Operations::Builder::ControlledExec.run(
          builder,
          [
            File.join(builder_base_dir, 'bin', 'runner'),
            'builder',
            'setup',
            builder.name
          ],
          id: setup_id,
          client:,
          env: build_environment
        )

        client.unmount(builder.ctid, builder_vpsadminos_dir) if vpsadminos_dir
        client.unmount(builder.ctid, builder_base_dir)

        if rc != 0
          raise OperationError,
                "builder setup failed with exit status #{rc}"
        end
      rescue OsCtl::Client::Error,
             OperationError => e
        puts "* error occurred: #{e.message}, cleaning up"

        if client.find_container(builder.ctid)
          client.delete_container(builder.ctid)
        end

        raise e
      end
    end

    protected

    def builder_base_dir
      "/build/basedir.#{setup_id}"
    end

    def builder_vpsadminos_dir
      "/build/vpsadminos.#{setup_id}"
    end

    def build_environment
      return {} unless vpsadminos_dir

      { 'OSCTL_IMAGE_VPSADMINOS_DIR' => builder_vpsadminos_dir }
    end
  end
end
