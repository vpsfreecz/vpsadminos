# frozen_string_literal: true

require 'osctld/commands/base'

module OsCtld
  class Commands::Pool::StorageActivity < Commands::Base
    handle :pool_storage_activity

    def execute
      name = opts[:pool]
      error!('provide exactly one zpool name') unless opts.keys == [:pool] &&
                                                      name.is_a?(String) &&
                                                      !name.empty? && !name.include?('/') &&
                                                      !name.include?("\0") &&
                                                      name.bytesize <= 255

      tracker = Daemon.get&.storage_activity
      error!('storage activity is unavailable') unless tracker

      ok(tracker.snapshot(name, pool: DB::Pools.find(name)))
    end
  end
end
