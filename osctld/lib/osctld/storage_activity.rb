# frozen_string_literal: true

require 'securerandom'

module OsCtld
  # Bounded, daemon-local evidence about delayed per-pool storage work.
  # It observes work; it does not prevent any operation from starting.
  class StorageActivity
    VERSION = 1
    COVERAGE = 'gc_trash_v1'
    MAX_COUNT = 10_000
    MAX_REASONS = 8
    KINDS = %i[run_gc trash_prune trash_move].freeze
    STATES = %w[importing active stopping absent].freeze
    REASONS = %w[
      prior_instance_unsettled invalid_registration_count count_overflow
      stale_instance_event worker_dead worker_inspection_failed pool_missing
      pool_instance_mismatch reason_overflow counter_mismatch
      gc_queue_failed gc_worker_lost gc_queue_event_unknown gc_job_failed
      gc_worker_unstopped trash_queue_failed trash_worker_lost
      trash_queue_event_unknown trash_job_failed trash_unmount_failed
      trash_metadata_incomplete trash_destroy_failed
    ].freeze

    Entry = Struct.new(
      :instance_uuid, :state, :counts, :registered, :unknown_reasons,
      keyword_init: true
    )

    attr_reader :boot_uuid

    def initialize
      @boot_uuid = SecureRandom.uuid
      @mutex = Mutex.new
      @generation = 0
      @pools = {}
    end

    def attach_pool(name)
      change do
        previous = @pools[name]
        reasons = previous ? previous.unknown_reasons.dup : []

        if previous && (previous.state != 'absent' || busy?(previous))
          add_reason(reasons, 'prior_instance_unsettled')
        end

        entry = Entry.new(
          instance_uuid: SecureRandom.uuid,
          state: 'importing',
          counts: empty_counts,
          registered: 0,
          unknown_reasons: reasons
        )
        @pools[name] = entry
        entry.instance_uuid
      end
    end

    def state(name, instance_uuid, value)
      raise ArgumentError, 'invalid pool state' unless STATES.include?(value)

      update(name, instance_uuid) { |entry| entry.state = value }
    end

    def enqueue(name, instance_uuid, kind)
      check_kind!(kind)
      update(name, instance_uuid) { |entry| increase(entry, kind, :pending) }
    end

    def start_queued(name, instance_uuid, kind)
      check_kind!(kind)
      update(name, instance_uuid) do |entry|
        decrease(entry, kind, :pending)
        increase(entry, kind, :running)
      end
    end

    def start_direct(name, instance_uuid, kind)
      check_kind!(kind)
      update(name, instance_uuid) { |entry| increase(entry, kind, :running) }
    end

    def finish(name, instance_uuid, kind)
      check_kind!(kind)
      update(name, instance_uuid) { |entry| decrease(entry, kind, :running) }
    end

    def registered(name, instance_uuid, count)
      update(name, instance_uuid) do |entry|
        if !count.is_a?(Integer) || count < 0
          add_reason(entry.unknown_reasons, 'invalid_registration_count')
        elsif count > MAX_COUNT
          entry.registered = MAX_COUNT
          add_reason(entry.unknown_reasons, 'count_overflow')
        else
          entry.registered = count
        end
      end
    end

    def unknown(name, instance_uuid, reason)
      update(name, instance_uuid) { |entry| add_reason(entry.unknown_reasons, reason) }
    end

    # The current Pool object is inspected under the same mutex as all counters.
    # A missing or dead worker remains unknown even if it is later restarted.
    def snapshot(name, pool:)
      @mutex.synchronize do
        entry = @pools[name]
        state = entry ? entry.state : 'absent'
        alive = { run_gc: false, trash_prune: false }

        if pool
          if entry.nil? || pool.storage_activity_instance_uuid != entry.instance_uuid
            mark_snapshot_unknown(entry, 'pool_instance_mismatch')
          else
            begin
              alive = {
                run_gc: pool.garbage_collector&.started? || false,
                trash_prune: pool.trash_bin&.started? || false
              }
              if state == 'active' && !alive.values.all?
                mark_snapshot_unknown(entry, 'worker_dead')
              end
            rescue StandardError
              mark_snapshot_unknown(entry, 'worker_inspection_failed') if state == 'active'
            end
          end
        elsif entry && state != 'absent'
          mark_snapshot_unknown(entry, 'pool_missing')
          state = 'absent'
        end

        reasons = entry ? entry.unknown_reasons.dup : ['pool_absent']
        counts = entry ? copy_counts(entry) : empty_counts
        overflow = reasons.include?('count_overflow') || reasons.include?('reason_overflow')
        unknown = state != 'active' || !alive.values.all? || reasons.any?
        idle = !unknown && counts.values.all? { |v| v.values.all?(&:zero?) }

        {
          version: VERSION,
          coverage: COVERAGE,
          daemon_boot_uuid: boot_uuid,
          pool_instance_uuid: entry&.instance_uuid,
          generation: @generation,
          pool: name,
          state: state,
          counts: counts,
          registered_run_datasets: entry ? entry.registered : 0,
          worker_alive: alive,
          unknown_reasons: reasons,
          unknown: unknown,
          overflow: overflow,
          idle: idle
        }
      end
    end

    private

    def change
      @mutex.synchronize do
        @generation += 1
        begin
          yield
        ensure
          @generation += 1
        end
      end
    end

    def update(name, instance_uuid)
      change do
        entry = @pools[name]
        if entry && entry.instance_uuid == instance_uuid
          yield entry
        elsif entry
          add_reason(entry.unknown_reasons, 'stale_instance_event')
        end
      end
    end

    def mark_snapshot_unknown(entry, reason)
      @generation += 1
      add_reason(entry.unknown_reasons, reason) if entry
      @generation += 1
    end

    def add_reason(reasons, reason)
      raise ArgumentError, 'invalid storage activity reason' unless REASONS.include?(reason)

      return if reasons.include?(reason)

      if reasons.length < MAX_REASONS
        reasons << reason
      elsif !reasons.include?('reason_overflow')
        reasons[-1] = 'reason_overflow'
      end
    end

    def empty_counts
      KINDS.to_h { |kind| [kind, { pending: 0, running: 0 }] }
    end

    def copy_counts(entry)
      entry.counts.transform_values(&:dup)
    end

    def busy?(entry)
      entry.counts.values.any? { |v| v.values.any?(&:positive?) }
    end

    def check_kind!(kind)
      raise ArgumentError, 'invalid activity kind' unless KINDS.include?(kind)
    end

    def increase(entry, kind, phase)
      current = entry.counts.fetch(kind).fetch(phase)
      if current == MAX_COUNT
        add_reason(entry.unknown_reasons, 'count_overflow')
      else
        entry.counts[kind][phase] = current + 1
      end
    end

    def decrease(entry, kind, phase)
      current = entry.counts.fetch(kind).fetch(phase)
      if current == 0
        add_reason(entry.unknown_reasons, 'counter_mismatch')
      else
        entry.counts[kind][phase] = current - 1
      end
    end
  end
end
