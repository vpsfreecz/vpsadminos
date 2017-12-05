require 'yaml'

module OsCtld
  class ContainerList < ObjectList
    STATEFILE = File.join(RunState::RUNDIR, 'containers.yml')

    class << self
      %i(save_state load_state).each do |v|
        define_method(v) { |*args, &block| instance.send(v, *args, &block) }
      end
    end

    def save_state
      get do |cts|
        data = {}

        cts.each do |ct|
          data[ct.id] = {
            'veth' => ct.veth,
          }
        end

        File.write("#{STATEFILE}.new", YAML.dump(data))
        File.rename("#{STATEFILE}.new", STATEFILE)
        File.chmod(0600, STATEFILE)
      end
    end

    def load_state
      return {} unless File.exist?(STATEFILE)
      YAML.load_file(STATEFILE)
    end
  end
end
