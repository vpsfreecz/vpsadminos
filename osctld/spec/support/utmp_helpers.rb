# frozen_string_literal: true

module UtmpHelpers
  def build_utmp_entry(type: :user_process, pid: 1234, line: 'pts/0', id: 'p0',
                       user: 'alice', host: '', session: 1, sec: 1, usec: 0,
                       addr: [0, 0, 0, 0])
    ut_type = OsCtld::UtmpReader::Entry::TYPES.index(type)
    raise ArgumentError, "unsupported utmp type #{type.inspect}" if ut_type.nil?

    OsCtld::UtmpReader::Entry.new(
      ut_type:,
      ut_pid: pid,
      ut_line: line,
      ut_id: id,
      ut_user: user,
      ut_host: host,
      ut_exit: { e_termination: 0, e_exit: 0 },
      ut_session: session,
      ut_tv: { tv_sec: sec, tv_usec: usec },
      ut_addr: addr,
      unused: "\x00" * 20
    )
  end

  def write_utmp(path, entries)
    File.open(path, 'wb') do |file|
      entries.each do |entry|
        file.write(entry.to_binary_s)
      end
    end
  end
end

RSpec.configure do |config|
  config.include UtmpHelpers
end
