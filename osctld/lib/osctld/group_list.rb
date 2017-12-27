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

    def setup
      load_or_create('root', 'osctl')
      load_or_create('default', 'default')
    end

    protected
    def load_or_create(name, path)
      grp = nil

      begin
        grp = Group.new(name)

      rescue Errno::ENOENT
        grp = Group.new(name, load: false)
        grp.configure(path)
      end

      add(grp)
    end
  end
end
