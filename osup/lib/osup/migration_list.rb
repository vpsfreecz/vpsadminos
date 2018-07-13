require 'singleton'

module OsUp
  class MigrationList
    include Singleton

    class << self
      %i([] each count get).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    def initialize
      @migrations = []
      @index = {}

      load_migrations
    end

    def [](id)
      index[id]
    end

    def each(&block)
      migrations.each(&block)
    end

    def count
      migrations.count
    end

    def get
      migrations.clone
    end

    protected
    attr_reader :migrations, :index

    def load_migrations
      dir = OsUp.migration_dir

      Dir.entries(dir).each do |f|
        next if f.start_with?('.') || !Dir.exist?(File.join(dir, f))

        m = Migration.load(dir, f)
        migrations << m
        index[m.id] = m
      end

      migrations.sort!
    end
  end
end
