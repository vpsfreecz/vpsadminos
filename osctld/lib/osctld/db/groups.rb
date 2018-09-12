require 'osctld/db/pooled_list'

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
        '/',
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
        root.devices.add_new(
          :block, '*', '*', 'm',
          inherit: true,
        )
        root.devices.add_new(
          :char, '*', '*', 'm',
          inherit: true,
        )
        root.devices.apply
        root.save_config

      else
        root.devices.init
      end

      load_or_create(pool, '/default')
    end

    def root(pool)
      find('/', pool)
    end

    def default(pool)
      find('/default', pool)
    end

    def add(grp)
      sync do
        super
        @index[grp.pool.name] ||= {}
        @index[grp.pool.name][grp.name] = grp
      end
    end

    def remove(grp)
      sync do
        super
        @index[grp.pool.name].delete(grp.name)
        @index.delete(grp.pool.name) if @index[grp.pool.name].empty?
        grp
      end
    end

    def by_path(pool, name)
      sync do
        next nil unless @index.has_key?(pool.name)
        @index[pool.name][name]
      end
    end

    protected
    def load_or_create(pool, name, path = nil)
      grp = nil
      root = name == '/'
      created = false

      begin
        grp = Group.new(pool, name, root: root, devices: false)

      rescue Errno::ENOENT
        grp = Group.new(pool, name, load: false, root: root)
        grp.configure(path: path, devices: false)
        created = true
      end

      add(grp)
      [grp, created]
    end
  end
end
