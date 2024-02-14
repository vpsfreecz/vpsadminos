#!@ruby@/bin/ruby
require 'optparse'
require 'socket'
require 'syslog/logger'
require 'tempfile'

class Halt
  REASON_TEMPLATE_DIR = '/etc/runit/halt.reason.d'

  HOOK_DIR = '/etc/runit/halt.hook.d'

  def initialize(name, args)
    @name = name
    @logger = Syslog::Logger.new('halt')
    parse(args)
  end

  def run
    return halt if @force

    @hostname = Socket.gethostname

    reason
    confirm
    countdown
    halt
  end

  protected

  def parse(args)
    @force = false
    @action = default_action
    @wall = true
    @message = nil

    OptionParser.new do |opts|
      opts.banner = "Usage: #{@name} [options]"
      opts.on('-f', '--force', 'Forcefully halt the system') do
        @force = true
      end

      opts.on('-r', '--reboot', 'Reboot the machine') do
        @action = 'reboot'
      end

      opts.on('-p', '--poweroff', 'Power off the machine') do
        @action = 'poweroff'
      end

      opts.on('-w', '--[no-]wall', 'Send message to logged-in container users') do |v|
        @wall = v
      end

      opts.on('-m', '--message MSG', 'Message sent to logged-in container users') do |v|
        @message = v
      end
    end.parse!(args)
  end

  def default_action
    case @name
    when 'halt', 'poweroff'
      'poweroff'
    when 'reboot'
      'reboot'
    else
      raise "invalid executable name #{@name.inspect}"
    end
  end

  def reason
    return if @message

    puts "Composing #{@action} message..."

    file = Tempfile.new("#{@action}-reason")
    file.puts(<<~END)
      # Please enter reason for #{@action} of #{@hostname}.
      # Lines starting with '#' will be ignored, and an empty message will
      # abort #{@action}.
    END

    if @wall
      file.puts('# The reason will be sent to logged-in container users.')
    else
      file.puts('# The reason will be written to system log.')
    end

    file.flush

    apply_reason_templates(file)
    puts

    begin
      unless Kernel.system(ENV['EDITOR'] || 'vim', file.path)
        raise "Failed to get #{@action} reason"
      end

      file.rewind
      @message = file.each_line.reject { |line| line.start_with?('#') }.join('')
    ensure
      file.close
      file.unlink
    end

    return unless @message.empty?

    puts 'Aborting due to empty message'
    exit(false)
  end

  def apply_reason_templates(file)
    begin
      ents = Dir.entries(REASON_TEMPLATE_DIR)
    rescue Errno::ENOENT
      return
    end

    ents.each do |v|
      abs_path = File.join(REASON_TEMPLATE_DIR, v)

      begin
        st = File.stat(abs_path)
      rescue Errno::ENOENT
        next
      end

      next unless st.file?

      if st.executable?
        pid = Process.fork do
          ENV['HALT_ACTION'] = @action
          ENV['HALT_REASON_FILE'] = file.path

          Process.exec(abs_path)
        end

        Process.wait(pid)

        if $?.exitstatus != 0
          warn "Reason template #{abs_path.inspect} failed with exit status #{$?.exitstatus}"
          next
        end

        file.seek(0, IO::SEEK_END)
      else
        file.write(File.read(abs_path))
        file.flush
      end
    end
  end

  def confirm
    puts 'The following containers will be stopped:'
    puts

    st = Kernel.system('osctl', 'ct', 'ls', '-S', 'running')
    raise 'Unable to list containers' unless st

    puts
    puts "Reason for #{@action}:"
    puts(@message.empty? ? '[not given]' : @message)
    puts

    if @wall
      puts 'The reason will be sent to logged-in container users.'
    else
      puts 'The reason will be written to system log.'
    end

    puts

    loop do
      $stdout.write("Enter machine hostname to #{@action}: ")
      $stdout.flush

      return true if $stdin.readline.strip == @hostname

      puts "Invalid hostname, this is #{@hostname}"
      puts
    end
  end

  def countdown
    timeout = 10
    puts

    timeout.times.each do |i|
      puts "#{@action} #{@hostname} in #{timeout - i}..."
      sleep(1)
    end

    puts
  end

  def halt
    puts 'Shutting down containers, this operation can still be interrupted'
    puts

    @logger.info("System #{@action}, reason: #{@message}, wall #{@wall ? 'yes' : 'no'}")

    begin
      shutdown_pid = Process.fork do
        cmd = %w[osctl shutdown --force]

        if @wall
          cmd << '--wall'
          cmd << '--message' << @message if @message && !@message.empty?
        else
          cmd << '--no-wall'
        end

        Kernel.exec(*cmd, pgroup: true)
      end
      Process.wait(shutdown_pid)
    rescue Interrupt
      handle_abort(shutdown_pid)
      return
    end

    raise 'Unable to shutdown osctld' if $?.exitstatus != 0

    run_hook('pre-system')

    puts "Proceeding with system #{@action}"

    case @action
    when 'poweroff'
      Process.exec('runit-init', '0')
    when 'reboot'
      Process.exec('runit-init', '6')
    else
      raise "invalid action #{@action.inspect}"
    end
  end

  def run_hook(name)
    puts "Executing #{name} hooks"

    begin
      hooks = Dir.entries(HOOK_DIR)
    rescue Errno::ENOENT
      return
    end

    hooks.each do |hook|
      abs_path = File.join(HOOK_DIR, hook)

      begin
        st = File.stat(abs_path)
      rescue Errno::ENOENT
        next
      end

      next if !st.file? || !st.executable?

      pid = Process.fork do
        ENV['HALT_HOOK'] = name
        ENV['HALT_ACTION'] = @action
        ENV['HALT_REASON'] = @message

        Process.exec(abs_path)
      end

      Process.wait(pid)

      if $?.exitstatus != 0
        warn "Halt hook #{abs_path.inspect} failed with exit status #{$?.exitstatus}"
      end
    end
  end

  def handle_abort(shutdown_pid)
    puts "Aborting #{@action} of #{@hostname}"

    begin
      abort_halt
    rescue Interrupt
      retry
    end

    cnt = 0

    begin
      Process.wait(shutdown_pid)
    rescue Interrupt
      warn 'Shutdown abort in progress'
      cnt += 1
      retry if cnt <= 5
      raise
    end

    puts
    puts 'Some pools may be already exported, disabled, or have stopped containers,'
    puts 'see man osctl(8) for more information about shutdown abort.'
    exit(false)
  end

  def abort_halt
    begin
      File.unlink('/run/osctl/shutdown')
    rescue Errno::ENOENT
    end

    st = Kernel.system('osctl', 'shutdown', '--abort')
    raise 'Unable to abort osctld shutdown' unless st
  end
end

halt = Halt.new(File.basename($0), ARGV)
halt.run
