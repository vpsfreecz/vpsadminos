module OsCtl::Lib
  class Hostname
    attr_reader :local, :domain, :fqdn

    # @param fqdn [String]
    def initialize(fqdn)
      names = fqdn.split('.')
      @local = names.first
      @domain = names[1..-1].join('.')
      @fqdn = fqdn
    end

    alias_method :to_s, :fqdn
  end
end
