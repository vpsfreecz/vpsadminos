# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Oomd::ContainerScore do
  subject(:container) { described_class.new('tank', 'ct1') }

  it 'increments hit counters and timestamps on hit' do
    allow(Time).to receive(:now).and_return(Time.at(1), Time.at(2))

    container.hit

    expect(container.restart_hits).to eq(1)
    expect(container.stop_hits).to eq(1)
    expect(container.first_hit).to eq(Time.at(1))
    expect(container.last_hit).to eq(Time.at(2))
  end

  it 'decrements counters on miss without going below zero' do
    container.hit
    container.miss
    container.miss

    expect(container.restart_hits).to eq(0)
    expect(container.stop_hits).to eq(0)
  end

  it 'resets only restart hits' do
    container.hit
    container.reset_restart_hits

    expect(container.restart_hits).to eq(0)
    expect(container.stop_hits).to eq(1)
  end

  it 'resets only stop hits' do
    container.hit
    container.reset_stop_hits

    expect(container.restart_hits).to eq(1)
    expect(container.stop_hits).to eq(0)
  end
end
