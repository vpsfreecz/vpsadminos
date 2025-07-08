module OsCtl::Cli
  class UgidFinder
    def initialize(header: true)
      @header = header
    end

    # @param uids [Array<Integer>]
    def list_by_uid(uids)
      results = find_by(uids:) if uids.any?

      header('UID', 'CONTAINER', 'CT_UID') if @header
      return if uids.empty?

      uids.each do |uid|
        _, cts = results[:by_uid].detect { |id, _cts| id == uid }

        if cts.nil?
          print(uid, nil)
        else
          cts.each { |ct| print(uid, ct) }
        end
      end
    end

    # @param gids [Array<Integer>]
    def list_by_gid(gids)
      results = find_by(gids:) if gids.any?

      header('GID', 'CONTAINER', 'CT_GID') if @header
      return if gids.empty?

      gids.each do |gid|
        _, cts = results[:by_gid].detect { |id, _cts| id == gid }

        if cts.nil?
          print(gid, nil)
        else
          cts.each { |ct| print(gid, ct) }
        end
      end
    end

    protected

    def find_by(uids: [], gids: [])
      c = OsCtl::Client.new
      c.open
      ret = c.cmd_data!(:ct_find_by_ugid, uids:, gids:)
      c.close
      ret
    end

    def header(*cols)
      puts format('%-10s %-20s %-10s', *cols)
    end

    def print(ugid, ct)
      puts format(
        '%-10d %-20s %-10s',
        ugid,
        ct ? "#{ct[:ct][:pool]}:#{ct[:ct][:id]}" : '-',
        ct ? ct[:ns_id].to_s : '-'
      )
    end
  end
end
