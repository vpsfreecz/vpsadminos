require 'osctld/commands/logged'

require 'fileutils'

module OsCtld
  class Commands::User::Create < Commands::Logged
    handle :user_create

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    def find
      pool = DB::Pools.get_or_default(opts[:pool])
      error!('pool not found') unless pool

      rx = /^[a-z0-9_-]{1,#{32 - 1 - pool.name.length}}$/

      if rx !~ opts[:name]
        error!("invalid name, allowed format: #{rx.source}")
      end

      u = User.new(pool, opts[:name], load: false)
      error!('user already exists') if DB::Users.contains?(u.name, pool)
      u
    end

    def execute(u)
      # Possibilities:
      # 1) user new [--id-range *range*] kkt
      #    -> allocate new block, add default map
      #
      # 2) user new [--id-range *range*] --id-range-block-index *n* kkt
      #    -> use existing block, or allocate at index
      #
      # 3) user new --map 0:123000:65536 kkt
      #    -> do not allocate anything, use custom map as is
      #
      # 4) user new [--id-range *range*] --id-range-block-index *n* --map 0:123000:65536 kkt
      #    -> do not allocate anything, use custom map, but check that it fits
      #       in that allocation

      uid_map, gid_map =
        if !opts[:block_index] && !opts[:uid_map] && !opts[:gid_map]
          new_block_with_default_mapping(u)

        elsif opts[:block_index] && !opts[:uid_map] && !opts[:gid_map]
          block_index_with_default_mapping(u)

        elsif !opts[:range] && !opts[:block_index] && opts[:uid_map] && opts[:gid_map]
          no_block_with_custom_mapping(u)

        elsif opts[:block_index] && opts[:uid_map] && opts[:gid_map]
          block_index_with_custom_mapping(u)

        else
          error!('unsupported flag combination')
        end

      check_mappings!(uid_map, gid_map)

      manipulate(u) do
        u.configure(
          uid_map,
          gid_map,
          ugid: opts[:ugid],
          standalone: opts[:standalone]
        )

        call_cmd!(Commands::User::Setup, user: u)
        call_cmd!(Commands::User::Register, name: u.name, pool: u.pool.name)
        call_cmd!(Commands::User::SubUGIds)
      end

      ok
    end

    protected

    # Allocate a new block, create a default mapping
    def new_block_with_default_mapping(u)
      range = find_id_range
      allocation = range.allocate(1, owner: u.id_range_allocation_owner)
      progress("Allocated block ##{allocation[:block_index]} from ID range #{range.name}")
      create_default_mapping(allocation)
    end

    # Use an existing or a new block at a specific position, create a default mapping
    def block_index_with_default_mapping(u)
      range = find_id_range
      allocation = range.export_at(opts[:block_index])

      if allocation[:type] == :free
        allocation = range.allocate(
          1,
          block_index: opts[:block_index],
          owner: u.id_range_allocation_owner
        )
        progress("Allocated block ##{allocation[:block_index]} from ID range #{range.name}")
      else
        progress("Using block ##{allocation[:block_index]} from ID range #{range.name}")
      end

      create_default_mapping(allocation)
    end

    # Do not allocate anything, use a custom map
    def no_block_with_custom_mapping(_u)
      [opts[:uid_map], opts[:gid_map]].map { |v| IdMap.from_string_list(v) }
    end

    # Custom mapping on an existing or a new block on a specific position
    def block_index_with_custom_mapping(u)
      range = find_id_range
      allocation = range.export_at(opts[:block_index])

      if allocation[:type] == :free
        allocation = range.allocate(
          1,
          block_index: opts[:block_index],
          owner: u.id_range_allocation_owner
        )
        progress("Allocated block ##{allocation[:block_index]} from ID range #{range.name}")
      else
        progress("Using block ##{allocation[:block_index]} from ID range #{range.name}")
      end

      uid_map = IdMap.from_string_list(opts[:uid_map])
      gid_map = IdMap.from_string_list(opts[:gid_map])

      # Check that the maps fit within the allocation
      { uid_map:, gid_map: }.each do |name, map|
        map.each do |entry|
          if entry.host_id < allocation[:first_id] \
             || (entry.host_id + entry.count - 1) > allocation[:last_id]
            error!("#{name} does not fit within the ID range allocation")
          end
        end
      end

      [uid_map, gid_map]
    end

    def create_default_mapping(allocation)
      v = "0:#{allocation[:first_id]}:#{allocation[:id_count]}"
      [v, v].map { |v| IdMap.from_string_list([v]) }
    end

    def check_mappings!(uid_map, gid_map)
      if !uid_map.valid?
        error!('UID map is not valid')

      elsif !gid_map.valid?
        error!('GID map is not valid')
      end
    end

    def find_id_range
      range = if opts[:id_range]
                DB::IdRanges.find(opts[:id_range], opts[:pool])
              else
                DB::IdRanges.find('default', opts[:pool])
              end

      range || error!('ID range not found')
    end
  end
end
