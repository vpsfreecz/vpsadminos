# frozen_string_literal: true

module FakeCliCompletionHelpers
  FakeSwitch = Struct.new(:forms) do
    def arguments_for_option_parser
      forms
    end
  end

  FakeFlag = Struct.new(:forms, :must_match) do
    def all_forms(_sep)
      forms.join(', ')
    end
  end

  FakeCommand = Struct.new(
    :name,
    :description,
    :commands,
    :switches,
    :flags,
    :arguments_description,
    :aliases,
    keyword_init: true
  )

  FakeApp = Struct.new(:exe_name, :commands, :switches, :flags, keyword_init: true)
end

RSpec.configure do |config|
  config.include FakeCliCompletionHelpers
end
