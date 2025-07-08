require 'osctld/commands/base'

module OsCtld
  class Commands::Container::FindByUgid < Commands::Base
    handle :ct_find_by_ugid

    def execute
      uids = check_ids!(opts.fetch(:uids, []))
      gids = check_ids!(opts.fetch(:gids, []))

      by_uid = {}
      by_gid = {}

      DB::Containers.each do |ct|
        uids.each do |uid|
          next unless ct.user.uid_map.include_host_id?(uid)

          by_uid[uid] ||= []
          by_uid[uid] << {
            ns_id: ct.user.uid_map.host_to_ns(uid),
            ct: ct.export
          }
        end

        gids.each do |gid|
          next unless ct.user.gid_map.include_host_id?(gid)

          by_gid[gid] ||= []
          by_gid[gid] << {
            ns_id: ct.user.gid_map.host_to_ns(gid),
            ct: ct.export
          }
        end
      end

      ok({ by_uid: hash_to_array(by_uid), by_gid: hash_to_array(by_gid) })
    end

    protected

    def check_ids!(ids)
      ids.each do |id|
        next if id.is_a?(Integer) && id >= 0

        error!("#{id.inspect} is not a valid user/group ID")
      end

      ids
    end

    def hash_to_array(hash)
      # JSON does not allow integer keys in a hash + osctld client code symbolizes names,
      # which break them as well.
      hash.map { |id, cts| [id, cts] }
    end
  end
end
