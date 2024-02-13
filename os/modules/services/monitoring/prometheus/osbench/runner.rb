#!@ruby@/bin/ruby

class Runner
  def initialize(textfile_dir, osbench, test, args)
    @textfile_dir = textfile_dir
    @osbench = osbench
    @test = test
    @args = args
  end

  def run!
    result = `su -s /bin/sh - nobody -c "#{@osbench}/bin/#{@test} #{@args}"`
    error! if $?.exitstatus != 0

    time, unit, = result.strip.split("\n").last.split(' ')
    error! if time.nil? || time.to_f == 0 || unit.nil?

    success!(time, translate_unit(unit))
  end

  protected

  def success!(time, unit)
    write do |f|
      write_status(f, true)
      write_result(f, time, unit)
    end

    exit(true)
  end

  def error!
    write { |f| write_status(f, false) }
    exit(false)
  end

  def write_status(f, success)
    metric = "osbench_#{@test}_success"

    f.puts "# HELP #{metric} 1 if the test was successful, 0 if not"
    f.puts "# TYPE #{metric} gauge"
    f.puts "#{metric} #{success ? 1 : 0}"
  end

  def write_result(f, time, unit)
    metric = "osbench_#{@test}_#{unit}"
    f.puts "# HELP #{metric} Fastest measurement from the test run in #{unit}"
    f.puts "# TYPE #{metric} gauge"
    f.puts "#{metric} #{time}"
  end

  def write(&)
    dst = "#{@textfile_dir}/osbench-#{@test}.prom"
    tmp = "#{dst}.tmp"

    File.open(tmp, 'w', &)
    File.rename(tmp, dst)
  end

  def translate_unit(unit)
    case unit
    when 'us'
      'microseconds'
    when 'ns'
      'nanoseconds'
    else
      error!
    end
  end
end

if ARGV.length < 3
  warn "Usage: #{$0} <output dir> <osbench path> <test name> [test args...]"
  exit(false)
end

textfile_dir, osbench, test, args = ARGV
runner = Runner.new(textfile_dir, osbench, test, args)
runner.run!
