require 'libosctl'

module OsCtl
  class Cli::KernelKeyring
    include OsCtl::Lib::Utils::Humanize

    PREFIX = 'keyring.'.freeze

    PARAMS = %w[nkeys nikeys qnkeys qnbytes].freeze

    def list_param_names
      PARAMS.map { |v| name_to_cli(v) }
    end

    def add_values(data, cols, precise: false)
      params = selected_params(cols)
      return if params.empty?

      if data.is_a?(::Hash)
        add_param_values(data, params, precise)
      elsif data.is_a?(::Array)
        data.each do |ct|
          add_param_values(ct, params, precise)
        end
      end
    end

    alias add_container_values add_values
    alias add_user_values add_values

    protected

    def add_param_values(data, params, precise)
      uid_map = OsCtl::Lib::IdMap.from_hash_list(data[:uid_map])
      key_users = keyring.for_id_map(uid_map)

      params.each do |param|
        # Key users are tracked per UID, so one container/mapping can have many
        # key users, we sum them all.
        sum = key_users.inject(0) { |acc, ku| acc + ku.send(param) }

        data[name_to_cli(param).to_sym] = param_value(param, sum, precise)
      end
    end

    def selected_params(cols)
      ret = []

      cols.each do |c|
        next unless c.start_with?(PREFIX)

        name = name_to_internal(c)
        ret << name if PARAMS.include?(name)
      end

      ret
    end

    def keyring
      @keyring ||= OsCtl::Lib::KernelKeyring.new
    end

    def name_to_cli(v)
      "#{PREFIX}#{v}"
    end

    def name_to_internal(v)
      v[PREFIX.length..]
    end

    def param_value(param, v, precise)
      case param
      when 'nkeys', 'nikeys', 'qnkeys'
        OsCtl::Lib::Cli::Presentable.new(v, formatted: precise ? nil : humanize_number(v))

      when 'qnbytes'
        OsCtl::Lib::Cli::Presentable.new(v, formatted: precise ? nil : humanize_data(v))
      end
    end
  end
end
