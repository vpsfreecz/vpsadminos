module OsCtl::Lib
  # Read selected dataset properties into {Zfs::DatasetTree}
  class Zfs::PropertyReader
    include Utils::Log
    include Utils::System

    # @param dataset_names [Array<String>]
    # @param properties [Array<String>]
    # @param type [String]
    # @param recursive [Boolean]
    # @return [Zfs::DatasetTree]
    def read(dataset_names, properties, type: 'filesystem', recursive: false)
      tree = Zfs::DatasetTree.new
      return tree if dataset_names.empty?

      zfs_opts = [
        '-Hp',
        '-o', 'name,property,value',
        '-t', type,
      ]

      zfs_opts << '-r' if recursive
      zfs_opts << properties.join(',')

      zfs(
        :get,
        zfs_opts.join(' '),
        dataset_names.join(' ')
      ).output.strip.split("\n").each do |line|
        dataset, prop, val = line.split("\t")

        tree.add_property(dataset, prop, val)
      end

      tree
    end
  end
end
