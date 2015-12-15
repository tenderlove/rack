require 'rack'
require 'digest/md5'
require 'rack/response'

module Rack
  # Automatically sets the ETag header on all String bodies.
  #
  # The ETag header is skipped if ETag or Last-Modified headers are sent or if
  # a sendfile body (body.responds_to :to_path) is given (since such cases
  # should be handled by apache/nginx).
  #
  # On initialization, you can pass two parameters: a Cache-Control directive
  # used when Etag is absent and a directive when it is present. The first
  # defaults to nil, while the second defaults to "max-age=0, private, must-revalidate"
  class ETag
    ETAG_STRING = Rack::ETAG
    DEFAULT_CACHE_CONTROL = "max-age=0, private, must-revalidate".freeze


    def initialize(app, no_cache_control = nil, cache_control = DEFAULT_CACHE_CONTROL)
      @app = app
      @cache_control = cache_control
      @no_cache_control = no_cache_control
    end

    def call(req, res)
      res = Rack::Response::Buffered.new res
      @app.call(req, res)

      if etag_status?(res.status) && etag_body?(res.buffer) && !skip_caching?(req)
        digest, new_body = digest_body(res.buffer)
        res.replace new_body
        res.set_header(ETAG_STRING, %(W/"#{digest}")) if digest
      end

      unless res.get_header(CACHE_CONTROL)
        if digest
          res.set_header(CACHE_CONTROL, @cache_control) if @cache_control
        else
          res.set_header(CACHE_CONTROL, @no_cache_control) if @no_cache_control
        end
      end
    end

    private

      def etag_status?(status)
        status == 200 || status == 201
      end

      def etag_body?(body)
        !body.respond_to?(:to_path)
      end

      def skip_caching?(req)
        (req.get_header(CACHE_CONTROL) && req.get_header(CACHE_CONTROL).include?('no-cache')) ||
          req.get_header(ETAG_STRING) || req.get_header('Last-Modified')
      end

      def digest_body(body)
        parts = []
        digest = nil

        body.each do |part|
          parts << part
          (digest ||= Digest::MD5.new) << part unless part.empty?
        end

        [digest && digest.hexdigest, parts]
      end
  end
end
