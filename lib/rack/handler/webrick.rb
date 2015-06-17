require 'webrick'
require 'stringio'
require 'rack/content_length'

# This monkey patch allows for applications to perform their own chunking
# through WEBrick::HTTPResponse iff rack is set to true.
class WEBrick::HTTPResponse
  attr_accessor :rack

  alias _rack_setup_header setup_header
  def setup_header
    app_chunking = rack && @header['transfer-encoding'] == 'chunked'

    @chunked = app_chunking if app_chunking

    _rack_setup_header

    @chunked = false if app_chunking
  end
end

module Rack
  module Handler
    class WEBrick < ::WEBrick::HTTPServlet::AbstractServlet
      def self.run(app, options={})
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : nil

        options[:BindAddress] = options.delete(:Host) || default_host
        options[:Port] ||= 8080
        @server = ::WEBrick::HTTPServer.new(options)
        @server.mount "/", Rack::Handler::WEBrick, app
        yield @server  if block_given?
        @server.start
      end

      def self.valid_options
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : '0.0.0.0'

        {
          "Host=HOST" => "Hostname to listen on (default: #{default_host})",
          "Port=PORT" => "Port to listen on (default: 8080)",
        }
      end

      def self.shutdown
        @server.shutdown
        @server = nil
      end

      def initialize(server, app)
        super server
        @app = app
      end

      class Response
        def initialize webrick_response, socket
          @webrick_response = webrick_response
          @socket           = socket
        end

        def has_header? key
          @webrick_response.header.key? key
        end

        def headers
          @webrick_response.header.dup
        end

        def get_header key
          @webrick_response[key]
        end
        alias :[] :get_header

        def status= status
          @webrick_response.status = status
        end

        def status
          @webrick_response.status
        end

        def set_header k, vs
          res = @webrick_response
          if k.downcase == "set-cookie"
            res.cookies.concat vs.split("\n")
          else
            # Since WEBrick won't accept repeated headers,
            # merge the values per RFC 1945 section 4.2.
            res[k] = vs.split("\n").join(", ")
          end
        end
        alias :[]= :set_header

        def write_head status, headers
          self.status = status

          headers.each do |key, value|
            @webrick_response[key] = value
          end
        end

        def write chunk
          @socket.write chunk
        end

        def finish
          @socket.close
        end
      end

      def service(req, res)
        res.rack = true
        env = req.meta_vars
        env.delete_if { |k, v| v.nil? }

        rack_input = StringIO.new(req.body.to_s)
        rack_input.set_encoding(Encoding::BINARY)

        env.update({"rack.version" => Rack::VERSION,
                     "rack.input" => rack_input,
                     "rack.errors" => $stderr,

                     "rack.multithread" => true,
                     "rack.multiprocess" => false,
                     "rack.run_once" => false,

                     "rack.url_scheme" => ["yes", "on", "1"].include?(env[HTTPS]) ? "https" : "http",

                     "rack.hijack?" => true,
                     "rack.hijack" => lambda { raise NotImplementedError, "only partial hijack is supported."},
                     "rack.hijack_io" => nil,
                   })

        env[HTTP_VERSION] ||= env[SERVER_PROTOCOL]
        env[QUERY_STRING] ||= ""
        unless env[PATH_INFO] == ""
          path, n = req.request_uri.path, env[SCRIPT_NAME].length
          env[PATH_INFO] = path[n, path.length-n]
        end
        env[REQUEST_PATH] ||= [env[SCRIPT_NAME], env[PATH_INFO]].join

        rd, wr = IO.pipe
        res.body = rd
        res.chunked = true

        m_req = @app.wrap_request Rack::Request.new env
        m_res = @app.wrap_response Response.new(res, wr), m_req

        @app.call(m_req, m_res)
        m_res.finish
      end
    end
  end
end
