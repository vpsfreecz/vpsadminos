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
      load_or_create(pool, 'root', 'osctl')
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

      begin
        grp = Group.new(pool, name, root: root)

      rescue Errno::ENOENT
        grp = Group.new(pool, name, load: false, root: root)
        grp.configure(path)
      end

      add(grp)
    end
  end
end
