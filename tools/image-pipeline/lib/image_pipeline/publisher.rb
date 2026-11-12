require 'securerandom'
require_relative 'control'

module ImagePipeline
  class Publisher
    def initialize(summary, control)
      @source = summary.fetch('source')
      @plan = summary.fetch('plan')
      @run = summary.fetch('run')
      @verified = summary.fetch('verified')
      @prefix = "#{@run.fetch('key')}/publisher"
      @control = control
    end

    attr_reader :control

    def publish(source_dir:)
      # Read the current public provenance, never the run baseline. A fresh
      # request follows generation conflicts instead of replaying stale policy.
      superseded = false
      3.times do
        view = control.call('status', key: "#{@prefix}/status/#{SecureRandom.uuid}")
        catalog = view.fetch('catalog')
        policy = catalog['policy_source']
        if superseded || (policy && policy != @source.fetch('sha') &&
           system('git', '-C', source_dir, 'merge-base', '--is-ancestor', @source.fetch('sha'), policy))
          return control.call('publish', { 'generation' => view.fetch('generation'), 'items' => [],
                                           'superseded' => @verified, 'defaults' => {}, 'gc' => [], 'ancestors' => [] },
                              run_key: @run.fetch('key'), key: "#{@prefix}/superseded/#{view.fetch('generation')}")
        end
        ancestors = catalog.fetch('images').filter_map { |image| image['source'] }.uniq
        ancestors << catalog['policy_source'] if catalog['policy_source']
        ancestors.uniq.each do |sha|
          next if sha == @source.fetch('sha')

          unless system('git', '-C', source_dir, 'merge-base', '--is-ancestor', sha, @source.fetch('sha'))
            raise "public source ancestry unavailable or not an ancestor: #{sha}"
          end
        end
        params = { 'generation' => view.fetch('generation'), 'items' => @verified,
                   'defaults' => @plan.fetch('defaults'), 'gc' => @plan.fetch('gc'), 'ancestors' => ancestors }
        begin
          return control.call('publish', params, run_key: @run.fetch('key'),
                                                 key: "#{@prefix}/publish/#{view.fetch('generation')}")
        rescue ControlError => e
          raise unless %w[conflict superseded].include?(e.code)

          superseded = true if e.code == 'superseded'
        end
      end
      raise 'public generation kept advancing'
    end
  end
end
