module OsCtld
  class Hook::Manager
    # @param event_instance [Class]
    # @param hook_class [Class] subclass of {Hook::Base}
    # @param opts [Hash] hook options
    def self.run(event_instance, hook_class, opts)
      m = new(event_instance)
      m.run(hook_class, opts)
    end

    # @param event_instance [Class]
    # @return [Array<Hook::Script>]
    def self.list_all_scripts(event_instance)
      m = new(event_instance)
      m.list_all_scripts
    end

    # @return [Class]
    attr_reader :event_instance

    def initialize(event_instance)
      @event_instance = event_instance
    end

    # List of hooks of particular type
    # @param hook_class [Class] subclass of {Hook::Base}
    # @return [Array<Hook::Script>]
    def list_scripts(hook_class)
      file_name = hook_class.hook_name.to_s.gsub(/_/, '-')
      basedir = event_instance.user_hook_script_dir
      scripts = []

      singleton = get_script_singleton(hook_class, basedir, file_name)
      scripts << singleton if singleton

      scripts.concat(get_script_dir(hook_class, basedir, file_name))

      scripts.sort! { |a, b| a.base_name <=> b.base_name }
    end

    # List of container hooks of all types
    # @return [Array<Hook::Script>]
    def list_all_scripts
      scripts = []

      Hook.hooks(event_instance.class).each_value do |klass|
        scripts.concat(list_scripts(klass))
      end

      scripts
    end

    # @param hook_class [Class] subclass of {Hook::Base}
    def run(hook_class, opts)
      hook = hook_class.new(event_instance, opts)

      list_scripts(hook_class).each do |v|
        hook.exec(v.abs_path)
      end
    end

    protected
    def get_script_singleton(hook_class, basedir, file_name)
      singleton = File.join(basedir, file_name)
      st = File.stat(singleton)
      return if !st.file? || !st.executable?

      Hook::Script.new(
        hook_class.hook_name,
        singleton,
        file_name,
      )
    rescue Errno::ENOENT
      nil
    end

    def get_script_dir(hook_class, basedir, file_name)
      dir_name = "#{file_name}.d"
      hookd = File.join(basedir, dir_name)
      scripts = []

      if Dir.exist?(hookd)
        Dir.entries(hookd).each do |v|
          next if %w(. ..).include?(v)

          abs_path = File.join(hookd, v)

          begin
            st = File.stat(abs_path)
          rescue Errno::ENOENT
            next
          end

          if st.file? && st.executable?
            scripts << Hook::Script.new(
              hook_class.hook_name,
              abs_path,
              File.join(dir_name, v),
            )
          end
        end
      end

      scripts
    end
  end
end
