module OsCtld
  class Commands::Container::PrLimitSet < Commands::Logged
    handle :ct_prlimit_set

    LIMITS = %w(
      as
      core
      cpu
      data
      fsize
      memlock
      msgqueue
      nice
      nofile
      nproc
      rss
      rtprio
      rttime
      sigpending
      stack
    )

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      soft = parse(opts[:soft])
      hard = parse(opts[:hard])

      validate(opts[:name], soft, hard)

      ct.exclusively do
        ct.prlimit_set(opts[:name], soft, hard)
        ok
      end
    end

    protected
    def parse(v)
      return v if v.is_a?(Integer)
      fail "a limit must be an integer or 'unlimited'" if v != 'unlimited'
      v.to_sym
    end

    def validate(name, soft, hard)
      fail "'#{name}' is not supported" unless LIMITS.include?(name)

      if soft.is_a?(Integer) && hard.is_a?(Integer) && soft > hard
        fail "soft has to be lower than hard"

      elsif (soft == :unlimited || hard == :unlimited) && soft != hard
        fail "either both soft and hard are unlimited, or neither is"
      end
    end
  end
end
