require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::PrLimitSet < Commands::Logged
    handle :ct_prlimit_set

    LIMITS = %w[
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
    ].freeze

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      soft = parse(opts[:soft])
      hard = parse(opts[:hard])

      validate(opts[:name], soft, hard)
      ct.prlimits.set(opts[:name], soft, hard)
      ok
    end

    protected

    def parse(v)
      return v if v.is_a?(Integer)

      error!("a limit must be an integer or 'unlimited'") if v != 'unlimited'

      v
    end

    def validate(name, soft, hard)
      error!("'#{name}' is not supported") unless LIMITS.include?(name)

      return if hard == 'unlimited'

      error!('soft cannot be unlimited when hard is finite') if soft == 'unlimited'
      error!('soft has to be lower than or equal to hard') if soft > hard
    end
  end
end
