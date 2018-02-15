module VpsAdminOS::Converter
  module Vz6::Migrator
    def self.for(vz_ct, use_zfs)
      if use_zfs
        Vz6::Migrator::Zfs

      elsif vz_ct.ploop?
        Vz6::Migrator::Ploop

      else
        Vz6::Migrator::Simfs
      end
    end

    def self.create(vz_ct, target_ct, opts)
      begin
        Vz6::Migrator::State.load(vz_ct.ctid)

      rescue Errno::ENOENT
        # ok

      else
        fail "migration for CT #{vz_ct.ctid} has already been started"
      end

      state = Vz6::Migrator::State.create(vz_ct, target_ct, opts)
      self.for(vz_ct, opts[:zfs]).new(state)
    end

    def self.load(ctid)
      state = Vz6::Migrator::State.load(ctid)
      self.for(state.vz_ct, state.opts[:zfs]).new(state)
    end
  end
end

require_relative 'migrator/state'
require_relative 'migrator/base'
require_relative 'migrator/zfs'
require_relative 'migrator/simfs'
require_relative 'migrator/ploop'
