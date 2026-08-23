require 'osctld/commands/base'

module OsCtld
  class UserControl::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      UserControl::Command.register(name, self)
    end

    def self.allow_adopted_legacy_callbacks
      @allow_adopted_legacy_callbacks = true
    end

    def self.adopted_legacy_callbacks?
      @allow_adopted_legacy_callbacks == true
    end

    def self.run(user, opts = {})
      ct =
        if opts[:id] && opts[:pool]
          DB::Containers.find(opts[:id], opts[:pool])
        end
      run_id = opts[:run_id]

      if ct && ct.user == user && !run_id && adopted_legacy_callbacks?
        run_id = ct.lifecycle.adopted_legacy_callback_run_id&.to_s
        opts = opts.merge(run_id:) if run_id
      end

      c = new(user, opts)

      unless ct && ct.user == user && run_id
        return c.execute
      end

      reserved_callback_id = Daemon.get.with_lifecycle_admission(
        internal: true,
        continuation: true,
        recovery: true
      ) do
        ct.lifecycle.reserve_callback(
          run_id,
          name: name.split('::').last
        )
      end
      unless reserved_callback_id
        return c.send(:error, 'managed lifecycle callback is fenced')
      end

      callback_id = ct.lifecycle.activate_callback(
        run_id,
        reserved_callback_id,
        name: name.split('::').last
      )
      unless callback_id
        ct.lifecycle.finish_callback(run_id, reserved_callback_id)
        return c.send(:error, 'managed lifecycle callback is fenced')
      end

      c.instance_variable_set(:@lifecycle_callback_id, callback_id)

      begin
        c.execute
      ensure
        effect_id = ct.lifecycle.finish_callback(run_id, callback_id)
        c.send(:spawn_finalizer, ct, run_id, effect_id) if effect_id
      end
    rescue CommandFailed
      c.send(:error, 'managed lifecycle callback is fenced')
    end

    attr_reader :user

    def initialize(user, opts) # rubocop:disable Lint/MissingSuper
      @user = user
      @opts = opts
    end

    protected

    attr_reader :lifecycle_callback_id

    def owns_ct?(ct)
      ct.user == user
    end

    def lifecycle_run_conf(ct)
      run_conf = ct.run_conf || ct.get_past_run_conf
      return unless run_conf
      return unless opts[:run_id]
      return unless run_conf.run_id.to_s == opts[:run_id]

      run_conf
    end

    def lifecycle_run(ct, allow_active: false)
      if opts[:run_id]
        ct.lifecycle.runs.values.detect do |run|
          Container::RunId.load(run.fetch('id')).to_s == opts[:run_id]
        end
      elsif allow_active
        ct.lifecycle.active_run
      end
    end

    def spawn_finalizer(ct, run_id, effect_id)
      run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
        conf.run_id.to_s == run_id.to_s
      end
      return unless run_conf

      require 'osctld/container/lifecycle_finalizer'
      Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id)
    end
  end
end
