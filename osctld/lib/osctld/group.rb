module OsCtld
  class Group
    include Lockable
    include CGroup::Params

    attr_reader :pool, :name, :path

    def initialize(pool, name, load: true, root: false)
      init_lock
      @pool = pool
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
      set_cgparams(cgparams, save: false)
      save_config
    end

    def config_path
      File.join(pool.conf_path, 'group', "#{id}.yml")
    end

    def cgroup_path
      if root?
        path

      else
        File.join(DB::Groups.root(pool).path, path)
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

    def has_containers?(user = nil)
      ct = DB::Containers.get.detect do |ct|
        ct.pool.name == pool.name && ct.group.name == name && (user.nil? || ct.user == user)
      end

      ct ? true : false
    end

    def containers
      ret = []

      DB::Containers.get.each do |ct|
        next if ct.pool != pool || ct.group != self || ret.include?(ct)
        ret << ct
      end

      ret
    end

    def users
      ret = []

      DB::Containers.get.each do |ct|
        next if ct.pool != pool || ct.group != self || ret.include?(ct.user)
        ret << ct.user
      end

      ret
    end

    def log_type
      "group=#{pool.name}:#{name}"
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
