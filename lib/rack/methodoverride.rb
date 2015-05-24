module Rack
  class MethodOverride
    HTTP_METHODS = %w[GET HEAD PUT POST DELETE OPTIONS PATCH LINK UNLINK]

    METHOD_OVERRIDE_PARAM_KEY = "_method".freeze
    HTTP_METHOD_OVERRIDE_HEADER = "HTTP_X_HTTP_METHOD_OVERRIDE".freeze
    ALLOWED_METHODS = %w[POST]

    class Request < SimpleDelegator
      attr_reader :request_method

      def initialize req, new_method, old
        super(req)
        @request_method = new_method
        @old_req_method = old
      end
    end

    def initialize(app)
      @app = app
    end

    def call(req, res)
      if allowed_methods.include?(req.request_method)
        method = method_override(req)
        if HTTP_METHODS.include?(method)
          req = Request.new(req, method, req.request_method)
        end
      end

      @app.call(req, res)
    end

    def method_override(req)
      method = method_override_param(req) || req.get_header(HTTP_METHOD_OVERRIDE_HEADER)
      method.to_s.upcase
    end

    private

    def allowed_methods
      ALLOWED_METHODS
    end

    def method_override_param(req)
      req.POST[METHOD_OVERRIDE_PARAM_KEY]
    end
  end
end
