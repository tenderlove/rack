require 'time'
require 'rack/utils'
require 'rack/mime'

module Rack
  # Rack::File serves files below the +root+ directory given, according to the
  # path info of the Rack request.
  # e.g. when Rack::File.new("/etc") is used, you can access 'passwd' file
  # as http://localhost:9292/passwd
  #
  # Handlers can detect if bodies are a Rack::File, and use mechanisms
  # like sendfile on the +path+.

  class File
    ALLOWED_VERBS = %w[GET HEAD OPTIONS]
    ALLOW_HEADER = ALLOWED_VERBS.join(', ')

    attr_accessor :root
    attr_accessor :path
    attr_accessor :cache_control

    alias :to_path :path

    def initialize(root, headers={}, default_mime = 'text/plain')
      @root = root
      @headers = headers
      @default_mime = default_mime
    end

    def call(req, res)
      dup._call(req, res)
    end

    def _call(req, res)
      unless ALLOWED_VERBS.include? req.request_method
        return fail(res, 405, "Method Not Allowed", {'Allow' => ALLOW_HEADER})
      end

      path_info = Utils.unescape(req.path_info)
      clean_path_info = Utils.clean_path_info(path_info)

      @path = ::File.join(@root, clean_path_info)

      available = begin
        ::File.file?(@path) && ::File.readable?(@path)
      rescue SystemCallError
        false
      end

      if available
        serving(req, res)
      else
        fail(res, 404, "File not found: #{path_info}")
      end
    end

    def serving(req, res)
      if req.options?
        res.status = 200
        res.set_header 'Allow', ALLOW_HEADER
        res.set_header CONTENT_LENGTH, '0'
        return res
      end

      last_modified = ::File.mtime(@path).httpdate
      if req.get_header('HTTP_IF_MODIFIED_SINCE') == last_modified
        res.status = 304
        res.body = ''
        return res
      end

      res.set_header "Last-Modified", last_modified
      res.set_header(CONTENT_TYPE, mime_type) if mime_type

      # Set custom headers
      @headers.each { |field, content| res.set_header field, content } if @headers

      res.status = 200
      return res if req.head?

      size = filesize

      ranges = Rack::Utils.byte_ranges(req.get_header("HTTP_RANGE"), size)
      if ranges.nil? || ranges.length > 1
        # No ranges, or multiple ranges (which we don't support):
        # TODO: Support multiple byte-ranges
        res.status = 200
        @range = 0..size-1
      elsif ranges.empty?
        # Unsatisfiable. Return error, and file size:
        res.set_header "Content-Range", "bytes */#{size}"
        return fail(res, 416, "Byte range unsatisfiable")
      else
        # Partial content:
        @range = ranges[0]
        res.status = 206
        res.set_header "Content-Range", "bytes #{@range.begin}-#{@range.end}/#{size}"
        size = @range.end - @range.begin + 1
      end

      res.set_header CONTENT_LENGTH, size.to_s
      if response_body.nil?
        each do |part|
          res.write part
        end
      else
        res.write response_body
      end
      res.finish
    end

    def each
      ::File.open(@path, "rb") do |file|
        file.seek(@range.begin)
        remaining_len = @range.end-@range.begin+1
        while remaining_len > 0
          part = file.read([8192, remaining_len].min)
          break unless part
          remaining_len -= part.length

          yield part
        end
      end
    end

    private

    def fail(res, status, body, headers = {})
      res.status = status
      headers.each_pair { |k,v| res.set_header k, v }
      res.set_header CONTENT_TYPE, 'text/plain'
      res.set_header CONTENT_LENGTH, body.bytesize.to_s

      body += "\n"
      res.body = body
      res
    end

    # The MIME type for the contents of the file located at @path
    def mime_type
      Mime.mime_type(::File.extname(@path), @default_mime)
    end

    def filesize
      # If response_body is present, use its size.
      return Rack::Utils.bytesize(response_body) if response_body

      #   We check via File::size? whether this file provides size info
      #   via stat (e.g. /proc files often don't), otherwise we have to
      #   figure it out by reading the whole file into memory.
      ::File.size?(@path) || ::File.read(@path).bytesize
    end

    # By default, the response body for file requests is nil.
    # In this case, the response body will be generated later
    # from the file at @path
    def response_body
      nil
    end
  end
end
