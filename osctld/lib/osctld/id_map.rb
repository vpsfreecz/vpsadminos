require 'libosctl'

module OsCtld
  class IdMap < OsCtl::Lib::IdMap
    # Load map from config file
    #
    # We're still backward compatible with UID/GID offsets, which are converted
    # to a map with a single entry. Remove this in the future (TODO).
    #
    # @return [IdMap]
    def self.load(cfg, old_cfg = nil)
      if old_cfg && cfg.nil? && old_cfg['offset'] && old_cfg['size']
        new(["0:#{old_cfg['offset']}:#{old_cfg['size']}"])

      else
        new(cfg || [])
      end
    end

    # Dump the map to config file
    def dump
      entries.map(&:to_s)
    end

    # Export the map to clients
    def export
      dump
    end
  end
end
