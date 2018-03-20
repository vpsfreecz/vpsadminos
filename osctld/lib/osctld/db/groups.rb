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
      root, created = load_or_create(
        pool,
        'root',
        File.join('osctl', "pool.#{pool.name}")
      )

      if created
        root.devices.init

        root.devices.add_new(
          :char, 1, 3, 'rwm',
          name: '/dev/null',
          inherit: true,
        )
        root.devices.add_new(
          :char, 1, 5, 'rwm',
          name: '/dev/zero',
          inherit: true,
        )
        root.devices.add_new(
          :char, 1, 7, 'rwm',
          name: '/dev/full',
          inherit: true,
        )
        root.devices.add_new(
          :char, 1, 8, 'rwm',
          name: '/dev/random',
          inherit: true,
        )
        root.devices.add_new(
          :char, 1, 9, 'rwm',
          name: '/dev/urandom',
          inherit: true,
        )
        root.devices.add_new(
          :char, 5, 0, 'rwm',
          name: '/dev/tty',
          inherit: true,
        )
        root.devices.add_new(
          :char, 5, 1, 'rwm',
        #  name: '/dev/console', # setup by lxc
          inherit: true,
        )
        root.devices.add_new(
          :char, 5, 2, 'rwm',
        #  name: '/dev/ptmx', # setup by lxc
          inherit: true,
        )
        root.devices.add_new(
          :char, 136, :all, 'rwm',
        #  name: '/dev/tty*', # setup by lxc
          inherit: true,
        )
        root.devices.apply
        root.save_config

      else
        root.devices.init
      end

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
        grp = Group.new(pool, name, root: root, devices: false)

      rescue Errno::ENOENT
        grp = Group.new(pool, name, load: false, root: root)
        grp.configure(path, [], devices: false)
        created = true
      end

      add(grp)
      [grp, created]
    end
  end
end
