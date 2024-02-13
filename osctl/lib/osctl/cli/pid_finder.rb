require 'libosctl'

module OsCtl::Cli
  class PidFinder
    def initialize(header: true)
      @finder = OsCtl::Lib::PidFinder.new
      print('PID', 'CONTAINER', 'CTPID', 'NAME') if header
    end

    # @param pid [Integer]
    def find(pid)
      ret = finder.find(pid.to_i)

      if ret.nil?
        print(pid, '-')

      elsif ret.ctid == :host
        print(pid, '[host]', '-', ret.os_process.name)

      else
        print(
          pid,
          "#{ret.pool}:#{ret.ctid}",
          ret.os_process.ct_pid,
          ret.os_process.name
        )
      end
    end

    protected

    attr_reader :finder

    def print(pid, ct, ctpid = '-', name = '-')
      puts format('%-10s %-20s %-10s %s', pid.to_s, ct, ctpid.to_s, name)
    end
  end
end
