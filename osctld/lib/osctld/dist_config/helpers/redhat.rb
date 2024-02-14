module OsCtld
  module DistConfig::Helpers::RedHat
    # @param file [String]
    # @param params [Hash]
    def set_params(file, params)
      return unless writable?(file)

      regenerate_file(file, 0o644) do |new, old|
        if old
          # Overwrite existing params and keep unchanged ones
          old.each_line do |line|
            param, value = params.detect { |k, _v| /^#{k}=/ =~ line }

            if param
              new.puts("#{param}=\"#{value}\"")
              params.delete(param)

            else
              new.write(line)
            end
          end
        end

        # Write params
        params.each do |k, v|
          new.puts("#{k}=\"#{v}\"")
        end
      end
    end
  end
end
