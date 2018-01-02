module OsCtld
  class Group
    include Lockable
    include CGroup::Params

    attr_reader :name, :path

    def initialize(name, load: true, root: false)
      init_lock
      @name = name
      @root = root
      @cgparams = []
      load_config if load
    end

    def id
      @name
    end

    def root?
      @root
    end

    def configure(path, cgparams = [])
      @path = path
      set(cgparams, save: false)
      save_config
    end

    def config_path
      File.join('/', OsCtld::CONF_DS, 'group', "#{id}.yml")
    end

    def cgroup_path
      if root?
        path

      else
        File.join(DB::Groups.root.path, path)
      end
    end

    def full_cgroup_path(user)
      File.join(cgroup_path, user.name)
    end

    def abs_cgroup_path(subsystem)
      File.join(CGroup::FS, CGroup.real_subsystem(subsystem), cgroup_path)
    end

    def userdir(user)
      File.join(user.userdir, name)
    end

    def setup_for?(user)
      Dir.exist?(userdir(user))
    end

    def has_containers?
      ct = DB::Containers.get.detect { |ct| ct.group.name == name }
      ct ? true : false
    end

    def containers
      ret = []

      DB::Containers.get.each do |ct|
        next if ct.group != self || ret.include?(ct)
        ret << ct
      end

      ret
    end

    def users
      ret = []

      DB::Containers.get.each do |ct|
        next if ct.group != self || ret.include?(ct.user)
        ret << ct.user
      end

      ret
    end

    protected
    def load_config
      cfg = YAML.load_file(config_path)

      @path = cfg['path']
      @cgparams = load_cgparams(cfg['cgparams'])
    end

    def save_config
      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump({
          'path' => path,
          'cgparams' => dump_cgparams(cgparams),
        }))
      end

      File.chown(0, 0, config_path)
    end
  end
end
