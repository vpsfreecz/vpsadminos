#!@ruby@/bin/ruby
require 'optparse'
require 'socket'
require 'syslog/logger'
require 'tempfile'

class Halt
  REASON_TEMPLATE_DIR = '/etc/runit/halt.reason.d'

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

      opts.on('-m', '--message MSG', 'Send message to logged-in container users') do |v|
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
      fail "invalid executable name #{@name.inspect}"
    end
  end

  def reason
    return if @message

    file = Tempfile.new("#{@action}-reason")
    file.puts(<<END)
# Reason for #{@action} of #{@hostname}:
END
    file.flush

    apply_reason_templates(file)

    begin
      unless Kernel.system(ENV['EDITOR'] || 'vim', file.path)
        fail "Failed to get #{@action} reason"
      end

      file.rewind
      @message = file.each_line.reject { |line| line.start_with?('#') }.join('')
    ensure
      file.close
      file.unlink
    end
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
    puts "The following containers will be stopped:"
    puts

    st = Kernel.system('osctl', 'ct', 'ls', '-S', 'running')
    fail "Unable to list containers" unless st

    puts
    puts "Reason for #{@action}:"
    puts (@message.empty? ? '[not given]' : @message)
    puts

    loop do
      STDOUT.write("Enter machine hostname to #{@action}: ")
      STDOUT.flush

      if STDIN.readline.strip == @hostname
        return true
      else
        puts "Invalid hostname, this is #{@hostname}"
        puts
      end
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
    puts "Shutting down containers, this operation can still be interrupted"
    puts

    @logger.info("System #{@action}, reason: #{@message}")

    begin
      shutdown_pid = Process.fork do
        cmd = %w(osctl shutdown --force)
        cmd << '--message' << @message if @message && !@message.empty?
        Kernel.exec(*cmd, pgroup: true)
      end
      Process.wait(shutdown_pid)
    rescue Interrupt
      handle_abort(shutdown_pid)
      return
    end

    fail "Unable to shutdown osctld" if $?.exitstatus != 0

    puts "Proceeding with system #{@action}"

    case @action
    when 'poweroff'
      Process.exec('runit-init', '0')
    when 'reboot'
      Process.exec('runit-init', '6')
    else
      fail "invalid action #{@action.inspect}"
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
      warn "Shutdown abort in progress"
      cnt += 1
      retry if cnt <= 5
      raise
    end

    puts
    puts "Some pools may be already exported, disabled, or have stopped containers,"
    puts "see man osctl(8) for more information about shutdown abort."
    exit(false)
  end

  def abort_halt
    begin
      File.unlink('/run/osctl/shutdown')
    rescue Errno::ENOENT
    end

    st = Kernel.system('osctl', 'shutdown', '--abort')
    fail "Unable to abort osctld shutdown" unless st
  end
end

halt = Halt.new(File.basename($0), ARGV)
halt.run
