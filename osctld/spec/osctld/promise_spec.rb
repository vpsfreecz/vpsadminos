# frozen_string_literal: true

require 'osctld/promise'

RSpec.describe OsCtld::Promise do
  subject(:promise) { described_class.new }

  it 'adds tokens that can time out' do
    token = promise.add

    expect(token).to be_a(described_class::Token)
    expect(token.wait(timeout: 0)).to be_nil
  end

  it 'fulfils all waiting tokens and returns nil' do
    token_a = promise.add
    token_b = promise.add

    expect(promise.fulfil).to be_nil
    expect(token_a.wait(timeout: 0)).to be(true)
    expect(token_b.wait(timeout: 0)).to be(true)
  end

  it 'immediately fulfils tokens added after fulfilment' do
    promise.fulfil
    token = promise.add

    expect(token.wait(timeout: 0)).to be(true)
  end

  it 'can be fulfilled repeatedly' do
    token = promise.add

    expect(promise.fulfil).to be_nil
    expect(promise.fulfil).to be_nil
    expect(token.wait(timeout: 0)).to be(true)
  end

  it 'reports fulfilment' do
    expect(promise.fulfilled?).to be(false)

    promise.fulfil

    expect(promise.fulfilled?).to be(true)
  end
end
