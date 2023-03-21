require 'bindata'

module OsCtld
  # Read utmp files, see man utmp(5)
  module UtmpReader
    MAX_ENTRIES = 128

    class ExitStatus < BinData::Record
      endian :little

      int16 :e_termination
      int16 :e_exit
    end

    class TimeValue < BinData::Record
      endian :little

      int32 :tv_sec
      int32 :tv_usec
    end

    class Entry < BinData::Record
      TYPES = %i(
        empty
        run_lvl
        boot_time
        new_time
        old_time
        init_process
        login_process
        user_process
        dead_process
        accounting
      )

      endian :little

      int16 :ut_type
      int32 :ut_pid, byte_align: 4
      string :ut_line, length: 32, trim_padding: true
      string :ut_id, length: 4, trim_padding: true

      string :ut_user, length: 32, trim_padding: true
      string :ut_host, length: 256, trim_padding: true

      exit_status :ut_exit

      int32 :ut_session

      time_value :ut_tv

      array :ut_addr, type: :int32, initial_length: 4

      string :unused, length: 20

      # @return [Symbol]
      def record_type
        TYPES[ut_type]
      end
    end

    # @param path [String] utmp file to parse
    # @param max_entries [Integer] maximum number of entries read from the file
    # @yieldparam [Entry] entry
    # @raise [IOError]
    # @return [Array<Entry>, nil]
    def self.read(path, max_entries: MAX_ENTRIES)
      ret = []
      i = 0

      File.open('/run/utmp', 'rb') do |f|
        until f.eof?
          e = Entry.read(f)

          if block_given?
            yield(e)
          else
            ret << e
          end

          i += 1
          break if i >= max_entries
        end
      end

      block_given? ? nil : ret
    end

    # Find utmp file in standard locations and read it
    # @param max_entries [Integer] maximum number of entries read from the file
    # @yieldparam [Entry] entry
    # @raise [IOError, Errno::ENOENT]
    # @return [Array<Entry>, nil]
    def self.read_utmp_fhs(max_entries: MAX_ENTRIES, &block)
      %w(/run/utmp /var/log/utmp).each do |path|
        begin
          return read(path, max_entries: max_entries, &block)
        rescue Errno::ENOENT
          next
        end
      end

      raise Errno::ENOENT, 'utmp file not found'
    end
  end
end
