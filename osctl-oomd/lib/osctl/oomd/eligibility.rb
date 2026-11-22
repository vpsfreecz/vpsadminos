module OsCtl::Oomd
  module Eligibility
    # Typed schema-2 fields used by the controller. Nil metrics are known
    # unknowns; malformed data is not a partially usable observation.
    module Partial
      module_function

      def positive_integer?(value)
        value.is_a?(Integer) && value > 0
      end

      def reading?(value)
        value.is_a?(Numeric) && value.to_f.finite? && value >= 0
      end

      def load?(value)
        value.is_a?(Array) && value.size == 3 && value.all? { |part| reading?(part) }
      end

      def index(data)
        return unless data.has_key?('state_counts') && data.has_key?('loadavg')

        counts = data['state_counts']
        return unless [true, false].include?(data['inventory_complete'])
        unless counts.nil? || (counts.is_a?(Hash) && counts.all? { |state, n| string?(state) && n.is_a?(Integer) && n >= 0 })
          return
        end
        return unless data['loadavg'].nil? || load?(data['loadavg'])

        rows = data['containers']
        return unless rows.is_a?(Array) && rows.last.is_a?(Hash)

        host = rows.last
        return unless host['id'] == '[host]' && host.has_key?('loadavg') && host['loadavg'] == data['loadavg']
        return unless %w[pool init_pid init_start_time_ticks].all? { |field| host.has_key?(field) && host[field].nil? }

        result = {}
        rows[0...-1].each do |row|
          return nil unless valid_row?(row)

          key = row.values_at('pool', 'id')
          return nil if result.has_key?(key)

          result[key] = row
        end
        return if data['inventory_complete'] && !closed_roster?(counts, result)

        result
      end

      def closed_roster?(counts, rows)
        counts && counts.fetch('running', 0) == rows.size && rows.values.all? { |row| row['run_verified'] }
      end

      def string?(value)
        value.is_a?(String) && !value.empty?
      end

      def valid_row?(row)
        return false unless row.is_a?(Hash) && %w[pool id group_path].all? { |field| string?(row[field]) }
        return false if row['id'] == '[host]' || ![true, false].include?(row['run_verified'])
        return false unless row['errors'].is_a?(Hash) && row['errors'].all? { |field, reason| string?(field) && string?(reason) }
        return false unless %w[cpu_usage memory].all? { |field| row.has_key?(field) && (row[field].nil? || reading?(row[field])) }
        return false unless row.has_key?('loadavg') && (row['loadavg'].nil? || load?(row['loadavg']))
        return false unless row.has_key?('nproc') && (row['nproc'].nil? || (row['nproc'].is_a?(Integer) && row['nproc'] >= 0))
        return false unless %w[cpu_limit memory_limit].all? { |key| valid_limit?(row, key) }
        return false if %w[memory nproc loadavg].any? { |key| row[key] && row['errors'].has_key?(key) }
        return false unless %w[init_pid init_start_time_ticks cpu_baseline_sequence cpu_window_started_monotonic_ns].all? { |key| row.has_key?(key) }

        window = row.values_at('cpu_baseline_sequence', 'cpu_window_started_monotonic_ns')
        if row['cpu_usage'].nil?
          return false unless window.all?(&:nil?)
        else
          return false unless window.all? { |value| positive_integer?(value) } && !row['errors'].has_key?('cpu_usage')
        end

        if row['run_verified']
          !row['errors'].has_key?('run') && positive_integer?(row['init_pid']) && positive_integer?(row['init_start_time_ticks'])
        else
          %w[init_pid init_start_time_ticks cpu_usage memory nproc loadavg].all? { |field| row[field].nil? } &&
            %w[cpu_limit_state memory_limit_state].all? { |field| row[field] == 'unknown' }
        end
      end

      def valid_limit?(row, key)
        return false unless row.has_key?(key)

        value = row[key]
        case row["#{key}_state"]
        when 'limited' then reading?(value) && value > 0 && !row['errors'].has_key?(key)
        when 'unlimited' then value.nil? && !row['errors'].has_key?(key)
        when 'unknown' then value.nil?
        else false
        end
      end

      def current_core?(row)
        row['run_verified'] && reading?(row['memory']) && load?(row['loadavg']) &&
          row['memory_limit_state'] != 'unknown' && row['cpu_limit_state'] != 'unknown'
      end

      def usable_cpu?(row)
        reading?(row['cpu_usage']) && finite_percent?(row['cpu_usage'], row['cpu_limit'])
      end

      def finite_percent?(value, limit)
        limit.nil? || ((value.to_f / limit) * 100).finite?
      end

      def decidable?(row)
        row['run_verified'] && reading?(row['memory']) && usable_cpu?(row) &&
          row['memory_limit_state'] != 'unknown' && row['cpu_limit_state'] != 'unknown' &&
          finite_percent?(row['memory'], row['memory_limit'])
      end

      def run(row)
        row.values_at('group_path', 'init_pid', 'init_start_time_ticks') if row && row['run_verified']
      end
    end

    def self.rank(roster)
      roster.sort { |a, b| b.fetch('loadavg').fetch(0) <=> a.fetch('loadavg').fetch(0) }
    end

    def self.rank_proof(row, roster, ranked, k)
      return ranked.index(row) < k if ranked
      return true if k >= roster.size
      return unless row['loadavg']

      target = row['loadavg'][0]
      peers = roster.reject { |peer| peer.equal?(row) }
      known = peers.filter_map { |peer| peer['loadavg']&.first }
      best = 1 + known.count { |load| load > target }
      worst = 1 + peers.size - known.size + known.count { |load| load >= target }
      return false if best > k
      return true if worst <= k

      nil
    end

    def self.resource_hit?(ct, memory_percent:, cpu_percent:)
      return false if ct['memory_limit'].nil?

      memory_pct = ct['memory'].to_f / ct['memory_limit'] * 100
      return false if memory_pct < memory_percent

      if ct['cpu_limit']
        cpu_pct = ct['cpu_usage'] / ct['cpu_limit'] * 100
        return false if cpu_pct < cpu_percent
      end

      true
    end

    def self.hit?(ct, cts_by_lavg, memory_percent:, cpu_percent:, load_top:)
      return false unless resource_hit?(ct, memory_percent:, cpu_percent:)

      load_pos = cts_by_lavg.index do |other_ct|
        other_ct['pool'] == ct['pool'] && other_ct['id'] == ct['id']
      end

      return false if load_pos.nil? || load_pos >= load_top

      true
    end
  end
end
