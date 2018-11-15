require 'libosctl'

module OsCtld
  # Manipulate localhost hostnames in `/etc/hosts` like files
  class EtcHosts
    include OsCtl::Lib::Utils::File

    # @return [String]
    attr_reader :path

    # @param path [String] path to the hosts file
    def initialize(path)
      @path = path
    end

    # @param hostname [OsCtl::Lib::Hostname]
    def set(hostname)
      names = all_names(hostname)

      do_edit(names) do |line|
        next(line) if (/^127\.0\.0\.1\s/ !~ line && /^::1\s/ !~ line)

        new_line = line.strip
        last = nil

        names.each do |name|
          next if includes_name?(new_line, name)

          new_line = add_name(new_line, name, after: last)
          last = name
        end

        new_line << "\n"
        new_line
      end
    end

    # @param old_hostname [OsCtl::Lib::Hostname]
    # @param new_hostname [OsCtl::Lib::Hostname]
    def replace(old_hostname, new_hostname)
      old_names = all_names(old_hostname)
      new_names = all_names(new_hostname)

      do_edit(new_names) do |line|
        next(line) if (/^127\.0\.0\.1\s/ !~ line && /^::1\s/ !~ line)

        new_line = line.strip
        last = nil

        zip_all(new_names, old_names).each do |new_name, old_name|
          if old_name && includes_name?(new_line, old_name)
            new_line = replace_name(new_line, old_name, new_name || '')
          elsif new_name
            new_line = add_name(new_line, new_name, after: last)
          end

          last = new_name
        end

        new_line << "\n"
        new_line
      end
    end

    protected
    # Edit the hosts file and let the caller transform it
    #
    # If the target file exists, it is read and each line is yielded to the
    # caller. The caller returns the new value that is written to the target
    # file instead of the original line.
    #
    # If the target file does not exist, it is created and populated with
    # `names`. Nothing is yielded to the caller in that case.
    #
    # @param names [Array<String>] list of hostnames to set
    def do_edit(names)
      regenerate_file(path, 0644) do |new, old|
        if old
          old.each_line do |line|
            new.write(yield(line))
          end

        else
          new.write(<<END
127.0.0.1       #{(names + %w(localhost)).join(' ')}
::1             #{(names + %w(localhost ip6-localhost ip6-loopback)).join(' ')}
END
          )
        end
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
        "#{$1}#{$2}#{name} #{line[i..-1]}"
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
