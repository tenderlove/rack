require 'delegate'
require 'rack/utils'
require 'rack/body_proxy'

module Rack

  # Sets the Content-Length header on responses with fixed-length bodies.
  class ContentLength
    include Rack::Utils

    def initialize(app)
      @app = app
    end

    def call(req, res)
      buffered_res = Rack::Response::Buffered.new res
      @app.call req, buffered_res
    end
  end
end
