require 'fileutils'
require 'yaml'

module OsCtld
  class User
    include Lockable
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    attr_reader :name, :ugid, :offset, :size

    def initialize(name, load: true)
      init_lock
      @name = name
      load_config if load
    end

    def id
      @name
    end

    def delete
      unregister
      zfs(:destroy, nil, ct_dataset)
      zfs(:destroy, nil, dataset)
    end

    def configure(ugid, offset, size)
      @ugid = ugid
      @offset = offset
      @size = size

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump({
          'ugid' => ugid,
          'offset' => offset,
          'size' => size,
        }))
      end

      File.chown(0, 0, config_path)
    end

    def registered?
      exclusively do
        next @registered unless @registered.nil?
        @registered = syscmd("id #{username}", valid_rcs: [1])[:exitstatus] == 0
      end
    end

    def register
      exclusively do
        syscmd("groupadd -g #{ugid} #{groupname}")
        syscmd("useradd -u #{ugid} -g #{ugid} -d #{homedir} #{username}")
        @registered = true
      end
    end

    def unregister
      exclusively do
        syscmd("userdel #{groupname}")
        @registered = false
      end
    end

    def username
      "uns#{name}"
    end

    def groupname
      username
    end

    def dataset
      user_ds(name)
    end

    def ct_dataset
      user_ct_ds(name)
    end

    def userdir
      user_dir(name)
    end

    def homedir
      File.join(userdir, '.home')
    end

    def lxc_home
      File.join(userdir, 'ct')
    end

    def config_path
      "#{userdir}/user.yml"
    end

    def has_containers?
      ct = ContainerList.get.detect { |ct| ct.user.name == name }
      ct ? true : false
    end

    def containers
      ContainerList.get { |cts| cts.select { |ct| ct.user == self } }
    end

    private
    def load_config
      cfg = YAML.load_file(config_path)

      @ugid = cfg['ugid']
      @offset = cfg['offset']
      @size = cfg['size']
    end
  end
end
