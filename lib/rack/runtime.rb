require 'rack/utils'

module Rack
  # Sets an "X-Runtime" response header, indicating the response
  # time of the request, in seconds
  #
  # You can put it right before the application to see the processing
  # time, or before all the other middlewares to include time for them,
  # too.
  class Runtime
    FORMAT_STRING = "%0.6f".freeze # :nodoc:
    HEADER_NAME = "X-Runtime".freeze # :nodoc:

    def initialize(app, name = nil)
      @app = app
      @header_name = HEADER_NAME
      @header_name += "-#{name}" if name
    end

    def call(req, res)
      start_time = clock_time
      @app.call(req, res)
      request_time = clock_time - start_time

      unless res.get_header(@header_name)
        res.set_header(@header_name, FORMAT_STRING % request_time)
      end
    end
  end
end
