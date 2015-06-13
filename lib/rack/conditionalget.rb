require 'rack/utils'

module Rack

  # Middleware that enables conditional GET using If-None-Match and
  # If-Modified-Since. The application should set either or both of the
  # Last-Modified or Etag response headers according to RFC 2616. When
  # either of the conditions is met, the response body is set to be zero
  # length and the response status is set to 304 Not Modified.
  #
  # Applications that defer response body generation until the body's each
  # message is received will avoid response body generation completely when
  # a conditional GET matches.
  #
  # Adapted from Michael Klishin's Merb implementation:
  # https://github.com/wycats/merb/blob/master/merb-core/lib/merb-core/rack/middleware/conditional_get.rb
  class ConditionalGet
    def initialize(app)
      @app = app
    end

    def call(req, res)
      if req.get? || req.head?
        @app.call(req, res)
        if res.status == 200 && fresh?(req)
          status = 304
          headers.delete(CONTENT_TYPE)
          headers.delete(CONTENT_LENGTH)
          res.replace []
        end
      else
        @app.call(req, res)
      end
    end

  private

    def fresh?(request)
      modified_since = request.get_header 'HTTP_IF_MODIFIED_SINCE'
      none_match     = request.get_header 'HTTP_IF_NONE_MATCH'

      return false unless modified_since || none_match

      success = true
      success &&= modified_since?(to_rfc2822(modified_since), request) if modified_since
      success &&= etag_matches?(none_match, request) if none_match
      success
    end

    def etag_matches?(none_match, request)
      etag = request.get_header('ETag') and etag == none_match
    end

    def modified_since?(modified_since, request)
      last_modified = to_rfc2822(request.get_header('Last-Modified')) and
        modified_since and
        modified_since >= last_modified
    end

    def to_rfc2822(since)
      # shortest possible valid date is the obsolete: 1 Nov 97 09:55 A
      # anything shorter is invalid, this avoids exceptions for common cases
      # most common being the empty string
      if since && since.length >= 16
        # NOTE: there is no trivial way to write this in a non execption way
        #   _rfc2822 returns a hash but is not that usable
        Time.rfc2822(since) rescue nil
      else
        nil
      end
    end
  end
end
