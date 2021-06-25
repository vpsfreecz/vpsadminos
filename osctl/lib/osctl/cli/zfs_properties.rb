require 'libosctl'

module OsCtl
  class Cli::ZfsProperties
    include Utils::Humanize

    ABBREVIATIONS = {
      'avail' => 'available',
      'compress' => 'compression',
      'dnsize' => 'dnodesize',
      'lrefer' => 'logicalreferenced',
      'lused' => 'logicalused',
      'rdonly' => 'readonly',
      'recsize' => 'recordsize',
      'refer' => 'referenced',
      'refreserv' => 'refreservation',
      'reserv' => 'reservation',
      'volsize' => 'volblocksize',
    }

    def list_property_names
      zpools = `zpool list -H -o name`.strip.split("\n")
      return [] if zpools.empty?

      `zfs get -H -o property all #{zpools.first}`.split.map do |v|
        name_to_cli(v)
      end
    end

    def validate_property_names(props)
      props.map do |v|
        next(v) unless is_prop?(v)

        n = name_to_zfs(v)
        real_name =
          if ABBREVIATIONS.has_key?(n)
            ABBREVIATIONS[n]
          else
            n
          end

        name_to_cli(real_name).to_sym
      end
    end

    def add_container_values(data, props, precise: false)
      zfs_props = props.select { |v| is_prop?(v) }.map { |v| name_to_zfs(v) }
      return if zfs_props.empty?

      if data.is_a?(::Hash)
        index = { data[:dataset] => data }
      elsif data.is_a?(::Array)
        index = Hash[data.map { |ct| [ct[:dataset], ct] }]
      end

      add_property_values(index, zfs_props, precise)
    end

    protected
    def add_property_values(index, zfs_props, precise)
      out = `zfs get -Hp -o name,property,value #{zfs_props.join(',')} #{index.keys.join(' ')}`

      if $?.exitstatus != 0
        fail "unable to read ZFS properties"
      end

      out.strip.split("\n").each do |line|
        dataset, prop, val = line.split("\t")

        index[dataset][:"#{name_to_cli(prop)}"] = prop_value(prop, val, precise)
      end
    end

    def name_to_zfs(v)
      v[4..-1]
    end

    def name_to_cli(v)
      "zfs.#{v}"
    end

    def is_prop?(v)
      v.start_with?('zfs.')
    end

    def prop_value(prop, v, precise)
      case prop
      # Timestamp
      when 'creation'
        i = v.to_i
        OsCtl::Lib::Cli::Presentable.new(
          i,
          formatted: precise ? nil : Time.at(i).strftime('%Y-%m-%d %H:%M:%S %Z'),
        )

      # Data units
      when 'avail', 'available', 'logicalreferenced', 'logicalused', 'quota',
           'recordsize', 'referenced', 'refquota', 'refreservation',
           'reservation', 'used', 'usedbychildren', 'usedbydataset',
           'usedbyrefreservation', 'usedbysnapshots', 'volblocksize', 'written'
        i = v.to_i
        OsCtl::Lib::Cli::Presentable.new(i, formatted: precise ? nil : humanize_data(i))

      # Other
      else
        v
      end
    end
  end
end
