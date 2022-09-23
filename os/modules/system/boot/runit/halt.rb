#!@ruby@/bin/ruby
require 'optparse'
require 'socket'

class Halt
  def initialize(name, args)
    @name = name
    parse(args)
  end

  def run
    return halt if @force
    @hostname = Socket.gethostname

    confirm
    countdown
    halt
  end

  protected
  def parse(args)
    @force = false
    @action = default_action

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

  def confirm
    puts "The following containers will be stopped:"
    puts

    st = Kernel.system('osctl', 'ct', 'ls', '-S', 'running')
    fail "Unable to list containers" unless st

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

    begin
      shutdown_pid = Process.fork do
        Kernel.exec('osctl', 'shutdown', '--force', pgroup: true)
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
