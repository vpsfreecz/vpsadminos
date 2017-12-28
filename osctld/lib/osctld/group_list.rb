module OsCtld
  class GroupList < ObjectList
    # Ensures presence of root and default groups
    def self.setup
      instance.setup
    end

    def self.root
      instance.find('root')
    end

    def self.default
      instance.find('default')
    end

    def self.by_path(path)
      instance.by_path(path)
    end

    def initialize(*_)
      super
      @index = {}
    end

    def setup
      load_or_create('root', 'osctl')
      load_or_create('default', 'default')
    end

    def add(grp)
      sync do
        super
        @index[grp.path] = grp
      end
    end

    def remove(grp)
      sync do
        super
        @index.delete(grp.path)
        grp
      end
    end

    def by_path(path)
      sync { @index[path] }
    end

    protected
    def load_or_create(name, path)
      grp = nil
      root = name == 'root'

      begin
        grp = Group.new(name, root: root)

      rescue Errno::ENOENT
        grp = Group.new(name, load: false, root: root)
        grp.configure(path)
      end

      add(grp)
    end
  end
end
