require 'prometheus/middleware/exporter'

class Prometheus::Middleware::Exporter
  orig_formats = Prometheus::Middleware::Exporter::FORMATS
  remove_const(:FORMATS)
  FORMATS = (orig_formats + [OsCtl::Exporter::Formats::Json]).freeze
end
