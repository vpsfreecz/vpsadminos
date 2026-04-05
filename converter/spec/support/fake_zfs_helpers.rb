# frozen_string_literal: true

module FakeZfsHelpers
  FakeSnapshot = Struct.new(:snapshot, keyword_init: true)

  FakeDataset = Struct.new(
    :name,
    :relative_name,
    :descendants,
    :snapshots,
    keyword_init: true
  ) do
    def initialize(**)
      super
      self.descendants ||= []
      self.snapshots ||= []
    end

    def to_s
      name
    end
  end

  def fake_snapshot(name)
    FakeSnapshot.new(snapshot: name)
  end

  def fake_dataset(name:, relative_name: nil, descendants: [], snapshots: [])
    FakeDataset.new(
      name:,
      relative_name: relative_name || name,
      descendants:,
      snapshots:
    )
  end
end

RSpec.configure do |config|
  config.include FakeZfsHelpers
end
