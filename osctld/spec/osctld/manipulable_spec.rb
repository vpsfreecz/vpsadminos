# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/manipulable'

RSpec.describe OsCtld::Manipulable do
  subject(:fixture) { fixture_class.new }

  let(:fixture_class) do
    Class.new do
      include OsCtld::Manipulable

      def initialize
        init_manipulable
      end

      def manipulation_resource
        %w[fixture alpha]
      end
    end
  end
  let(:holder) { holder_class.new('holder-1') }
  let(:other_holder) { holder_class.new('holder-2') }

  let(:holder_class) do
    Struct.new(:name) do
      def manipulation_holder
        name
      end
    end
  end

  it 'manipulates with a block and releases afterwards' do
    expect(fixture.manipulate(holder, block: true) { fixture.manipulated_by }).to eq(holder)
    expect(fixture.is_being_manipulated?).to be(false)
    expect(fixture.manipulated_by).to be_nil
  end

  it 'supports manual acquire and release' do
    expect(fixture.acquire_manipulation_lock(holder)).to be(true)
    expect(fixture.is_being_manipulated?).to be(true)
    expect(fixture.manipulated_by).to eq(holder)

    fixture.release_manipulation_lock

    expect(fixture.is_being_manipulated?).to be(false)
    expect(fixture.manipulated_by).to be_nil
  end

  it 'allows the same thread to re-enter without deadlocking' do
    fixture.acquire_manipulation_lock(holder)

    expect(fixture.manipulate(other_holder) { :nested }).to eq(:nested)
    expect(fixture.manipulated_by).to eq(holder)

    fixture.release_manipulation_lock
  end

  it 'raises ResourceLocked for a second thread when block is false' do
    fixture.acquire_manipulation_lock(holder)

    result = Queue.new

    waiter = Thread.new do
      fixture.acquire_manipulation_lock(other_holder)
      result << :acquired
    rescue StandardError => e
      result << e
    end

    error = pop_with_timeout(result)

    expect(error).to be_a(OsCtld::ResourceLocked)
    expect(error.resource).to eq(fixture)
    expect(error.holder).to eq(holder)

    fixture.release_manipulation_lock
    waiter.join
  end

  it 'waits for a second thread when block is true' do
    fixture.acquire_manipulation_lock(holder)

    events = Queue.new

    waiter = Thread.new do
      events << :attempting
      fixture.manipulate(other_holder, block: true) do
        events << :acquired
      end
    end

    expect(pop_with_timeout(events)).to eq(:attempting)
    expect(fixture.manipulated_by).to eq(holder)

    fixture.release_manipulation_lock

    expect(pop_with_timeout(events)).to eq(:acquired)
    waiter.join
  end
end
