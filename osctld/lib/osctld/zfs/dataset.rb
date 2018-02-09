module OsCtld
  # Class representing a single ZFS dataset
  class Zfs::Dataset
    include Utils::Log
    include Utils::System
    include Utils::Zfs

    # Full dataset name
    # @return [String]
    attr_reader :name

    # Dataset properties, only loaded properties are present
    # @return [Hash<String, String>]
    attr_reader :properties

    # Base name, i.e. path that this dataset is relative to
    # @return [String]
    attr_reader :base

    # @param name [String]
    # @param base [String] container subdatasets are relative to the container
    #                      dataset, so the base should be set to the container's
    #                      root dataset, e.g. `<pool>/ct/<id>`
    # @param properties [Hash]
    def initialize(name, base: '', properties: {})
      @name = name
      @base = base
      @properties = properties
    end

    def to_s
      name
    end

    # @param pool [String]
    def on_pool?(pool)
      name.start_with?("#{pool}/")
    end

    # @param dataset [Zfs::Dataset]
    def subdataset_of?(dataset)
      name.start_with?("#{dataset.name}/")
    end

    # @param opts [Hash] options
    # @option opts [Boolean] :parents
    # @option opts [Hash] :properties
    def create!(opts)
      zfs_opts = []
      zfs_opts << '-p' if opts[:parents]

      (opts[:properties] || {}).each do |k, v|
        zfs_opts << '-o' << "#{k}=#{v}"
      end

      zfs(:create, zfs_opts.join(' '), name)
    end

    # @param opts [Hash] options
    # @option opts [Boolean] :parents create the private dir for all parents
    #                                 as well
    def create_private!(opts = {})
      if opts[:parents]
        parents.each do |ds|
          break if Dir.exist?(ds.private_path)
          ds.create_private!
        end
      end

      Dir.mkdir(private_path, 0750)
    end

    # @param opts [Hash] options
    # @option opts [Boolean] :recursive
    def destroy!(opts)
      zfs(:destroy, opts[:recursive] ? '-r' : nil, name)
    end

    # @return [Boolean]
    def exist?
      zfs(:get, '-o value name', name, valid_rcs: [1])[:exitstatus] == 0
    end

    # @return [String]
    def private_path
      File.join(mountpoint, 'private')
    end

    # List descendant datasets and read selected properties
    # @param opts [Hash] options
    # @option opts [Integer] :depth
    # @option opts [:filesystem] :type
    # @option opts [Array<String>, Array<Symbol>] :properties
    # @return [Array<Zfs::Dataset>]
    def list(opts = {})
      zfs_opts = [
        '-r', '-H', '-p',
        '-o', 'name,property,value',
        '-t', opts[:type] || 'filesystem'
      ]
      zfs_opts << '-d' << opts[:depth] if opts[:depth]

      properties = []
      properties.concat(opts[:properties]) if opts[:properties]
      properties << 'name' if properties.empty?
      properties.uniq!

      zfs_opts << properties.map(&:to_s).join(',')

      ret = []
      last = nil

      zfs(:get, zfs_opts.join(' '), name)[:output].strip.split("\n").each do |line|
        name, property, value = line.split

        if !last || last.name != name
          ret << last unless last.nil?
          last = self.class.new(name, base: base)
        end

        next if property == 'name'
        last.properties[property.to_sym] = value
      end

      ret << last unless last.nil?
      ret
    end

    # @return [String]
    def mountpoint
      if @mountpoint
        return @mountpoint

      elsif properties[:mountpoint]
        @mountpoint = properties[:mountpoint]

      else
        @mountpoint = zfs(:get, '-H -o value mountpoint', name)[:output].strip
      end
    end

    # Return the direct parent
    # @return [Zfs::Dataset]
    def parent
      parts = name.split('/')

      if parts.count == 1
        nil

      else
        self.class.new(parts[0..-2].join('/'), base: base)
      end
    end

    # Return all parent datasets, up to the root
    # @return [Array<Zfs::Dataset>]
    def parents
      ret = []
      parts = name.split('/')[0..-2]

      parts.each_with_index do |v, i|
        ret << self.class.new(parts[0..i].join('/'), base: base)
      end

      ret.reverse!
    end

    # Return all direct and indirect children
    # @return [Array<Zfs::Dataset>]
    def descendants
      ret = list
      ret.shift # remove the current dataset
      ret
    end

    # Return the last component of the dataset name
    # @return [String]
    def base_name
      name.split('/').last
    end

    # Return the dataset name relative to the base
    # @return [String]
    def relative_name
      return @relative_name if @relative_name

      @relative_name = if base == name
        '/'

      elsif !name.start_with?("#{base}/")
        fail 'invalid base'

      else
        name[(base.length+1)..-1]
      end
    end

    # Return the dataset's parent relative to the base
    # @return [Zfs::Dataset, nil]
    def relative_parent
      ret = parent

      @relative_parent = if ret.name.length < @base.length
        nil
      else
        ret
      end
    end

    # Return the parents up to the base
    # @return [Array<Zfs::Dataset>]
    def relative_parents
      parents.take_while { |ds| ds.name.length >= @base.length }
    end

    # @return [Boolean]
    def root?
      name == base || !name.index('/')
    end

    # Export to client
    # @return [Hash]
    def export
      ret = {name: relative_name, dataset: name}
      ret.update(properties)
      ret
    end
  end
end
