require 'rack'
require 'prometheus/middleware/exporter'
require 'libosctl'
require 'osctl/exporter'

Thread.abort_on_exception = true
OsCtl::Lib::Logger.setup(:stdout)
OsCtl::Exporter::Collector.start

use Rack::Deflater
use Prometheus::Middleware::Exporter, { registry: OsCtl::Exporter.registry }

run ->(_) { [200, { 'Content-Type' => 'text/html' }, ['OK']] }
