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
      st = Kernel.system('osctl', 'shutdown', '--force')
    rescue Interrupt
      puts "Aborting #{@action} of #{@hostname}"
      abort_halt
      exit(false)
    end

    fail "Unable to shutdown osctld" unless st

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

  def abort_halt
    begin
      File.unlink('/run/osctl/shutdown')
    rescue Errno::ENOENT
    end
  end
end

halt = Halt.new(File.basename($0), ARGV)
halt.run
