require 'libosctl'

module OsCtld
  # Manipulate localhost hostnames in `/etc/hosts` like files
  class EtcHosts
    include OsCtl::Lib::Utils::File

    NOTICE_HEAD = '### Start of osctld-generated notice'
    NOTICE_BODY = <<~END
      # This file is updated by osctld from vpsAdminOS on every VPS start to configure
      # the hostname. If you would like to manage the hostname manually,
      # administrators can configure this by `osctl ct unset hostname` and users
      # in VPS details in vpsAdmin. In addition, osctld will not modify this file
      # if the write by user permission is removed:
      #
      #   chmod u-w /etc/hosts
    END
    NOTICE_TAIL = '### End of osctld-generated notice'

    # @return [String]
    attr_reader :path

    # @param path [String] path to the hosts file
    def initialize(path)
      @path = path
    end

    # @param hostname [OsCtl::Lib::Hostname]
    def set(hostname)
      names = all_names(hostname)

      do_edit(names) do |new, old|
        each_line(old) do |line|
          if /^127\.0\.0\.1\s/ !~ line && /^::1\s/ !~ line
            new.write(line)
            next
          end

          new_line = line
          last = nil

          names.each do |name|
            next if includes_name?(new_line, name)

            new_line = add_name(new_line, name, after: last)
            last = name
          end

          new.write(new_line)
        end
      end
    end

    # @param old_hostname [OsCtl::Lib::Hostname]
    # @param new_hostname [OsCtl::Lib::Hostname]
    def replace(old_hostname, new_hostname)
      old_names = all_names(old_hostname)
      new_names = all_names(new_hostname)

      do_edit(new_names) do |new, old|
        each_line(old) do |line|
          if /^127\.0\.0\.1\s/ !~ line && /^::1\s/ !~ line
            new.write(line)
            next
          end

          new_line = line
          last = nil

          zip_all(new_names, old_names).each do |new_name, old_name|
            if old_name && includes_name?(new_line, old_name)
              new_line = replace_name(new_line, old_name, new_name || '')
            elsif new_name
              new_line = add_name(new_line, new_name, after: last)
            end

            last = new_name
          end

          new.write(new_line)
        end
      end
    end

    def unmanage
      return unless File.exist?(path)

      regenerate_file(path, 0o644) do |new, old|
        next if old.nil?

        clear_notice(new, old)
      end
    end

    protected

    # Edit the hosts file and let the caller transform it
    #
    # If the target file exists, IOs to both new and old files are yielded.
    #
    # If the target file does not exist, it is created and populated with
    # `names`. Nothing is yielded to the caller in that case.
    #
    # @param names [Array<String>] list of hostnames to set
    #
    # @yieldparam new [IO]
    # @yieldparam old [IO]
    def do_edit(names)
      regenerate_file(path, 0o644) do |new, old|
        write_notice(new)

        if old
          yield(new, old)
        else
          new.puts("127.0.0.1 #{(names + %w[localhost]).join(' ')}")
          new.puts("::1 #{(names + %w[localhost ip6-localhost ip6-loopback]).join(' ')}")
        end
      end
    end

    # Iterate over all lines except the osctld-generated notice
    # @param io [IO]
    # @yieldparam line [String]
    def each_line(io)
      within_notice = false

      io.each_line do |line|
        if line.start_with?(NOTICE_HEAD)
          within_notice = true
          next
        end

        if within_notice
          if !line.start_with?('#') # malformed notice
            within_notice = false
          elsif line.start_with?(NOTICE_TAIL)
            within_notice = false
            next
          end
        end

        yield(line) unless within_notice
      end
    end

    def write_notice(dst)
      dst.puts(NOTICE_HEAD)
      dst.write(NOTICE_BODY)
      dst.puts(NOTICE_TAIL)
    end

    def clear_notice(dst, src)
      inside = false

      src.each_line do |line|
        if line.start_with?(NOTICE_HEAD)
          inside = true
          next
        end

        if inside
          if !line.start_with?('#') # malformed notice
            inside = false
          elsif line.start_with?(NOTICE_TAIL)
            inside = false
            next
          end
        end

        dst.write(line) unless inside
      end
    end

    # Return all names in the order that should be set for a hostname
    # @param hostname [OsCtl::Lib::Hostname]
    def all_names(hostname)
      ret = []

      if hostname.local == hostname.fqdn
        ret << hostname.fqdn
      else
        ret << hostname.fqdn << hostname.local
      end

      ret
    end

    # Check if a line of string contains specific hostname
    # @param line [String]
    # @param name [String]
    def includes_name?(line, name)
      /\s#{Regexp.escape(name)}(\s|$)/ =~ line
    end

    # Add hostname to `line` from `/etc/hosts`
    #
    # The hostname is put into the first position.
    #
    # @param line [String]
    # @param name [String]
    # @param after [String, nil]
    def add_name(line, name, after: nil)
      if after
        replace_name(line, after, "#{after} #{name}")
      else
        return if line !~ /^([^\s]+)(\s+)/

        i = $~.end(2)
        "#{::Regexp.last_match(1)}#{::Regexp.last_match(2)}#{name} #{line[i..-1]}"
      end
    end

    # Replace hostname in `line` read from `/etc/hosts`
    #
    # @param line [String]
    # @param old_name [String]
    # @param new_name [String]
    def replace_name(line, old_name, new_name)
      line.sub(
        /(\s)#{Regexp.escape(old_name)}(\s|$)/,
        "\\1#{new_name}\\2"
      )
    end

    def zip_all(a, b)
      [a.size, b.size].max.times.map { |i| [a[i], b[i]] }
    end
  end
end
