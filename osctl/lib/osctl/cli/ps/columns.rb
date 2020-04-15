require 'libosctl'

module OsCtl::Cli
  class Ps::Columns
    COLS = %i(
      pool
      ctid
      pid
      ctpid
      ruid
      rgid
      euid
      egid
      ctruid
      ctrgid
      cteuid
      ctegid
      vmsize
      rss
      state
      start
      time
      command
      name
    )

    DEFAULT = %i(
      pid
      ctpid
      cteuid
      vmsize
      rss
      state
      start
      time
      command
    )

    ALIGN_RIGHT = %i(
      pid
      ruid
      rgid
      euid
      egid
      ctruid
      ctrgid
      cteuid
      ctegid
      vmsize
      rss
      time
    )

    # @param process_list <OsCtl::Lib::ProcessList>
    # @param cols [Array<Symbol>]
    # @param precise [Boolean]
    # @return [Array<Hash>]
    def self.generate(process_list, cols, precise)
      spec = cols.map do |c|
        {
          name: c,
          label: c.to_s.upcase,
          align: ALIGN_RIGHT.include?(c) ? :right : :left,
        }
      end

      data = []

      process_list.each do |os_proc|
        row = new(os_proc, precise)

        begin
          data << Hash[cols.map { |c| [c, row.send(c)] }]
        rescue OsCtl::Lib::Exceptions::OsProcessNotFound
          next
        end
      end

      [spec, data]
    end

    include OsCtl::Utils::Humanize

    # @param os_proc [OsCtl::Lib::OsProcess]
    # @param precise [Boolean]
    def initialize(os_proc, precise)
      @os_proc = os_proc
      @precise = precise
    end

    def pool
      os_proc.ct_id[0]
    end

    def ctid
      os_proc.ct_id[1]
    end

    def pid
      os_proc.pid
    end

    def ctpid
      os_proc.ct_pid
    end

    def ruid
      os_proc.ruid
    end

    def rgid
      os_proc.rgid
    end

    def euid
      os_proc.euid
    end

    def egid
      os_proc.egid
    end

    def ctruid
      mapped_id_or_fallback(:ruid)
    end

    def ctrgid
      mapped_id_or_fallback(:rgid)
    end

    def cteuid
      mapped_id_or_fallback(:euid)
    end

    def ctegid
      mapped_id_or_fallback(:egid)
    end

    def vmsize
      present_data(os_proc.vmsize)
    end

    def rss
      present_data(os_proc.rss)
    end

    def state
      os_proc.state
    end

    def start
      present_time(os_proc.start_time)
    end

    def time
      present_duration(os_proc.user_time + os_proc.sys_time)
    end

    def command
      os_proc.cmdline
    end

    def name
      os_proc.name
    end

    protected
    attr_reader :os_proc

    def present_data(v)
      OsCtl::Lib::Cli::Presentable.new(v, formatted: precise? ? nil : humanize_data(v))
    end

    def present_time(v)
      OsCtl::Lib::Cli::Presentable.new(v, formatted: precise? ? nil : format_time(v))
    end

    def present_duration(v)
      OsCtl::Lib::Cli::Presentable.new(v, formatted: precise? ? nil : format_short_duration(v))
    end

    def format_time(v)
      now = Time.now

      if now - v > 24*60*60
        v.strftime('%b%d')
      else
        v.strftime('%H:%M')
      end
    end

    def mapped_id_or_fallback(id)
      os_proc.send(:"ct_#{id}")
    rescue OsCtl::Lib::Exceptions::IdMappingError
      os_proc.send(id) * -1
    end

    def precise?
      @precise
    end
  end
end
