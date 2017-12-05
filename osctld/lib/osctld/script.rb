module OsCtld
  module Script
    def self.run(names, env)
      script = find_script(names)
      fail "script not found at any path: #{names.join(', ')}" unless script

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
