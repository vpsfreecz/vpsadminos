module ImagePipeline
  module Selection
    def self.full_ci_requested?(event:, requested:)
      event == 'schedule' || (event == 'workflow_dispatch' && requested)
    end

    def self.items(items, names:, automatic:)
      return items if names.nil? || names == 'all'

      selected = names.split(',')
      matching = items.select { |item| selected.include?(item['name']) || selected.include?(item['name'].split('#').first) }
      found = matching.flat_map { |item| [item['name'], item['name'].split('#').first] }
      unknown = selected - found
      raise "unknown selected images: #{unknown}" if !automatic && unknown.any?
      raise 'no configured images selected' if !automatic && matching.empty?

      matching
    end
  end
end
