module OsCtld
  module Script
    class NotFound < StandardError ; end

    def self.run(names, env)
      script = find_script(names)

      unless script
        raise NotFound, "script not found at any path: #{names.join(', ')}"
      end

      pid = Process.fork do
        ENV.clear
        ENV.update(env)

        Process.exec(script)
      end

      Process.wait(pid)
    end

    def self.find_script(names)
      names.detect do |v|
        path = OsCtld::script(v)
        return path if File.exist?(path)
      end

      nil
    end
  end
end
