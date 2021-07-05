module OsCtld
  # Used to find and execute configured container hooks
  class Container::HookManager
    # @param ct [Container]
    # @param hook_class [Class] subclass of {Container::Hooks::Base}
    # @param opts [Hash] hook options
    def self.run(ct, hook_class, opts)
      m = new(ct)
      m.run(hook_class, opts)
    end

    # @return [Array<Container::HookScript>]
    def self.list_all_scripts(ct)
      m = new(ct)
      m.list_all_scripts
    end

    # @return [Container]
    attr_reader :ct

    def initialize(ct)
      @ct = ct
    end

    # List of container hooks of particular type
    # @param hook_class [Class] subclass of {Container::Hooks::Base}
    # @return [Array<Container::HookScript>]
    def list_scripts(hook_class)
      file_name = hook_class.hook_name.to_s.gsub(/_/, '-')
      basedir = ct.user_hook_script_dir
      scripts = []

      singleton = get_script_singleton(hook_class, basedir, file_name)
      scripts << singleton if singleton

      scripts.concat(get_script_dir(hook_class, basedir, file_name))

      scripts.sort! { |a, b| a.base_name <=> b.base_name }
    end

    # List of container hooks of all types
    # @return [Array<Container::HookScript>]
    def list_all_scripts
      scripts = []

      Container::Hook.hooks.each_value do |klass|
        scripts.concat(list_scripts(klass))
      end

      scripts
    end

    # @param hook_class [Class] subclass of {Container::Hooks::Base}
    def run(hook_class, opts)
      hook = hook_class.new(ct, opts)

      list_scripts(hook_class).each do |v|
        hook.exec(v.abs_path)
      end
    end

    protected
    def get_script_singleton(hook_class, basedir, file_name)
      singleton = File.join(basedir, file_name)
      st = File.stat(singleton)
      return if !st.file? || !st.executable?

      Container::HookScript.new(
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
            scripts << Container::HookScript.new(
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
