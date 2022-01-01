require 'osctld/lockable'
require 'osctld/manipulable'
require 'osctld/assets/definition'

module OsCtld
  class Group
    include Lockable
    include Manipulable
    include Assets::Definition

    attr_reader :pool, :name, :cgparams, :devices, :attrs

    def initialize(pool, name, load: true, config: nil, devices: true, root: false)
      init_lock
      init_manipulable
      @pool = pool
      @name = name
      @root = root
      @cgparams = nil
      @devices = nil
      @attrs = Attributes.new
      load_config(config) if load
      devices.init if load && devices
    end

    def id
      @name
    end

    def root?
      @root
    end

    def path
      root? ? @path : File.join(DB::Groups.root(pool).path, name)
    end

    def configure(path: nil, devices: true)
      @path = path if root?
      @cgparams = CGroup::Params.new(self)
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
            desc: "LXC path for #{u.name}:#{name}",
            user: 0,
            group: u.ugid,
            mode: 0751
          )
        end
      end
    end

    # @param opts [Hash]
    # @option opts [Hash] :attrs
    def set(opts)
      opts.each do |k, v|
        case k
        when :attrs
          attrs.update(v)

        else
          fail "unsupported option '#{k}'"
        end
      end

      save_config
    end

    # @param opts [Hash]
    # @option opts [Array<String>] :attrs
    def unset(opts)
      opts.each do |k, v|
        case k
        when :attrs
          v.each { |attr| attrs.unset(attr) }

        else
          fail "unsupported option '#{k}'"
        end
      end

      save_config
    end

    def config_dir
      File.join(pool.conf_path, 'group', id)
    end

    def config_path
      File.join(pool.conf_path, 'group', id, 'config.yml')
    end

    def cgroup_path
      if root?
        path

      else
        File.join(
          DB::Groups.root(pool).path,
          *name.split('/').drop(1).map { |v| "group.#{v}" }
        )
      end
    end

    def full_cgroup_path(user)
      File.join(cgroup_path, "user.#{user.name}")
    end

    def abs_cgroup_path(subsystem)
      CGroup.abs_cgroup_path(subsystem, cgroup_path)
    end

    def abs_full_cgroup_path(subsystem, user)
      CGroup.abs_cgroup_path(subsystem, full_cgroup_path(user))
    end

    def userdir(user)
      File.join(
        user.userdir,
        *name.split('/').drop(1).map { |v| "group.#{v}" },
        'cts'
      )
    end

    def setup_for?(user)
      Dir.exist?(userdir(user))
    end

    # Return all parent groups, from the root group to the closest parent
    # @return [Array<Group>]
    def parents
      return [] if root?

      ret = []
      t = ''

      name.split('/')[0..-2].each do |n|
        t = File.join('/', t, n)

        g = DB::Groups.by_path(pool, t)
        raise GroupNotFound, "group '#{t}' not found" if g.nil?

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

    # Return all groups that are direct descendants
    # @return [Array<Group>]
    def children
      DB::Groups.get.select do |grp|
        next if grp.pool != pool || grp.name == name

        if root?
          s = '/'
        else
          s = "#{name}/"
        end

        grp.name.start_with?(s) && grp.name[s.size..-1].index('/').nil?

      end.sort! { |a, b| a.name <=> b.name }
    end

    # Return all groups below the current group's path
    # @return [Array<Group>]
    def descendants
      groups = DB::Groups.get.select { |grp| grp.pool == pool }

      if root?
        groups.drop(1) # remove the root group, which is first

      else
        groups.select { |grp| grp.name.start_with?("#{name}/") }
      end.sort! { |a, b| a.name <=> b.name }
    end

    # @param user [User, nil]
    def has_containers?(user = nil)
      ct = DB::Containers.get.detect do |ct|
        ct.pool.name == pool.name \
          && ct.group.name == name \
          && (user.nil? || ct.user.name == user.name)
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

    # Return `true` if any container from this or any descendant group is
    # running.
    def any_container_running?
      groups = [self] + descendants

      DB::Containers.get.each do |ct|
        return true if ct.pool == pool && groups.include?(self) && ct.running?
      end

      false
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

    def manipulation_resource
      ['group', "#{pool.name}:#{name}"]
    end

    def save_config
      Dir.mkdir(config_dir) unless Dir.exist?(config_dir)

      cfg = {
        'cgparams' => cgparams.dump,
        'devices' => devices.dump,
        'attrs' => attrs.dump,
      }

      cfg['path'] = path if root?

      File.open(config_path, 'w', 0400) do |f|
        f.write(YAML.dump(cfg))
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

      @path = cfg['path'] if root?
      @cgparams = CGroup::Params.load(self, cfg['cgparams'])
      @devices = Devices::GroupManager.load(self, cfg['devices'] || [])
      @attrs = Attributes.load(cfg['attrs'] || {})
    end
  end
end
