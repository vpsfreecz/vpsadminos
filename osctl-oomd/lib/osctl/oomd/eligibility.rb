module OsCtl::Oomd
  module Eligibility
    def self.hit?(ct, cts_by_lavg, memory_percent:, cpu_percent:, load_top:)
      return false if ct['memory_limit'].nil?

      memory_pct = ct['memory'].to_f / ct['memory_limit'] * 100
      return false if memory_pct < memory_percent

      if ct['cpu_limit']
        cpu_pct = ct['cpu_usage'] / ct['cpu_limit'] * 100
        return false if cpu_pct < cpu_percent
      end

      load_pos = cts_by_lavg.index do |other_ct|
        other_ct['pool'] == ct['pool'] && other_ct['id'] == ct['id']
      end

      return false if load_pos.nil? || load_pos >= load_top

      true
    end
  end
end
