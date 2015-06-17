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

    class BufferedResponse < SimpleDelegator
      def initialize res
        super
        @buffer = []
      end

      def write chunk
        @buffer << chunk
      end

      def buffer
        @buffer
      end

      def replace(buffer)
        @buffer = buffer
      end

      def finish
        if !Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.include?(status.to_i) &&
          !get_header(CONTENT_LENGTH) &&
          !get_header(TRANSFER_ENCODING)

          set_header CONTENT_LENGTH, @buffer.map { |part| part.bytesize }.inject(:+).to_s
        end

        @buffer.each { |chunk| __getobj__.write chunk }
        super
      end
    end

    def call(req, res)
      buffered_res = BufferedResponse.new res
      @app.call req, buffered_res
    end
  end
end
