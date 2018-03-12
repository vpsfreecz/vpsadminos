require 'fileutils'
require 'yaml'

module OsCtld
  class User
    include Lockable
    include Assets::Definition
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    attr_reader :pool, :name, :ugid, :offset, :size

    def initialize(pool, name, load: true, config: nil)
      init_lock
      @pool = pool
      @name = name
      load_config(config) if load
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

    def assets
      define_assets do |add|
        # Datasets
        add.dataset(dataset, desc: "User's home dataset")

        # Directories and files
        add.directory(
          userdir,
          desc: 'User directory',
          user: 0,
          group: ugid,
          mode: 0751
        )

        add.directory(
          homedir,
          desc: 'Home directory',
          user: ugid,
          group: ugid,
          mode: 0751
        )

        add.file(
          config_path,
          desc: "osctld's user config",
          user: 0,
          group: 0,
          mode: 0400
        )

        add.entry('/etc/passwd', desc: 'System user') do |asset|
          asset.validate do
            if /^#{Regexp.escape(sysusername)}:x:#{ugid}:#{ugid}:/ !~ File.read(asset.path)
              asset.add_error('entry missing or invalid')
            end
          end
        end

        add.entry('/etc/group', desc: 'System group') do |asset|
          asset.validate do
            if /^#{Regexp.escape(sysgroupname)}:x:#{ugid}:$/ !~ File.read(asset.path)
              asset.add_error('entry missing or invalid')
            end
          end
        end
      end
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
        syscmd("userdel -f #{sysusername}")
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

    def log_type
      "user=#{pool.name}:#{name}"
    end

    private
    def load_config(config)
      if config
        cfg = YAML.load(config)
      else
        cfg = YAML.load_file(config_path)
      end

      @ugid = cfg['ugid']
      @offset = cfg['offset']
      @size = cfg['size']
    end
  end
end
