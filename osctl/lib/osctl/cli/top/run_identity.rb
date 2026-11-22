module OsCtl::Cli
  # Keep all proof reads tied to one task, even if its numeric PID is reused.
  class Top::RunIdentity
    Invalid = Class.new(StandardError)

    attr_reader :ticks, :load_namespace

    def initialize(pid:, id:, group_path:, v1:, pid_namespace: nil)
      raise Invalid unless pid.is_a?(Integer) && pid > 0

      File.open("/proc/#{pid}") do |task|
        path = "/proc/self/fd/#{task.fileno}"
        stat = File.read("#{path}/stat")
        closing = stat.rindex(')')
        raise Invalid unless stat.start_with?("#{pid} (") && closing

        fields = stat[(closing + 1)..].split
        birth = fields[19]
        raise Invalid unless birth&.match?(/\A[0-9]+\z/) && birth.to_i > 0 && %w[R S D T t I P W].include?(fields[0])

        pids = File.read("#{path}/status").lines.grep(/\ANSpid:/)
        raise Invalid unless pids.one? && pids.first.split == ['NSpid:', pid.to_s, '1']
        raise Invalid unless payload_member?(File.read("#{path}/cgroup"), group_path, id, v1)
        raise Invalid if pid_namespace && !same_namespace?(pid_namespace.stat, File.stat("#{path}/ns/pid"))

        @ticks = birth.to_i
        @load_namespace = load_namespace_at(path)
      end
    end

    protected

    def payload_member?(content, group_path, id, v1)
      parts = group_path.split('/').reject(&:empty?)
      raise Invalid if parts.empty? || parts.intersect?(%w[. ..]) || id.include?('/')

      payload = "/#{parts.join('/')}/lxc.payload.#{id}"
      member = ->(path) { path == payload || path.start_with?("#{payload}/") }
      authorities = []
      content.each_line do |line|
        hierarchy, subsystems, path = line.chomp.split(':', 3)
        return false unless hierarchy&.match?(/\A[0-9]+\z/) && subsystems && path&.start_with?('/')

        controllers = subsystems.split(',')
        if v1 ? controllers.include?('freezer') : hierarchy == '0' || subsystems.empty?
          valid = v1 ? hierarchy.to_i > 0 : hierarchy == '0' && subsystems.empty?
          return false unless valid

          authorities << path
        elsif contradictory_membership?(path, parts, member)
          return false
        end
      end
      authorities.one? && member.call(authorities.first)
    end

    def contradictory_membership?(path, expected, member)
      return false if member.call(path)

      components = path.split('/').reject(&:empty?)
      return true if components.any? { |part| part.start_with?('lxc.payload.', 'lxc.monitor.') }

      # Other controllers may report / or ordinary named service hierarchies.
      # A canonical CT subtree, however, is affirmative ownership evidence.
      ct = components.index { |part| part.start_with?('ct.') }
      ct && components != expected && components != expected[0...-1]
    end

    def same_namespace?(a, b)
      a.dev == b.dev && a.ino == b.ino
    end

    def load_namespace_at(path)
      File.readlink("#{path}/ns/cgroup")[/\Acgroup:\[([1-9][0-9]*)\]\z/, 1]
    rescue SystemCallError, IOError
      nil
    end
  end
end
