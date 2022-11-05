require "js.so"

# The JS module provides a way to interact with JavaScript from Ruby.
#
# == Example
#
#   require 'js'
#   JS.eval("return 1 + 2") # => 3
#   JS.global[:document].write("Hello, world!")
#   JS.global[:document].addEventListner("click") do |event|
#     puts event          # => # [object MouseEvent]
#     puts event[:detail] # => 1
#   end
#
module JS
  Undefined = JS.eval("return undefined")
  Null = JS.eval("return null")

  def self.promise_scheduler
    @promise_scheduler
  end

  def self.eval_async(code, future)
    @promise_scheduler ||= PromiseScheduler.new Fiber.current
    Fiber.new do
      future.resolve JS::Object.wrap(Kernel.eval(code.to_s, nil, "eval_async"))
    rescue => e
      future.reject JS::Object.wrap(e)
    end.transfer
  end

  class PromiseScheduler
    Task = Struct.new(:fiber, :status, :value)

    def initialize(main_fiber)
      @tasks = []
      @is_spinning = false
      @loop_fiber = Fiber.new do
        loop do
          while task = @tasks.shift
            task.fiber.transfer(task.value, task.status)
          end
          @is_spinning = false
          main_fiber.transfer
        end
      end
    end

    def await(promise)
      current = Fiber.current
      promise.call(
        :then,
        ->(value) { enqueue Task.new(current, :success, value) },
        ->(value) { enqueue Task.new(current, :failure, value) }
      )
      value, status = @loop_fiber.transfer
      raise JS::Error.new(value) if status == :failure
      value
    end

    def enqueue(task)
      @tasks << task
      unless @is_spinning
        @is_spinning = true
        JS.global.queueMicrotask -> { @loop_fiber.transfer }
      end
    end
  end
end

class JS::Object
  def method_missing(sym, *args, &block)
    if self[sym].typeof == "function"
      self.call(sym, *args, &block)
    else
      super
    end
  end

  def respond_to_missing?(sym, include_private)
    return true if super
    self[sym].typeof == "function"
  end

  def await
    sched = JS.promise_scheduler
    unless sched
      raise "Please start Ruby evaluation with RubyVM.eval_async to use JS::Object#await"
    end
    # Promise.resolve wrap a value or flattens promise-like object and its thenable chain
    promise = JS.global[:Promise].resolve(self)
    sched.await(promise)
  end
end

# A wrapper class for JavaScript Error to allow the Error to be thrown in Ruby.
class JS::Error
  def initialize(exception)
    @exception = exception
    super
  end

  def message
    stack = @exception[:stack]
    if stack.typeof == "string"
      # Error.stack contains the error message also
      stack.to_s
    else
      @exception.to_s
    end
  end
end
