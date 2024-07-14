require 'osctld/dist_config/distributions/debian'

module OsCtld
  class DistConfig::Distributions::Chimera < DistConfig::Distributions::Debian
    distribution :chimera

    def apply_hostname
      ct_syscmd(ct, ['hostname', ct.hostname.local])
    rescue SystemCommandFailed => e
      log(:warn, ct, "Unable to apply hostname: #{e.message}")
    end

    def passwd(opts)
      # Without the -c switch, the password is not set (bug?)
      ret = ct_syscmd(
        ct,
        %w[chpasswd -c SHA512],
        stdin: "#{opts[:user]}:#{opts[:password]}\n",
        run: true,
        valid_rcs: :all
      )

      return true if ret.success?

      log(:warn, ct, "Unable to set password: #{ret.output}")
    end
  end
end
