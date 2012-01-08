module NIO
  # Selectors monitor IO objects for events of interest
  class Selector
    java_import "java.nio.channels.Selector"
    java_import "java.nio.channels.SelectionKey"

    # Convert nio4r interest symbols to Java NIO interest ops
    def self.sym2iops(interest, channel)
      case interest
      when :r
        if channel.validOps & SelectionKey::OP_ACCEPT != 0
          SelectionKey::OP_ACCEPT
        else
          SelectionKey::OP_READ
        end
      when :w
        if channel.respond_to? :connected? and not channel.connected?
          SelectionKey::OP_CONNECT
        else
          SelectionKey::OP_WRITE
        end
      when :rw
        super(:r, channel) | super(:w, channel)
      else raise ArgumentError, "invalid interest type: #{interest}"
      end
    end

    # Convert Java NIO interest ops to the corresponding Ruby symbols
    def self.iops2sym(interest_ops)
      case interest_ops
      when SelectionKey::OP_READ, SelectionKey::OP_ACCEPT
        :r
      when SelectionKey::OP_WRITE, SelectionKey::OP_CONNECT
        :w
      when SelectionKey::OP_READ | SelectionKey::OP_WRITE
        :rw
      else raise ArgumentError, "unknown interest op combination: 0x#{interest_ops.to_s(16)}"
      end
    end

    # Create a new NIO::Selector
    def initialize
      @java_selector = Selector.open
      @select_lock = Mutex.new
    end

    # Register interest in an IO object with the selector for the given types
    # of events. Valid event types for interest are:
    # * :r - is the IO readable?
    # * :w - is the IO writeable?
    # * :rw - is the IO either readable or writeable?
    def register(io, interest)
      java_channel = io.to_channel
      java_channel.configureBlocking(false)
      interest_ops = self.class.sym2iops(interest, java_channel)

      begin
        selector_key = java_channel.register @java_selector, interest_ops
      rescue NativeException => ex
        case ex.cause
        when java.lang.IllegalArgumentException
          raise ArgumentError, "invalid interest type for #{java_channel}: #{interest}"
        else raise
        end
      end

      NIO::Monitor.new(io, selector_key)
    end

    # Deregister the given IO object from the selector
    def deregister(io)
      key = io.to_channel.keyFor(@java_selector)
      return unless key

      monitor = key.attachment
      monitor.close
      monitor
    end

    # Is the given IO object registered with the selector?
    def registered?(io)
      key = io.to_channel.keyFor(@java_selector)
      return unless key
      !key.attachment.closed?
    end

    # Select which monitors are ready
    def select(timeout = nil)
      @select_lock.synchronize do
        ready = run_select(timeout)
        return unless ready > 0 # timeout or wakeup

        selected = @java_selector.selectedKeys.map { |key| key.attachment }
        @java_selector.selectedKeys.clear
        selected
      end
    end

    # Iterate across all selectable monitors
    def select_each(timeout = nil)
      @select_lock.synchronize do
        ready = run_select(timeout)
        return unless ready > 0

        @java_selector.selectedKeys.each { |key| yield key.attachment }
        @java_selector.selectedKeys.clear

        ready
      end
    end

    # Wake up the other thread that's currently blocking on this selector
    def wakeup
      @java_selector.wakeup
      nil
    end

    # Close this selector
    def close
      @java_selector.close
    end

    # Is this selector closed?
    def closed?
      !@java_selector.isOpen
    end

    #######
    private
    #######

    # Run the Java NIO Selector.select, filling selectedKeys as a side effect
    def run_select(timeout = nil)
      if timeout
        @java_selector.select(timeout * 1000)
      else
        @java_selector.select
      end
    end
  end
end
