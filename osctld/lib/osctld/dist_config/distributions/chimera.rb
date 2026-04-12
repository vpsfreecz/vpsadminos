require 'osctld/dist_config/distributions/debian'

module OsCtld
  class DistConfig::Distributions::Chimera < DistConfig::Distributions::Debian
    distribution :chimera

    def apply_hostname
      ct_syscmd(ct, ['hostname', ct.hostname.local])
    rescue SystemCommandFailed => e
      log(:warn, ct, "Unable to apply hostname: #{e.message}")
    end

    def chpasswd_command
      # Without the -c switch, the password is not set (bug?)
      %w[chpasswd -c SHA512]
    end
  end
end
