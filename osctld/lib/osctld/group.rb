module OsCtld
  class Group
    include Lockable
    include Assets::Definition

    attr_reader :pool, :name, :path, :cgparams, :devices

    def initialize(pool, name, load: true, config: nil, devices: true, root: false)
      init_lock
      @pool = pool
      @name = name
      @root = root
      @cgparams = nil
      @devices = nil
      load_config(config) if load
      devices.init if load && devices
    end

    def id
      @name
    end

    def root?
      @root
    end

    def configure(path, cgparams = [], devices: true)
      @path = path
      @cgparams = CGroup::Params.new(self)
      @cgparams.set(cgparams, save: false)
      @devices = Devices::GroupManager.new(self)
      @devices.init if devices
      save_config
    end

    def assets
      define_assets do |add|
        add.file(
          config_path,
          desc: "osctld's group config",
          user: 0,
          group: 0,
          mode: 0400
        )

        users.each do |u|
          add.directory(
            userdir(u),
            desc: "LXC path for #{u.name}/#{name}",
            user: 0,
            group: u.ugid,
            mode: 0751
          )
        end
      end
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

    # Return all parent groups, from the root group to the closest parent
    # @return [Array<Group>]
    def parents
      return [] if root?

      ret = [DB::Groups.root(pool)]
      t = ''

      path.split('/').each do |name|
        t = File.join(t, name)
        t = t[1..-1] if t.start_with?('/')

        g = DB::Groups.by_path(pool, t)
        next if g.nil? || g.root?
        return ret if g == self

        ret << g
      end

      ret
    end

    # Return the closest parent group
    # @return [Group, nil]
    def parent
      return if root?
      parents.last
    end

    # Return all groups leading to this group's path, i.e. all parents and
    # the group itself.
    # @return [Array<Group>]
    def groups_in_path
      parents + [self]
    end

    # Return all groups below the current group's path
    # @return [Array<Group>]
    def descendants
      groups = DB::Groups.get.select { |grp| grp.pool == pool }

      if root?
        groups.drop(1) # remove the root group, which is first

      else
        groups.select { |grp| grp.path.start_with?("#{path}/") }
      end.sort! { |a, b| a.path <=> b.path }
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

    def save_config
      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump({
          'path' => path,
          'cgparams' => cgparams.dump,
          'devices' => devices.dump,
        }))
      end

      File.chown(0, 0, config_path)
    end

    protected
    def load_config(config = nil)
      if config
        cfg = YAML.load(config)
      else
        cfg = YAML.load_file(config_path)
      end

      @path = cfg['path']
      @cgparams = CGroup::Params.load(self, cfg['cgparams'])
      @devices = Devices::GroupManager.load(self, cfg['devices'] || [])
    end
  end
end
