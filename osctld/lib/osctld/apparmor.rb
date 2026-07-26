require 'libosctl'
require 'osctld/run_state'

module OsCtld
  class AppArmor
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    extend OsCtl::Lib::Utils::System

    # Paths where `apparmor_parser` searches for configuration files
    PATHS = [RunState::APPARMOR_DIR].freeze

    def self.enabled?
      if @enabled.nil?
        begin
          @enabled = Daemon.get.config.apparmor_paths.any? \
            && Dir.exist?('/sys/kernel/security/apparmor') \
            && File.read('/sys/module/apparmor/parameters/enabled').strip.downcase == 'y'
        rescue Errno::ENOENT
          @enabled = false
        end
      else
        @enabled
      end
    end

    # Prepare shared files in `/run/osctl`
    def self.setup
      PATHS.concat(Daemon.get.config.apparmor_paths)

      base = File.join(RunState::APPARMOR_DIR, 'osctl')
      features = File.join(base, 'features')

      [base, features].each do |dir|
        FileUtils.mkdir_p(dir, mode: 0o755)
      end

      ErbTemplate.render_to(
        'apparmor/features/nesting',
        {},
        File.join(features, 'nesting')
      )
    end

    # Load profiles of running containers from `pool`
    # @param pool [Pool]
    def self.setup_pool(pool)
      [profile_dir(pool), cache_dir(pool)].each do |dir|
        FileUtils.mkdir_p(dir, mode: 0o700)
      end

      cts = DB::Containers.get.select do |ct|
        next(false) if ct.pool != pool || !ct.running?

        ct.apparmor.generate_profile(ct.run_conf)
        true
      end

      return unless cts.any?

      apparmor_parser(pool, 'r', cts.map { |ct| ct.apparmor.profile_path(ct.run_conf) })
    end

    # Per-pool runstate directory with profiles
    def self.profile_dir(pool)
      File.join(pool.apparmor_dir, 'profiles')
    end

    # Per-pool runstate directory with profile cache
    def self.cache_dir(pool)
      File.join(pool.apparmor_dir, 'cache')
    end

    def self.assets(add, pool)
      add.directory(
        profile_dir(pool),
        desc: 'Per-container AppArmor profiles',
        user: 0,
        group: 0,
        mode: 0o700
      )
      add.directory(
        cache_dir(pool),
        desc: 'Cache for apparmor_parser',
        user: 0,
        group: 0,
        mode: 0o700
      )
    end

    # Call apparmor_parser
    # @param pool [Pool]
    # @param cmd ["a", "r", "R"]
    # @param profiles [Array<String>] absolute paths to profiles
    # @param opts [Hash] options for `syscmd`
    def self.apparmor_parser(pool, cmd, profiles, opts = {})
      syscmd(
        "apparmor_parser -#{cmd} -W -v #{PATHS.map { |v| "-I #{v}" }.join(' ')} " \
        "-L #{cache_dir(pool)} #{profiles.join(' ')}",
        opts
      )
    end

    # @param ct [Container]
    def initialize(ct)
      @ct = ct
    end

    # Generate container profile, load it and create a namespace
    def setup(run_conf = current_run_conf)
      generate_profile(run_conf)
      load_profile(run_conf)
      create_namespace(run_conf)
    end

    # Generate AppArmor profile for the container
    #
    # The profile is generated only if it has been changed to let
    # `apparmor_parser` use cached profiles for faster container startup times.
    def generate_profile(run_conf = current_run_conf)
      ErbTemplate.render_to_if_changed('apparmor/profile', {
        name: profile_name(run_conf),
        namespace: namespace(run_conf),
        ct:,
        all_combinations_of: lambda do |arr|
          ret = []
          arr.count.times { |i| ret.concat(arr.combination(i + 1).to_a) }
          ret
        end
      }, profile_path(run_conf))
    end

    # Load the container's profile into the kernel
    def load_profile(run_conf = current_run_conf)
      apparmor_parser('r', run_conf:)
    end

    # Remove the container's profile from the kernel
    def unload_profile(run_conf = current_run_conf)
      apparmor_parser('R', { valid_rcs: [254] }, run_conf:)
    end

    # Remove the container's profile from the kernel and remove it from cache
    def destroy_profile(run_conf = current_run_conf)
      unload_profile(run_conf) if File.exist?(profile_path(run_conf))

      begin
        cached = File.join(cache_dir, profile_name(run_conf))
        File.unlink(cached)
      rescue Errno::ENOENT
        # ignore
      end

      begin
        File.unlink(profile_path(run_conf))
      rescue Errno::ENOENT
        # ignore
      end
    end

    # Create an AppArmor namespace for the container
    def create_namespace(run_conf = current_run_conf)
      path = namespace_path(run_conf)
      FileUtils.mkdir_p(path)
    end

    # Destroy the container's AppArmor namespace
    def destroy_namespace(run_conf = current_run_conf)
      path = namespace_path(run_conf)
      FileUtils.rm_f(path)
    end

    def profile_name(run_conf = current_run_conf)
      suffix =
        if run_conf&.generation_cgroups?
          "-#{run_conf.run_id.key}"
        else
          ''
        end

      "ct-#{ct.pool.name}-#{ct.id}#{suffix}"
    end

    def profile_path(run_conf = current_run_conf)
      File.join(self.class.profile_dir(ct.pool), profile_name(run_conf))
    end

    def namespace(run_conf = current_run_conf)
      # Ubuntu's AppArmor service initializes profiles only when in a namespace
      # beginning with `lxd-` or `lxc-`, so we have to use the prefix as well.
      "lxc-#{profile_name(run_conf)}"
    end

    def namespace_profile_name(run_conf = current_run_conf)
      "#{profile_name(run_conf)}//&:#{namespace(run_conf)}:"
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected

    attr_reader :ct

    def namespace_path(run_conf)
      File.join('/sys/kernel/security/apparmor/policy/namespaces', namespace(run_conf))
    end

    def cache_dir
      self.class.cache_dir(ct.pool)
    end

    def apparmor_parser(cmd, opts = {}, run_conf:)
      self.class.apparmor_parser(ct.pool, cmd, [profile_path(run_conf)], opts)
    end

    def current_run_conf
      ct.run_conf || ct.get_past_run_conf
    end
  end
end
