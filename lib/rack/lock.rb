require 'thread'
require 'rack/body_proxy'

module Rack
  # Rack::Lock locks every request inside a mutex, so that every request
  # will effectively be executed synchronously.
  class Lock
    def initialize(mutex = Mutex.new)
      @mutex = mutex
    end

    def start_request req, res
      @mutex.lock
    end

    def finish_request req, res
      @mutex.unlock
    end
  end
end
