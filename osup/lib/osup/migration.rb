module OsUp
  class Migration
    attr_reader :id, :path, :dirname, :name, :summary, :description, :snapshot

    def self.load(path, dirname)
      if /^(\d+)\-(.+)$/ !~ dirname
        fail "'#{dirname}' is not a valid migration"
      end

      new(path, dirname, $1.to_i, $2.gsub('-', ' ').capitalize)
    end

    def initialize(path, dirname, id, name)
      @path = File.join(path, dirname)
      @dirname = dirname
      @id = id
      @name = name
      @spec = load_spec
    end

    def action_script(action)
      File.join(path, "#{action}.rb")
    end

    def <=>(other)
      id <=> other.id
    end

    protected
    def load_spec
      unless File.exist?(spec_path)
        @snapshot = []
        return
      end

      spec = YAML.load_file(spec_path)
      @name = spec['name'] || @name
      @description = spec['description']
      @snapshot = spec['snapshot'].map(&:to_sym)
    end

    def spec_path
      File.join(path, 'spec.yml')
    end
  end
end
