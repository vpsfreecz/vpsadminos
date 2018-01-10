module OsCtld
  class DB::Groups < DB::PooledList
    class << self
      %i(setup root default by_path).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    def initialize(*_)
      super
      @index = {}
    end

    # Ensures presence of root and default groups
    def setup(pool)
      root, created = load_or_create(pool, 'root', 'osctl')

      if created
        root.set_cgparams(root.import_cgparams([
          {
            subsystem: 'devices',
            parameter: 'devices.deny',
            value: ['a'],
          },
          {
            subsystem: 'devices',
            parameter: 'devices.allow',
            value: [
              'c 1:3 rwm',    # /dev/null
              'c 1:5 rwm',    # /dev/zero
              'c 1:7 rwm',    # /dev/full
              'c 1:8 rwm',    # /dev/random
              'c 1:9 rwm',    # /dev/urandom
              'c 5:0 rwm',    # /dev/tty
              'c 5:1 rwm',    # /dev/console
              'c 5:2 rwm',    # /dev/ptmx
              'c 10:229 rwm', # /dev/fuse
              'c 136:* rwm',  # /dev/tty*, /dev/console
            ],
          },
        ]))
      end

      # The devices in the root group have to be configured as soon as possible,
      # because `echo a > devices.deny` will not work when the root cgroup has
      # any children.
      CGroup.mkpath('devices', root.path.split('/'))
      Commands::Group::CGParamApply.run(name: root.name)

      load_or_create(pool, 'default', 'default')
    end

    def root(pool)
      find('root', pool)
    end

    def default(pool)
      find('default', pool)
    end

    def add(grp)
      sync do
        super
        @index[grp.pool.name] ||= {}
        @index[grp.pool.name][grp.path] = grp
      end
    end

    def remove(grp)
      sync do
        super
        @index[grp.pool.name].delete(grp.path)
        @index.delete(grp.pool.name) if @index[grp.pool.name].empty?
        grp
      end
    end

    def by_path(pool, path)
      sync do
        next nil unless @index.has_key?(pool.name)
        @index[pool.name][path]
      end
    end

    protected
    def load_or_create(pool, name, path)
      grp = nil
      root = name == 'root'
      created = false

      begin
        grp = Group.new(pool, name, root: root)

      rescue Errno::ENOENT
        grp = Group.new(pool, name, load: false, root: root)
        grp.configure(path)
        created = true
      end

      add(grp)
      [grp, created]
    end
  end
end
