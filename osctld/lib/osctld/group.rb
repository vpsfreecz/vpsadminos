module OsCtld
  class Group
    include Lockable

    attr_reader :name, :path

    def initialize(name, load: true)
      init_lock
      @name = name
      load_config if load
    end

    def id
      @name
    end

    def configure(path)
      @path = path

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump({
          'path' => path,
        }))
      end

      File.chown(0, 0, config_path)
    end

    def config_path
      File.join('/', OsCtld::CONF_DS, 'group', "#{id}.yml")
    end

    def lxc_home(user)
      user.lxc_home(self)
    end

    def full_cgroup_path(user)
      File.join(GroupList.root.path, path, user.name)
    end

    def setup_for?(user)
      Dir.exist?(lxc_home(user))
    end

    def has_containers?
      ct = ContainerList.get.detect { |ct| ct.group.name == name }
      ct ? true : false
    end

    def users
      ret = []

      ContainerList.get.each do |ct|
        next if ct.group != self || ret.include?(ct.user)
        ret << ct.user
      end

      ret
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

      @path = cfg['path']
    end
  end
end
