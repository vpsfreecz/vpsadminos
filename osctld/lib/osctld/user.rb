require 'fileutils'
require 'yaml'

module OsCtld
  class User
    include Lockable
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    attr_reader :pool, :name, :ugid, :offset, :size

    def initialize(pool, name, load: true)
      init_lock
      @pool = pool
      @name = name
      load_config if load
    end

    def id
      @name
    end

    def delete
      unregister
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
        @registered = syscmd("id #{sysusername}", valid_rcs: [1])[:exitstatus] == 0
      end
    end

    def register
      exclusively do
        syscmd("groupadd -g #{ugid} #{sysgroupname}")
        syscmd("useradd -u #{ugid} -g #{ugid} -d #{homedir} #{sysusername}")
        @registered = true
      end
    end

    def unregister
      exclusively do
        syscmd("userdel #{sysusername}")
        @registered = false
      end
    end

    def sysusername
      "uns#{name}"
    end

    def sysgroupname
      sysusername
    end

    def dataset
      File.join(pool.user_ds, name)
    end

    def userdir
      "/#{dataset}"
    end

    def homedir
      File.join(userdir, '.home')
    end

    def config_path
      File.join(pool.conf_path, 'user', "#{name}.yml")
    end

    def has_containers?
      ct = DB::Containers.get.detect { |ct| ct.user.name == name }
      ct ? true : false
    end

    def containers
      DB::Containers.get { |cts| cts.select { |ct| ct.user == self } }
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
