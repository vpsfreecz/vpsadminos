#!/usr/bin/env ruby
require 'json'
require 'optparse'
require 'digest'
require 'fileutils'
require_relative 'lib/image_pipeline/coordinator'
require_relative 'lib/image_pipeline/selection'
require_relative 'lib/image_pipeline/admission'

options = {}
OptionParser.new do |parser|
  %w[machine-config plan source-dir state-dir producer publisher url run-id event ref input-graph images].each do |key|
    parser.on("--#{key} VALUE") { |value| options[key] = value }
  end
  parser.on('--full-ci') { options['full-ci'] = true }
  parser.on('--workers N|auto') { |value| options['workers'] = value }
  %w[max-memory-mib max-cpus attempt lease-seconds].each do |key|
    parser.on("--#{key} N", Integer) { |value| options[key] = value }
  end
end.parse!

full_ci = ImagePipeline::Selection.full_ci_requested?(event: options.fetch('event'), requested: options.fetch('full-ci', false))

source_dir = File.realpath(options.fetch('source-dir'))
state = File.expand_path(options.fetch('state-dir'))
raise 'state must be outside source shared with guests' if state.start_with?("#{source_dir}/")

FileUtils.mkdir_p(state)
sha = IO.popen(['git', '-C', source_dir, 'rev-parse', 'HEAD'], &:read).strip
source = { 'sha' => sha, 'input_digest' => Digest::SHA256.file(options.fetch('input-graph')).hexdigest,
           'ref' => options.fetch('ref'), 'event' => options.fetch('event') }
plan = JSON.parse(File.read(options.fetch('plan')))
plan['items'] = ImagePipeline::Selection.items(plan.fetch('items'), names: options['images'],
                                                                    automatic: options.fetch('event') == 'push')
if plan.fetch('items').empty?
  warn 'No configured image changes; skipping candidate run'
  exit
end
require_relative 'lib/image_pipeline/pool'

plan.fetch('items').each do |item|
  path = File.join(source_dir, 'image-scripts/images', item.fetch('name').split('#').first, 'config.sh')
  # Literal builder names are hints only; actual configuration is captured in
  # the assigned guest. No date-dependent configuration is evaluated here.
  item['builder'] = File.read(path)[/^BUILDER=([\w.-]+)$/, 1]
end

# Share only committed source, not the checkout's credentials, untracked caches
# or another job's state. Source/input receipts remain outside guest mounts.
snapshot = File.join(state, 'source')
FileUtils.mkdir_p(snapshot)
statuses = Open3.pipeline(['git', '-C', source_dir, 'archive', '--format=tar', sha], ['tar', '-x', '-C', snapshot])
raise 'source archive failed' unless statuses.all?(&:success?)

File.write(File.join(snapshot, '.vpsadminos-git-rev'), "#{sha}\n")

config = JSON.parse(File.read(options.fetch('machine-config'))).fetch('machines').fetch('machine')
admission = ImagePipeline::Admission.new(config:, item_count: plan.fetch('items').length, state_dir: state,
                                         workers: options['workers'], max_memory_mib: options['max-memory-mib'],
                                         max_cpus: options['max-cpus'])
File.write(File.join(state, 'admission.json'), "#{JSON.pretty_generate(admission.evidence)}\n")
warn "Admitted #{admission.workers} image worker(s) from current runner resources"

producer = ImagePipeline::Control.new(options.fetch('producer'), repository: 'vpsadminos',
                                                                 receipts: File.join(state, 'producer'))
coordinator = ImagePipeline::Coordinator.new(control: producer, repository_url: options.fetch('url'),
                                             source:, plan:, state_dir: state, run_id: options.fetch('run-id'),
                                             attempt: options.fetch('attempt'), lease_seconds: options.fetch('lease-seconds'), full_ci:)
summary = { 'source' => source, 'plan' => plan, 'run' => coordinator.run, 'admission' => admission.evidence }

finished = Queue.new
heartbeat = Thread.new do
  loop do
    break unless finished.empty?

    sleep([options.fetch('lease-seconds') / 3, 300].min)
    break unless finished.empty?

    coordinator.renew(options.fetch('lease-seconds'))
  end
end
begin
  factory = lambda do |index|
    ImagePipeline::Worker.new(index, config:, root: state, source: sha, source_dir: snapshot,
                                     bind: coordinator.method(:bind))
  end
  ImagePipeline::Pool.new(
    plan.fetch('items'), workers: admission.workers, factory:, result: coordinator.method(:result)
  ).run
rescue StandardError => e
  summary['error'] = "#{e.class}: #{e.message}"
ensure
  finished << true
  heartbeat.kill
  heartbeat.join
  begin
    summary['url'] = coordinator.finish
  rescue StandardError => e
    summary['seal_error'] = "#{e.class}: #{e.message}"
  end
  summary['verified'] = coordinator.verified
  summary['failures'] = coordinator.failures
  summary['full_ci'] = { 'requested' => full_ci, 'ready' => coordinator.ci_ready }
  if full_ci && !coordinator.ci_ready
    summary['full_ci']['reason'] = summary['seal_error'] || summary['error'] || 'selected images failed or run could not seal'
  end
  File.write(File.join(state, 'run.json'), "#{JSON.pretty_generate(summary)}\n")
end
raise summary.fetch('error') if summary['error']
raise 'one or more images failed, or requested CI view unavailable' unless summary['url']
