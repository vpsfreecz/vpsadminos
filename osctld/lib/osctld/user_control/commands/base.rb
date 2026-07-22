require 'osctld/commands/base'

module OsCtld
  class UserControl::Commands::Base < OsCtld::Commands::Base
    def self.handle(name)
      UserControl::Command.register(name, self)
    end

    def self.run(user, opts = {}, peer: nil)
      c = new(user, opts, peer:)
      c.execute
    end

    attr_reader :user, :peer

    def initialize(user, opts, peer: nil) # rubocop:disable Lint/MissingSuper
      @user = user
      @opts = opts
      @peer = peer
      @authenticated_run_conf = nil
      @lifecycle_event_lease = nil
    end

    protected

    def owns_ct?(ct)
      ct.user == user
    end

    def authenticate_run_callback(ct)
      run_conf = ct.run_conf
      ret = validate_run_callback(ct, run_conf)
      return ret if ret

      @authenticated_run_conf = run_conf
      nil
    rescue SystemCallError, IOError, ArgumentError, TypeError
      error('unable to authenticate callback')
    end

    def authenticate_lifecycle_callback(ct)
      ret = authenticate_run_callback(ct)
      return ret if ret

      validate_lifecycle_peer(@authenticated_run_conf)
    rescue SystemCallError, IOError, ArgumentError, TypeError
      error('unable to authenticate callback')
    end

    # Revalidate the peer while the container's current-run pointer is locked
    # against replacement. The yielded object is exactly the run captured by
    # the initial authentication; a request can never move onto a new run's
    # event ledger.
    def with_authenticated_run(ct, lifecycle: false)
      run_conf = @authenticated_run_conf
      return error('unauthenticated callback') unless run_conf

      ret = nil

      ct.inclusively do
        unless ct.run_conf.equal?(run_conf)
          ret = error('stale container run')
          next
        end

        ret = validate_run_callback(ct, run_conf)
        next if ret

        if lifecycle
          ret = validate_lifecycle_peer(run_conf)
          next if ret
        end

        yield run_conf
      end

      ret
    rescue SystemCallError, IOError, ArgumentError, TypeError
      error('unable to authenticate callback')
    end

    def validate_run_callback(ct, run_conf)
      return error('access denied') unless owns_ct?(ct)
      return error('unauthenticated callback') unless peer&.alive?
      return error('callback does not belong to container') unless peer.in_cgroup_subtree?(ct.base_cgroup_path)
      return error('container run is not active') unless run_conf
      return error('stale container run') unless opts[:run_id].to_s == run_conf.run_id.to_s

      nil
    end

    def validate_lifecycle_peer(run_conf)
      lifecycle_identity = run_conf.lifecycle_identity

      unless lifecycle_identity && peer.descendant_at_depth?(
        lifecycle_identity,
        lifecycle_peer_depth
      )
        return error('callback does not belong to the active container lifecycle')
      end

      nil
    end

    # Most LXC lifecycle hooks are forked directly by lxc-start. Commands
    # invoked from the cloned setup child override this with their exact depth.
    def lifecycle_peer_depth
      1
    end

    def claim_lifecycle_event(ct, event, after: [], lifecycle: true)
      # Event claims are deliberately consumed before privileged effects. If an
      # effect fails after a partial change, the callback remains consumed and
      # cannot be replayed against ambiguous host state.
      lease = nil
      with_authenticated_run(ct, lifecycle:) do |run_conf|
        lease = run_conf.acquire_lifecycle_lease
        run_conf.claim_lifecycle_event(event, after:)
        @lifecycle_event_lease = lease
        lease = nil
      end
    rescue Container::RunConfiguration::LifecycleError => e
      error(e.message)
    ensure
      lease&.close
    end

    # Hold the exact run from the one-shot event claim through every callback
    # effect. Retirement cannot detach that run or admit a replacement until
    # the block finishes.
    def with_claimed_lifecycle_event(ct, event, after: [], lifecycle: true)
      claim_options = { after: }
      claim_options[:lifecycle] = false unless lifecycle
      ret = claim_lifecycle_event(ct, event, **claim_options)
      return ret if ret

      yield authenticated_run_conf
    ensure
      release_lifecycle_event_lease
    end

    def release_lifecycle_event_lease
      lease = @lifecycle_event_lease
      @lifecycle_event_lease = nil
      lease&.close
    end

    attr_reader :authenticated_run_conf

    def container_rootfs_mount(ct)
      rootfs_mount =
        if ct.map_mode == 'native'
          ct.mounts.shared_dir.host_path_for(authenticated_run_conf.rootfs)
        else
          authenticated_run_conf.rootfs
        end

      File.absolute_path(rootfs_mount)
    end

    def peer_in_container_cgroup?(ct)
      peer&.in_cgroup_subtree?(ct.cgroup_path)
    rescue SystemCallError, IOError, ArgumentError
      false
    end
  end
end
