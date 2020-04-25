require 'osctl'

module OsCtl::Image
  class OsCtldClient
    def initialize
      @client = OsCtl::Client.new
      @connected = false
    end

    # Execute multiple commands within one connection
    def batch
      @batch = true
      yield(self)
    ensure
      @batch = false
    end

    def ignore_error
      yield(self)
    rescue OsCtl::Client::Error
    end

    # @return [Array]
    def list_containers
      connect do |client|
        client.cmd_data!(:ct_list)
      end
    end

    # @param ctid [String]
    def find_container(ctid)
      connect do |client|
        client.cmd_data!(:ct_show, id: ctid)
      end
    rescue OsCtl::Client::Error
      nil
    end

    # @param ctid [String]
    # @param distribution [String]
    # @param version [String]
    # @param arch [String]
    # @param vendor [String]
    # @param variant [String]
    def create_container_from_repo(ctid, distribution, version, arch, vendor, variant)
      connect do |client|
        client.cmd_data!(
          :ct_create,
          id: ctid,
          image: {
            distribution: distribution,
            version: version,
            arch: arch,
            vendor: vendor,
            variant: variant,
          },
        )
      end
    end

    # @param ctid [String]
    # @param file [String]
    def create_container_from_file(ctid, file)
      connect do |client|
        client.cmd_data!(
          :ct_import,
          as_id: ctid,
          file: File.absolute_path(file),
        )
      end
    end

    # @param ctid [String]
    # @param image_path [String]
    # @param remove_snapshots [Boolean]
    def reinstall_container_from_image(ctid, image_path, remove_snapshots: false)
      connect do |client|
        client.cmd_data!(
          :ct_reinstall,
          id: ctid,
          remove_snapshots: remove_snapshots,
          type: :image,
          path: File.absolute_path(image_path),
        )
      end
    end

    # @param ctid [String]
    # @param attr [String]
    # @param value [String]
    def set_container_attr(ctid, attr, value)
      connect do |client|
        client.cmd_data!(:ct_set, id: ctid, attrs: {attr => value})
      end
    end

    # @param ctid [String]
    def start_container(ctid)
      connect do |client|
        client.cmd_data!(:ct_start, id: ctid)
      end
    end

    # @param ctid [String]
    def stop_container(ctid)
      connect do |client|
        client.cmd_data!(:ct_stop, id: ctid)
      end
    end

    # @param ctid [String]
    # @param cmd [Array<String>]
    def exec(ctid, cmd)
      connect do |client|
        cont = client.cmd_data!(
          :ct_exec,
          id: ctid,
          cmd: cmd,
          run: false,
        )

        if cont != 'continue'
          fail "exec not available: invalid response '#{cont}'"
        end

        null = File.open('/dev/null', 'r')

        client.send_io(null)
        client.send_io(STDOUT)
        client.send_io(STDOUT)

        null.close

        resp = client.receive_resp

        if resp.error?
          fail (resp['message'] || 'exec failed')
        end

        resp[:exitstatus]
      end
    end

    # @param ctid [String]
    # @param script [String]
    def runscript(ctid, script)
      connect do |client|
        cont = client.cmd_data!(
          :ct_runscript,
          id: ctid,
          script: script,
          run: false,
        )

        if cont != 'continue'
          fail "runscript not available: invalid response '#{cont}'"
        end

        null = File.open('/dev/null', 'r')

        client.send_io(null)
        client.send_io(STDOUT)
        client.send_io(STDOUT)

        null.close

        resp = client.receive_resp

        if resp.error?
          fail (resp['message'] || 'runscript failed')
        end

        resp[:exitstatus]
      end
    end

    # @param ctid [String]
    def delete_container(ctid)
      connect do |client|
        client.cmd_data!(:ct_delete, id: ctid, force: true)
      end
    end

    # @param ctid [String]
    def add_netif_bridge(ctid, netif, link)
      connect do |client|
        client.cmd_data!(
          :netif_create,
          id: ctid,
          name: netif,
          type: 'bridge',
          link: link,
          dhcp: true,
        )
      end
    end

    # @param ctid [String]
    # @param src [String]
    # @param dst [String]
    def bind_mount(ctid, src, dst)
      connect do |client|
        client.cmd_data!(
          :ct_mount_create,
          id: ctid,
          fs: src,
          mountpoint: dst,
          type: 'bind',
          opts: 'bind,create=dir',
          automount: false,
        )
      end
    end

    # @param ctid [String]
    # @param dst [String]
    def activate_mount(ctid, dst)
      connect do |client|
        client.cmd_data!(
          :ct_mount_activate,
          id: ctid,
          mountpoint: dst,
        )
      end
    end

    # @param ctid [String]
    # @param dst [String]
    def unmount(ctid, dst)
      connect do |client|
        client.cmd_data!(
          :ct_mount_delete,
          id: ctid,
          mountpoint: dst,
        )
      end
    end

    # @param user [String]
    # @return [Array]
    def user_idmap(user)
      connect do |client|
        client.cmd_data!(
          :user_idmap_list,
          name: user,
          uid: true,
          gid: true,
        )
      end
    end

    # @param user [String]
    def delete_user(user)
      connect do |client|
        client.cmd_data!(
          :user_delete,
          name: user,
        )
      end
    end

    protected
    # @yieldparam client [OsCtl::Client]
    def connect
      @client.open unless @connected
      @connected = true
      yield(@client)
    ensure
      unless @batch
        @client.close
        @connected = false
      end
    end
  end
end
