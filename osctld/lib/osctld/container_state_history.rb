require 'json'
require 'libosctl'
require 'tempfile'

module OsCtld
  # Observed state samples and permanent first-running evidence for one host boot.
  class ContainerStateHistory
    include OsCtl::Lib::Utils::Log

    PATH = '/run/osctl/container-state-history.json'.freeze
    BOOT_ID_PATH = '/proc/sys/kernel/random/boot_id'.freeze
    SUPPORT_PATH = '/run/booted-system/etc/osctl/container-state-history-version'.freeze
    DEFAULT_MAX_EVENTS = 1000
    BOOT_ID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/
    # Match Container::Builder::ID_RX without importing the builder/load path.
    ID_PATTERN = /\A[a-z0-9_-]{1,100}\z/i
    STATE_PATTERN = /\A[a-z][a-z0-9_]{0,31}\z/
    KINDS = %w[state observation].freeze
    SUMMARY_KEYS = %w[first_running_boottime_seconds id last_observation last_state pool].freeze
    EVENT_KEYS = %w[boottime_seconds id kind pool sequence state].freeze
    SNAPSHOT_KEYS = %w[boot_id dropped_events entries events next_sequence schema_version].freeze

    class InvalidState < StandardError; end
    class BootIdMismatch < InvalidState; end
    class PersistenceFailed < InvalidState; end

    class << self
      def instance
        @instance ||= new
      end

      %i[load record export].each do |method|
        define_method(method) { |*args, **kwargs| instance.public_send(method, *args, **kwargs) }
      end
    end

    def initialize(path: PATH, boot_id_path: BOOT_ID_PATH, support_path: SUPPORT_PATH,
                   failure_path: File.join(File.dirname(path), 'container-state-history.failed.json'))
      @path = path
      @boot_id_path = boot_id_path
      @support_path = support_path
      @failure_path = failure_path
      @mutex = Mutex.new
      @entries = {}
      @events = []
      @next_sequence = 1
      @dropped_events = 0
      @max_events = DEFAULT_MAX_EVENTS
      @reason = 'state_missing'
      @loaded = false
    end

    def load(max_events: DEFAULT_MAX_EVENTS)
      unless max_events.is_a?(Integer) && (1..10_000).cover?(max_events)
        raise ArgumentError, 'state_history.max_events must be an integer from 1 to 10000'
      end

      @mutex.synchronize do
        return if @loaded

        @loaded = true
        @max_events = max_events
        @boot_id = File.read(@boot_id_path).strip
        raise InvalidState, 'invalid kernel boot ID' unless BOOT_ID_PATTERN.match?(@boot_id)
        return unavailable('persistence_failed') if failure_present?

        begin
          data = read_snapshot
        rescue Errno::ENOENT
          return unavailable(File.exist?(@support_path) ? 'state_missing' : 'awaiting_reboot')
        end
        install(data)
        @reason = nil
        trim_on_load
      rescue BootIdMismatch => e
        unavailable('boot_id_mismatch', e)
      rescue InvalidState, JSON::ParserError, SystemCallError, IOError => e
        unavailable('state_invalid', e)
      end
    end

    # Callers hold the container lock. No history path ever reads a CT object.
    def record(pool, id, state, kind: :state, initial: false)
      @mutex.synchronize do
        return false if @reason

        verify_persisted_snapshot
        kind = kind.to_s.dup
        state = state.to_s.dup
        validate_identity(pool, id)
        raise InvalidState, 'invalid sample kind/state' unless KINDS.include?(kind) && valid_state?(state)

        old = @entries[[pool, id]]
        # Deserialization/publication alone must not manufacture running proof.
        return false if initial && state == 'running'
        return true if old && old["last_#{kind}"] == state

        timestamp = Process.clock_gettime(Process::CLOCK_BOOTTIME)
        raise InvalidState, 'invalid observation time' unless valid_time?(timestamp)

        entry = if old
                  old.dup
                else
                  {
                    'pool' => pool.dup, 'id' => id.dup, 'first_running_boottime_seconds' => nil,
                    'last_state' => nil, 'last_observation' => nil
                  }
                end
        entry["last_#{kind}"] = state
        entry['first_running_boottime_seconds'] ||= timestamp if state == 'running' && !initial
        event = {
          'sequence' => @next_sequence, 'boottime_seconds' => timestamp,
          'pool' => pool.dup, 'id' => id.dup, 'kind' => kind, 'state' => state
        }
        events = @events + [event]
        evicted = [events.length - @max_events, 0].max
        data = snapshot(
          entries: @entries.merge([pool, id] => entry), events: events.drop(evicted),
          next_sequence: @next_sequence + 1, dropped_events: @dropped_events + evicted
        )
        persist(data)
        install(data)
        true
      rescue InvalidState, JSON::ParserError, SystemCallError, IOError => e
        persistence_failed(e)
        false
      end
    end

    def export(view: 'timeline', pool: nil, id: nil)
      validate_query(view, pool, id)
      @mutex.synchronize do
        check_snapshot unless @reason
        ret = { schema_version: 1, boot_id: @boot_id&.dup, available: @reason.nil?, reason: @reason&.dup, entries: [] }
        if @reason.nil?
          rows = sorted_entries(@entries).select { |row| matches?(row, pool, id) }
          ret[:entries] = if view == 'ever_running'
                            rows.filter_map do |row|
                              next if row['first_running_boottime_seconds'].nil?

                              row.slice('pool', 'id', 'first_running_boottime_seconds')
                            end
                          else
                            rows
                          end
        end
        if view == 'timeline'
          ret.merge!(max_events: @max_events,
                     dropped_events: @reason ? nil : @dropped_events,
                     truncated: @reason ? nil : @dropped_events > 0,
                     events: @reason ? [] : @events.select { |event| matches?(event, pool, id) })
        end
        # The query must not hand mutable recorder objects to in-process callers.
        JSON.parse(JSON.generate(ret), symbolize_names: true)
      end
    end

    protected

    def validate_query(view, pool, id)
      raise ArgumentError, 'invalid history view' unless %w[timeline ever_running].include?(view)
      raise ArgumentError, 'container ID requires an explicit pool' if !id.nil? && pool.nil?
      raise ArgumentError, 'invalid pool filter' if !pool.nil? && (!pool.is_a?(String) || !NAME_PATTERN.match?(pool))
      raise ArgumentError, 'invalid container ID filter' if !id.nil? && (!id.is_a?(String) || !ID_PATTERN.match?(id))
    end

    def matches?(row, pool, id)
      (!pool || row['pool'] == pool) && (!id || row['id'] == id)
    end

    def validate_identity(pool, id)
      return if pool.is_a?(String) && NAME_PATTERN.match?(pool) && id.is_a?(String) && ID_PATTERN.match?(id)

      raise InvalidState, 'invalid container identity'
    end

    def valid_time?(time)
      time.is_a?(Numeric) && time.finite? && time >= 0
    end

    def valid_state?(state)
      state.is_a?(String) && STATE_PATTERN.match?(state)
    end

    def read_snapshot
      data = JSON.parse(File.read(@path))
      unless data.is_a?(Hash) && data.keys.sort == SNAPSHOT_KEYS && data['schema_version'].is_a?(Integer) &&
             data['schema_version'] == 1 && data['entries'].is_a?(Array) && data['events'].is_a?(Array) &&
             data['next_sequence'].is_a?(Integer) && data['next_sequence'] > 0 &&
             data['dropped_events'].is_a?(Integer) && data['dropped_events'] >= 0
        raise InvalidState, 'invalid history header'
      end
      unless data['boot_id'].is_a?(String) && BOOT_ID_PATTERN.match?(data['boot_id'])
        raise InvalidState, 'invalid history boot ID'
      end
      raise BootIdMismatch, 'history belongs to another boot' if data['boot_id'] != @boot_id

      entries = data['entries'].each_with_object({}) do |row, result|
        unless row.is_a?(Hash) && row.keys.sort == SUMMARY_KEYS
          raise InvalidState, 'invalid history summary'
        end

        validate_identity(row['pool'], row['id'])
        first = row['first_running_boottime_seconds']
        unless (first.nil? || valid_time?(first)) &&
               %w[last_state last_observation].all? { |key| row[key].nil? || valid_state?(row[key]) }
          raise InvalidState, 'invalid history summary values'
        end
        if first.nil? && %w[last_state last_observation].any? { |key| row[key] == 'running' }
          raise InvalidState, 'running summary has no first-running proof'
        end

        key = [row['pool'], row['id']]
        raise InvalidState, 'duplicate container identity' if result.has_key?(key)

        result[key] = row
      end
      validate_events(data, entries)
      data
    end

    def validate_events(data, entries)
      unless data['next_sequence'] - 1 == data['dropped_events'] + data['events'].length
        raise InvalidState, 'inconsistent sequence counters'
      end

      previous_time = 0
      last_samples = {}
      data['events'].each_with_index do |event, index|
        unless event.is_a?(Hash) && event.keys.sort == EVENT_KEYS &&
               event['sequence'].is_a?(Integer) && event['sequence'] == data['dropped_events'] + index + 1 &&
               valid_time?(event['boottime_seconds']) && event['boottime_seconds'] >= previous_time &&
               KINDS.include?(event['kind']) && valid_state?(event['state'])
          raise InvalidState, 'invalid state event'
        end

        validate_identity(event['pool'], event['id'])
        summary = entries[[event['pool'], event['id']]]
        raise InvalidState, 'event has no summary' unless summary
        if event['state'] == 'running' &&
           (summary['first_running_boottime_seconds'].nil? ||
            summary['first_running_boottime_seconds'] > event['boottime_seconds'])
          raise InvalidState, 'running event has no first-running proof'
        end

        last_samples[[event['pool'], event['id'], event['kind']]] = event['state']
        previous_time = event['boottime_seconds']
      end
      last_samples.each do |(pool, id, kind), state|
        raise InvalidState, 'event/summary state mismatch' if entries[[pool, id]]["last_#{kind}"] != state
      end
    end

    def sorted_entries(entries)
      entries.sort_by { |key, _entry| key }.map(&:last)
    end

    def snapshot(entries: @entries, events: @events, next_sequence: @next_sequence, dropped_events: @dropped_events)
      { 'schema_version' => 1, 'boot_id' => @boot_id, 'next_sequence' => next_sequence,
        'dropped_events' => dropped_events, 'entries' => sorted_entries(entries), 'events' => events }
    end

    def install(data)
      @entries = data['entries'].to_h { |row| [[row['pool'], row['id']], row] }
      @events = data['events']
      @next_sequence = data['next_sequence']
      @dropped_events = data['dropped_events']
    end

    def trim_on_load
      evicted = @events.length - @max_events
      return unless evicted > 0

      data = snapshot(events: @events.drop(evicted), dropped_events: @dropped_events + evicted)
      persist(data)
      install(data)
    rescue InvalidState, JSON::ParserError, SystemCallError, IOError => e
      persistence_failed(e)
    end

    def check_snapshot
      verify_persisted_snapshot
    rescue PersistenceFailed => e
      unavailable('persistence_failed', e)
    rescue Errno::ENOENT => e
      unavailable('state_missing', e)
    rescue BootIdMismatch => e
      unavailable('boot_id_mismatch', e)
    rescue InvalidState, JSON::ParserError, SystemCallError, IOError => e
      unavailable('state_invalid', e)
    end

    def verify_persisted_snapshot
      raise PersistenceFailed, 'a failed observation is retained' if failure_present?
      raise InvalidState, 'history changed outside osctld' if read_snapshot != snapshot
    end

    def failure_present?
      File.lstat(@failure_path)
      true
    rescue Errno::ENOENT
      false
    end

    def persist(data)
      Tempfile.create(['.container-state-history-', '.json'], File.dirname(@path)) do |file|
        file.write(JSON.generate(data))
        file.flush
        file.fsync
        File.rename(file.path, @path)
      end
    end

    def unavailable(reason, error = nil)
      @reason = reason
      log(:warn, :container_state_history, "History unavailable: #{reason}#{error ? ": #{error.message}" : ''}")
      nil
    end

    def persistence_failed(error)
      unavailable('persistence_failed', error)
      retain_failure
    end

    def retain_failure
      return if failure_present?

      File.rename(@path, @failure_path)
    rescue SystemCallError, IOError
      begin
        File.open(@failure_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(schema_version: 1, boot_id: @boot_id, reason: 'persistence_failed'))
          file.flush
          file.fsync
        end
      rescue Errno::EEXIST
        # Every existing sentinel, even a partial one, latches unavailable.
      rescue SystemCallError, IOError
        invalidate_failed_history
      end
    end

    def invalidate_failed_history
      File.unlink(@path)
    rescue Errno::ENOENT
      # Missing state prevents the next daemon from claiming completeness.
    rescue SystemCallError, IOError => e
      log(:warn, :container_state_history,
          "Unable to retain failure across daemon restart; history may be incomplete: #{e.message}")
    end
  end
end
