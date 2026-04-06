# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::ExampleGroup do
  let(:config) { TestRunner::ExampleConfiguration.new }
  let(:noop) { proc {} }

  it 'composes messages from parent groups' do
    parent = described_class.new('parent', config:, &noop)
    child = described_class.new('child', config:, parent:, &noop)

    expect(child.message).to eq('parent child')
  end

  it 'adds child groups and examples' do
    group = described_class.new('group', config:, &noop)
    child = described_class.new('child', config:, parent: group, &noop)
    example = TestRunner::Example.new(group, 'works', &noop)

    group.add_group(child)
    group.add_example(example)

    expect(group.groups).to eq([child])
    expect(group.examples).to eq([example])
  end

  it 'runs before and after hooks around context and examples' do
    events = []
    group = nil
    group = described_class.new('group', config:) do
      group.add_before(:context, proc { events << :before_context })
      group.add_before(:example, proc { events << :before_example })
      group.add_after(:example, proc { events << :after_example })
      group.add_after(:context, proc { events << :after_context })
      group.add_example(TestRunner::Example.new(group, 'works') { events << :example })
    end

    group.load
    group.evaluate

    expect(events).to eq(
      %i[before_context before_example example after_example after_context]
    )
  end

  it 'delegates ordering to ExampleOrdering' do
    group = nil
    group = described_class.new('group', config:, order: :defined) do
      group.add_example(TestRunner::Example.new(group, 'first', &noop))
    end
    allow(TestRunner::ExampleOrdering).to receive(:sort_by_order).and_call_original

    group.load
    group.evaluate

    expect(TestRunner::ExampleOrdering).to have_received(:sort_by_order).at_least(:once)
  end

  it 'omits skipped examples from evaluation' do
    group = nil
    group = described_class.new('group', config:) do
      group.add_example(TestRunner::Example.new(group, 'skip', skip: true, &noop))
      group.add_example(TestRunner::Example.new(group, 'run', &noop))
    end

    group.load
    results = group.evaluate

    expect(results.map(&:title)).to eq(['group run'])
  end

  it 'concatenates nested group results' do
    parent = nil
    parent = described_class.new('parent', config:) do
      parent.add_example(TestRunner::Example.new(parent, 'one', &noop))
    end
    child = nil
    child = described_class.new('child', config:, parent:) do
      child.add_example(TestRunner::Example.new(child, 'two', &noop))
    end

    parent.load
    child.load
    parent.add_group(child)

    expect(parent.evaluate.map(&:title)).to eq(['parent one', 'parent child two'])
  end
end
