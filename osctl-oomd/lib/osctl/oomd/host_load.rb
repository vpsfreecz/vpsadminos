require 'fileutils'
require 'libosctl'

module OsCtl::Oomd
  class HostLoad
    STATE_FILE = '/run/osctl/oomd/host-load.yml'.freeze
    STATE_VERSION = 2

    include OsCtl::Lib::Utils::File

    def initialize(interval)
      load_state
      @interval = interval
      @last_save = nil
    end

    def <<(lavg)
      @loads << lavg
      @loads.shift if @loads.length > max_samples

      if @last_save.nil? || @last_save + 60 < Time.now
        save_state
        @last_save = Time.now
      end

      nil
    end

    def median
      length = @loads.length
      center = length / 2
      sorted_loads = @loads.sort

      if length == 0
        0
      elsif length.even?
        (sorted_loads[center - 1] + sorted_loads[center]) / 2.0
      else
        sorted_loads[center]
      end
    end

    protected

    def load_state
      state = OsCtl::Lib::ConfigFile.load_yaml_file(STATE_FILE)
      @loads = state['version'] == STATE_VERSION ? Array(state['loads']) : []
    rescue Errno::ENOENT
      @loads = []
    end

    def max_samples
      86_400 / @interval
    end

    def save_state
      FileUtils.mkdir_p(File.dirname(STATE_FILE))

      regenerate_file(STATE_FILE, 0o600) do |new|
        new.write(OsCtl::Lib::ConfigFile.dump_yaml({
          'version' => STATE_VERSION,
          'loads' => @loads
        }))
      end
    end
  end
end
