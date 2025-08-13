require 'fileutils'
require 'libosctl'

module OsCtl::Oomd
  class HostLoad
    STATE_FILE = '/run/osctl/oomd/host-load.yml'.freeze

    include OsCtl::Lib::Utils::File

    def initialize(interval)
      load_state
      @interval = interval
      @last_save = nil
    end

    def <<(lavg)
      @loads << lavg
      @loads.sort!
      @loads.shift if @loads.length > (86_400 / @interval)

      if @last_save.nil? || @last_save + 60 < Time.now
        save_state
        @last_save = Time.now
      end

      nil
    end

    def median
      length = @loads.length
      center = length / 2

      if length == 0
        0
      elsif length.even?
        (@loads[center - 1] + @loads[center]) / 2.0
      else
        @loads[center]
      end
    end

    protected

    def load_state
      @loads = OsCtl::Lib::ConfigFile.load_yaml_file(STATE_FILE)['loads']
    rescue Errno::ENOENT
      @loads = []
    end

    def save_state
      FileUtils.mkdir_p(File.dirname(STATE_FILE))

      regenerate_file(STATE_FILE, 0o600) do |new|
        new.write(OsCtl::Lib::ConfigFile.dump_yaml({ 'loads' => @loads }))
      end
    end
  end
end
