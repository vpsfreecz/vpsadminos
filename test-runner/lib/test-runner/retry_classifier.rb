# frozen_string_literal: true

require 'osvm'

module TestRunner
  module RetryClassifier
    ANSI_ESCAPE = %r{\e(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])}
    APT_GENERIC_FAILURES = [
      /^E: Some index files failed to download\./,
      /^E: Unable to fetch some archives/
    ].freeze
    APK_GENERIC_FAILURES = [
      %r{^ERROR: Not continuing due to stale/unavailable repositories\.}
    ].freeze
    APK_FAILURE_SUMMARIES = [
      /^\d+ unavailable, \d+ stale;/,
      /^(?:\d+ errors?|ERRORS);/
    ].freeze
    SWH_PROGRESS = /SWH vault: (?:requested bundle cooking|Processing)/

    module_function

    def apt(error)
      return unless error.is_a?(OsVm::CommandFailed)

      output_lines = command_output_lines(error)
      return unless output_lines.last&.start_with?('E: ')

      error_lines = output_lines.select { |line| line.start_with?('E: ') }
      return unless error_lines.all? do |line|
        generic_failure = APT_GENERIC_FAILURES.any? { |pattern| pattern.match?(line) }
        fetch_failure = line.start_with?('E: Failed to fetch ') && apt_failure_reason(line)

        generic_failure || fetch_failure
      end

      reasons = error_lines.filter_map { |line| apt_failure_reason(line) }
      reasons.last
    end

    def apt_failure_reason(line)
      case line
      when /File has unexpected size.*Mirror sync in progress/
        'APT mirror synchronization race'
      when /Hash Sum mismatch/
        'APT repository metadata changed during download'
      when /(?:Temporary failure resolving|Could not resolve|Could not connect|Connection timed out)/i
        'APT transport failure'
      when /(?:502 Bad Gateway|503 Service Unavailable|504 Gateway Time-out)/i
        'APT mirror HTTP failure'
      when /TLS connection was non-properly terminated/i
        'APT mirror TLS failure'
      end
    end

    def apk(error)
      return unless error.is_a?(OsVm::CommandFailed)

      output_lines = command_output_lines(error)
      terminal_line = output_lines.last
      return unless terminal_line
      return unless APK_FAILURE_SUMMARIES.any? { |pattern| pattern.match?(terminal_line) } ||
                    APK_GENERIC_FAILURES.any? { |pattern| pattern.match?(terminal_line) }

      diagnostic_lines = output_lines.select do |line|
        line.start_with?('WARNING:', 'ERROR:')
      end
      return if diagnostic_lines.empty?

      reasons = diagnostic_lines.filter_map { |line| apk_failure_reason(line) }
      return if reasons.empty?
      return unless diagnostic_lines.all? do |line|
        apk_failure_reason(line) || APK_GENERIC_FAILURES.any? { |pattern| pattern.match?(line) }
      end

      reasons.last
    end

    def apk_failure_reason(line)
      case line
      when /DNS: transient error \(try again later\)/i,
           /temporary error \(try again later\)/i
        'APK transient network failure'
      when /(?:operation|connection) timed out/i
        'APK transport timeout'
      when /(?:network connection aborted|software caused connection abort|could not connect to server|connection (?:reset|refused|aborted)|network is unreachable|network error \(check Internet connection and firewall\)|no route to host)/i
        'APK transport failure'
      when /HTTP (?:408|500|502|503|504):/i
        'APK repository HTTP failure'
      end
    end

    def guix_operation(error)
      return unless error.is_a?(OsVm::CommandFailed)

      terminal_error = command_output_lines(error).reverse.find do |line|
        line.match?(/(?:^|:) error:/i) || line.match?(/Git error:/i)
      end
      return unless terminal_error

      case terminal_error
      when /Git error:.*(?:SSL error|Resource temporarily unavailable|Temporary failure in name resolution|Could not resolve host|Name or service not known|Connection timed out|Connection reset by peer|502 Bad Gateway|503 Service Unavailable|504 Gateway Time-out)/i
        'transient Guix Git failure'
      when /some substitutes .* failed \(usually happens due to networking issues\)/i
        'transient Guix substitute failure'
      end
    end

    def guix_preparation(error)
      return unless error.is_a?(OsVm::CommandFailed)

      if error.message.match?(/failed with status 124\./)
        output_lines = command_output_lines(error)
        progress_index = output_lines.rindex { |line| SWH_PROGRESS.match?(line) }

        if progress_index && output_lines[(progress_index + 1)..].all? { |line| line == 'Terminated' }
          return 'Software Heritage fallback stalled'
        end
      end

      guix_operation(error)
    end

    def command_output_lines(error)
      lines = error.message.lines.map do |line|
        line.gsub(ANSI_ESCAPE, '').strip
      end.reject(&:empty?)
      output_index = lines.index { |line| line.start_with?('Command ') && line.end_with?('Output:') }
      output_lines = output_index ? lines[(output_index + 1)..] : lines

      output_lines.reject { |line| line == 'error: executed command failed' }
    end
    private_class_method :apt_failure_reason
    private_class_method :apk_failure_reason
    private_class_method :command_output_lines
  end
end
