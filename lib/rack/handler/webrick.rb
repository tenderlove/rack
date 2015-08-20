require 'webrick'
require 'webrick/https'
require 'stringio'
require 'rack/content_length'
require 'ds9'

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

PKEY = OpenSSL::PKey::EC.new "prime256v1"
CERT, KEY = WEBrick::Utils.create_self_signed_cert(2048,
                                                   [['CN', 'localhost']],
                                                   'such secure!')

module Rack
  module Handler
    class WEBrick < ::WEBrick::HTTPServlet::AbstractServlet
      SETTINGS = [ [DS9::Settings::MAX_CONCURRENT_STREAMS, 100] ]

      class HTTP2Response < ::WEBrick::HTTPResponse
        def initialize config, ctx, stream_id
          @ctx = ctx
          @stream_id = stream_id
          super(config)
        end

        def send_header socket
          @header.delete 'connection'
          headers = [[':status', @status.to_s]] + @header.map { |key, value|
            [key.downcase, value.to_s]
          } + @cookies.map { |cookie| ['set-cookie', cookie.to_s] }
          @ctx.submit_response @stream_id, headers
        end

        def send_body io
        end
      end

      class HTTP2Request < ::WEBrick::HTTPRequest
        def parse socket, headers
          @socket = socket
          begin
            @peeraddr = socket.respond_to?(:peeraddr) ? socket.peeraddr : []
            @addr = socket.respond_to?(:addr) ? socket.addr : []
          rescue Errno::ENOTCONN
            raise HTTPStatus::EOFError
          end

          @request_time = Time.now
          @request_method = headers[':method']
          @unparsed_uri   = headers[':path']
          @http_version   = ::WEBrick::HTTPVersion.new '2.0'
          @request_line = "#{headers[':method']} #{headers[':path']} HTTP/2.0"

          @request_uri = URI.parse "#{headers[':scheme']}://#{headers[':authority']}#{headers[':path']}"

          @header = headers.each_with_object(Hash.new([].freeze)) do |(k,v), h|
            h[k] = [v]
          end

          @header['cookie'].each{|cookie|
            @cookies += ::WEBrick::Cookie::parse(cookie)
          }
          @accept = ::WEBrick::HTTPUtils.parse_qvalues(self['accept'])
          @accept_charset = ::WEBrick::HTTPUtils.parse_qvalues(self['accept-charset'])
          @accept_encoding = ::WEBrick::HTTPUtils.parse_qvalues(self['accept-encoding'])
          @accept_language = ::WEBrick::HTTPUtils.parse_qvalues(self['accept-language'])
          return if @request_method == "CONNECT"
          return if @unparsed_uri == "*"

          begin
            setup_forwarded_info
            @path = ::WEBrick::HTTPUtils::unescape(@request_uri.path)
            @path = ::WEBrick::HTTPUtils::normalize_path(@path)
            @host = @request_uri.host
            @port = @request_uri.port
            @query_string = @request_uri.query
            @script_name = ""
            @path_info = @path.dup
          rescue
            raise ::WEBrick::HTTPStatus::BadRequest, "bad URI `#{@unparsed_uri}'."
          end

          @keep_alive = true
        end
      end

      class HTTP2Server < ::WEBrick::HTTPServer
        def setup_ssl_context config
          ctx = super
          ctx.ssl_version   = "SSLv23_server"
          ctx.npn_protocols = [DS9::PROTO_VERSION_ID]
          ctx.tmp_ecdh_callback = ->(ssl, export, len) { PKEY }
          ctx
        end

        def run socket
          return super unless socket.npn_protocol == 'h2'

          session = MySession.new socket, self
          session.submit_settings SETTINGS
          session.run
        end
      end

      class MySession < DS9::Server
        def initialize sock, server
          super()
          @sock = sock
          @config = server.config
          @server = server
          @write_streams = {}
          @read_streams = {}
        end

        def on_data_source_read stream_id, length
          @write_streams[stream_id].read(length)
        end

        def on_stream_close id, error_code
          @write_streams.delete id
          @read_streams.delete id
        end

        def on_begin_headers frame
          @read_streams[frame.stream_id] = {}
        end

        def on_header name, value, frame, flags
          @read_streams[frame.stream_id][name] = value
        end

        def on_frame_recv frame
          return unless frame.headers?

          res = HTTP2Response.new(@config, self, frame.stream_id)
          req = HTTP2Request.new(@config)
          req.parse @sock, @read_streams[frame.stream_id]

          res.request_method = req.request_method
          res.request_uri = req.request_uri
          res.request_http_version = req.http_version
          res.keep_alive = false

          begin
            @server.service req, res
            @write_streams[frame.stream_id] = StringIO.new(res.body)
          rescue ::WEBrick::HTTPStatus::EOFError, ::WEBrick::HTTPStatus::RequestTimeout => ex
            res.set_error(ex)
          rescue ::WEBrick::HTTPStatus::Error => ex
            @server.logger.error(ex.message)
            res.set_error(ex)
          rescue ::WEBrick::HTTPStatus::Status => ex
            res.status = ex.code
          rescue StandardError => ex
            @server.logger.error(ex)
            res.set_error(ex, true)
          ensure
            res.send_response(nil)
            @server.access_log(@config, req, res)
          end

          true
        end

        def send_event string
          @sock.write string
        end

        def recv_event length
          return '' unless want_read? || want_write?

          case data = @sock.read_nonblock(length, nil, exception: false)
          when :wait_readable
            DS9::ERR_WOULDBLOCK
          when nil
            DS9::ERR_EOF
          else
            data
          end
        end

        def run
          while want_read? || want_write?
            if want_read?
              @sock.to_io.wait_readable
              begin
                return if @sock.eof?
              rescue OpenSSL::SSL::SSLError
                return
              end
              receive
            end

            if want_write?
              @sock.to_io.wait_writable
              send
            end
          end
        end
      end

      def self.run(app, options={})
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : nil

        options[:BindAddress] = options.delete(:Host) || default_host
        options[:Port] ||= 8080
        options.merge!(SSLEnable: true,
                       SSLCertificate: CERT,
                       SSLPrivateKey: KEY)

        @server = HTTP2Server.new(options)
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

        env.update(
          RACK_VERSION      => Rack::VERSION,
          RACK_INPUT        => rack_input,
          RACK_ERRORS       => $stderr,
          RACK_MULTITHREAD  => true,
          RACK_MULTIPROCESS => false,
          RACK_RUNONCE      => false,
          RACK_URL_SCHEME   => ["yes", "on", "1"].include?(env[HTTPS]) ? "https" : "http",
          RACK_IS_HIJACK    => true,
          RACK_HIJACK       => lambda { raise NotImplementedError, "only partial hijack is supported."},
          RACK_HIJACK_IO    => nil
        )

        env[HTTP_VERSION] ||= env[SERVER_PROTOCOL]
        env[QUERY_STRING] ||= ""
        unless env[PATH_INFO] == ""
          path, n = req.request_uri.path, env[SCRIPT_NAME].length
          env[PATH_INFO] = path[n, path.length-n]
        end
        env[REQUEST_PATH] ||= [env[SCRIPT_NAME], env[PATH_INFO]].join

        io = StringIO.new
        m_req = @app.wrap_request Rack::Request.new env
        m_res = @app.wrap_response Response.new(res, io), m_req

        @app.call(m_req, m_res)
        m_res.finish
        res.body = io.string
      end
    end
  end
end
