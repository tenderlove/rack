require 'rack/body_proxy'

module Rack
  # Rack::Head returns an empty body for all HEAD requests. It leaves
  # all other requests unchanged.
  class Head
    def initialize(app)
      @app = app
    end

    def call(req, res)
      # FIXME: This needs a buffered response that writes 0 bytes if the req
      # is a head.
      @app.call(req, res)

      if req.head?
        res.finish
      end
    end
  end
end
