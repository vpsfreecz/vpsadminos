require 'libosctl'
require 'osctld/run_state'

module OsCtld
  class AppArmor
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    extend OsCtl::Lib::Utils::System

    # Paths where `apparmor_parser` searches for configuration files
    PATHS = [RunState::APPARMOR_DIR]

    # Prepare shared files in `/run/osctl`
    def self.setup
      PATHS.concat(Daemon.get.config.apparmor_paths)

      base = File.join(RunState::APPARMOR_DIR, 'osctl')
      features = File.join(base, 'features')

      [base, features].each do |dir|
        Dir.mkdir(dir, 0755) unless Dir.exist?(dir)
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
        Dir.mkdir(dir, 0700) unless Dir.exist?(dir)
      end

      cts = DB::Containers.get.select do |ct|
        next(false) if ct.pool != pool || !ct.running?

        ct.apparmor.generate_profile
        true
      end

      if cts.any?
        apparmor_parser(pool, 'r', cts.map { |ct| ct.apparmor.profile_path })
      end
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
        mode: 0700
      )
      add.directory(
        profile_dir(pool),
        desc: 'Cache for apparmor_parser',
        user: 0,
        group: 0,
        mode: 0700
      )
    end

    # Call apparmor_parser
    # @param pool [Pool]
    # @param cmd ["a", "r", "R"]
    # @param profiles [Array<String>] absolute paths to profiles
    # @param opts [Hash] options for `syscmd`
    def self.apparmor_parser(pool, cmd, profiles, opts = {})
      syscmd(
        "apparmor_parser -#{cmd} -W -v #{PATHS.map { |v| "-I #{v}" }.join(' ')} "+
        "-L #{cache_dir(pool)} #{profiles.join(' ')}",
        opts
      )
    end

    # @param ct [Container]
    def initialize(ct)
      @ct = ct
    end

    # Generate container profile, load it and create a namespace
    def setup
      generate_profile
      load_profile
      create_namespace
    end

    # Generate AppArmor profile for the container
    #
    # The profile is generated only if it has been changed to let
    # `apparmor_parser` use cached profiles for faster container startup times.
    def generate_profile
      ErbTemplate.render_to_if_changed('apparmor/profile', {
        name: profile_name,
        namespace: namespace,
        ct: ct,
        all_combinations_of: ->(arr) do
          ret = []
          arr.count.times { |i| ret.concat(arr.combination(i+1).to_a) }
          ret
        end,
      }, profile_path)
    end

    # Load the container's profile into the kernel
    def load_profile
      apparmor_parser('r')
    end

    # Remove the container's profile from the kernel
    def unload_profile
      apparmor_parser('R', valid_rcs: [254])
    end

    # Remove the container's profile from the kernel and remove it from cache
    def destroy_profile
      unload_profile if File.exist?(profile_path)

      begin
        cached = File.join(cache_dir, profile_name)
        File.unlink(cached)
      rescue Errno::ENOENT
      end
    end

    # Create an AppArmor namespace for the container
    def create_namespace
      path = namespace_path
      Dir.mkdir(path) unless Dir.exist?(path)
    end

    # Destroy the container's AppArmor namespace
    def destroy_namespace
      path = namespace_path
      Dir.rmdir(path) if Dir.exist?(path)
    end

    def profile_name
      "ct-#{ct.pool.name}-#{ct.id}"
    end

    def profile_path
      File.join(self.class.profile_dir(ct.pool), profile_name)
    end

    def namespace
      # Ubuntu's AppArmor service initializes profiles only when in a namespace
      # beginning with `lxd-` or `lxc-`, so we have to use the prefix as well.
      "lxc-#{profile_name}"
    end

    def namespace_profile_name
      "#{profile_name}//&:#{namespace}:"
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    protected
    attr_reader :ct

    def namespace_path
      File.join('/sys/kernel/security/apparmor/policy/namespaces', namespace)
    end

    def cache_dir
      self.class.cache_dir(ct.pool)
    end

    def apparmor_parser(cmd, opts = {})
      self.class.apparmor_parser(ct.pool, cmd, [profile_path], opts)
    end
  end
end
