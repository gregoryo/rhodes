require "socket"
require "json/pure"
require "set"

# DAPServer implements the Debug Adapter Protocol (DAP) for Ruby debugging.
#
# The Debug Adapter Protocol (DAP) is a standardized protocol for communication
# between a debug adapter and a client (typically an IDE like VS Code). This
# implementation provides a DAP server that can debug Ruby applications by:
#
# - Setting and managing breakpoints in source files
# - Stepping through code execution (next, continue)
# - Inspecting variables (local, instance, and global)
# - Viewing stack traces when execution is paused
# - Evaluating expressions in the current context
#
# Protocol Flow:
# 1. Client connects and sends 'initialize' request
# 2. Server responds with capabilities and sends 'initialized' event
# 3. Client sends 'attach' request with application root path
# 4. Server sets up trace_func to monitor code execution
# 5. Client sets breakpoints via 'setBreakpoints' requests
# 6. When breakpoint is hit or step completes, server sends 'stopped' event
# 7. Client queries stack frames, scopes, and variables
# 8. Client sends 'continue' or 'next' to resume execution
#
# The server uses Ruby's set_trace_func to monitor code execution and pause
# at breakpoints or step points. All communication follows the DAP specification
# with JSON-RPC style messages over a TCP socket connection.
class DAPServer
  # Creates a new DAP server instance.
  #
  # @param host [String] The hostname or IP address to bind the server to (e.g., "localhost", "127.0.0.1")
  # @param port [Integer] The port number to listen on for DAP client connections
  def initialize(host, port)
    @breakpoints = {}  # key: path, value: Set of line numbers
    @current_binding = nil
    @stack_frames = []
    @frame_bindings = {}
    @next_var_ref = 1
    @variables_map = {} # variablesReference => [binding, :local | :instance | :global]
    @step_mode = nil
    @server = TCPServer.new(host, port)
    puts "DAP server listening on #{host}:#{port}"
  end

  # Starts the DAP server and begins accepting client connections.
  #
  # This method enters an infinite loop, accepting incoming TCP connections
  # from DAP clients. Each client connection is handled in a separate thread
  # to allow multiple concurrent debugging sessions.
  #
  # @return [void] This method never returns under normal circumstances
  def start
    loop do
      @client = @server.accept
      Thread.new { handle_client() }
    end
  end

  # Handles a connected DAP client by reading and processing requests.
  #
  # This method continuously reads DAP protocol messages from the client,
  # which consist of a header with Content-Length followed by JSON payload.
  # Each request is parsed and dispatched to the appropriate handler method.
  #
  # @return [void]
  # @raise [Exception] Any errors during request processing are caught, logged, and cause the connection to close
  def handle_client()
    loop do
      header = read_header()
      break unless header

      content_length = header["Content-Length"].to_i
      json_data = @client.read(content_length)
      request = Rho::JSON.parse(json_data)
      handle_request(request)
    end
  rescue => e
    puts "[Error] #{e.message}"
  ensure
    @client&.close
  end

  # Reads the DAP protocol message header from the client.
  #
  # DAP messages start with HTTP-style headers (e.g., "Content-Length: 123")
  # followed by an empty line before the JSON body. This method reads until
  # the empty line and returns a hash of header key-value pairs.
  #
  # @return [Hash, nil] Hash of header fields (e.g., {"Content-Length" => "123"}), or nil if connection closed
  def read_header()
    header = {}
    while (line = @client.gets)
      line = line.strip
      break if line.empty?
      key, value = line.split(/:\s*/, 2)
      header[key] = value
    end
    header.empty? ? nil : header
  end

  # Sends a DAP protocol response message to the client.
  #
  # Constructs a response object following the DAP specification and sends
  # it to the connected client using the DAP message format.
  #
  # @param req [Hash] The original request being responded to (must contain "seq" and "command" fields)
  # @param body [Hash] The response body containing result data (default: {})
  # @param success [Boolean] Whether the request was successful (default: true)
  # @param message [String, nil] Optional error or status message
  # @return [void]
  def send_response(req, body: {}, success: true, message: nil)
    response = {
      type: "response",
      request_seq: req["seq"],
      success: success,
      command: req["command"],
    }
    response[:body] = body if body.any?
    response[:message] = message if message
    write_message(response)
  end

  # Sends a DAP protocol event message to the client.
  #
  # Events are asynchronous notifications from the server to the client about
  # state changes (e.g., "stopped" when hitting a breakpoint, "output" for logs).
  #
  # @param event_name [String] The name of the event (e.g., "stopped", "initialized", "output")
  # @param body [Hash] The event body containing event-specific data (default: {})
  # @return [void]
  def send_event(event_name, body = {})
    event = {
      type: "event",
      event: event_name,
      body: body,
    }
    write_message(event)
  end

  # Writes a DAP protocol message to the client socket.
  #
  # Formats the message according to DAP specification: HTTP-style headers
  # followed by JSON body. The Content-Length header is automatically calculated.
  #
  # @param message [Hash] The message to send (will be converted to JSON)
  # @return [void]
  def write_message(message)
    body = message.to_json
    header = "Content-Length: #{body.bytesize}\r\n\r\n"
    puts "app -> vsc: #{body}"
    @client.write(header + body)
  end

  # Dispatches incoming DAP requests to the appropriate handler method.
  #
  # This is the main request router that examines the command field and
  # delegates to specialized handler methods. Unsupported commands receive
  # an error response.
  #
  # @param req [Hash] The parsed DAP request containing "type", "command", and other fields
  # @return [void]
  def handle_request(req)
    puts "vsc -> app: #{req}"

    return unless req["type"] == "request"

    case req["command"]
    when "initialize"
      handle_initialize(req)
    when "attach"
      handle_attach(req)
    when "threads"
      handle_threads(req)
    when "stackTrace"
      handle_stack_trace(req)
    when "scopes"
      handle_scopes(req)
    when "variables"
      handle_variables(req)
    when "disconnect"
      handle_disconnect(req)
    when "setBreakpoints"
      handle_set_breakpoints(req)
    when "evaluate"
      handle_evaluate(req)
    when "continue"
      handle_continue(req)
    when "next"
      handle_next(req)
    else
      send_response(req, success: false, message: "Command not implemented")
    end
  end

  # Callback function invoked by Ruby's set_trace_func for each execution event.
  #
  # This is the core of the debugger, monitoring Ruby code execution and pausing
  # when breakpoints are hit or step operations complete. Only monitors files
  # within the application root path to avoid debugging framework code.
  #
  # @param event [String] The trace event type (e.g., "line", "call", "return")
  # @param file [String] The source file where the event occurred
  # @param line [Integer] The line number where the event occurred
  # @param method_name [Symbol] The name of the method being executed
  # @param binding [Binding] The execution context at this point
  # @param klass [Class] The class where the event occurred
  # @return [void]
  def trace_callback(event, file, line, method_name, binding, klass)
    normalized_file = File.expand_path(file)
    return unless normalized_file.start_with?(@root_path)

    msg = "[#{event}] #{file}:#{line} #{klass} #{method_name}"
    send_output_event("console", msg)

    return unless event == "line"

    stop_reason = nil
    if @step_mode == :next
      stop_reason = "step"
      @step_mode = nil
    elsif @breakpoints[normalized_file]&.include?(line)
      stop_reason = "breakpoint"
    end

    return unless stop_reason

    unless @stopped
      @stopped = true
      puts "[BREAK] Hit #{stop_reason} at #{normalized_file}:#{line}"

      @current_binding = binding
      update_stack_frames(binding)
      handle_stop(stop_reason, normalized_file, line)
    end
  end

  # === Command Handlers ===

  # Handles the DAP 'continue' request to resume execution.
  #
  # Resumes execution after a breakpoint or step pause. All threads continue
  # until the next breakpoint or step point.
  #
  # @param req [Hash] The DAP continue request
  # @return [void]
  def handle_continue(req)
    @wait_for_continue = false
    send_response(req, body: { allThreadsContinued: true })
  end

  # Handles the DAP 'next' request to step over the next line.
  #
  # Sets step mode and resumes execution. The debugger will pause at the
  # next line of code in the current context.
  #
  # @param req [Hash] The DAP next request
  # @return [void]
  def handle_next(req)
    @step_mode = :next
    @wait_for_continue = false
    send_response(req)
  end

  # Handles the DAP 'initialize' request to start the debugging session.
  #
  # This is the first request in the DAP protocol flow. The server responds
  # with its capabilities and sends an 'initialized' event to indicate readiness.
  #
  # @param req [Hash] The DAP initialize request
  # @return [void]
  def handle_initialize(req)
    send_response(req, body: { supportsEvaluateForHovers: true })
    send_event("initialized")
  end

  # Handles the DAP 'attach' request to attach the debugger to the application.
  #
  # Sets up the debugger by establishing the application root path and
  # installing the trace callback to monitor code execution. The root path
  # is used to filter which files should be debugged.
  #
  # @param req [Hash] The DAP attach request with arguments including optional "appRoot"
  # @return [void]
  def handle_attach(req)
    args = req["arguments"] || {}

    @root_path = File.expand_path(args["appRoot"] || Dir.pwd)
    puts "APP ROOT: #{@root_path}"

    set_trace_func method(:trace_callback).to_proc
    send_response(req)
  end

  # Handles the DAP 'threads' request to list all threads.
  #
  # Returns a list of all Ruby threads currently running. Each thread is
  # identified by its object_id which is used in subsequent requests.
  #
  # @param req [Hash] The DAP threads request
  # @return [void]
  def handle_threads(req)
    threads = Thread.list.map { |each| { :id => each.object_id, :name => each } }
    send_response(req, body: { threads: threads })
  end

  # Handles the DAP 'setBreakpoints' request to set or clear breakpoints.
  #
  # Updates the list of breakpoints for a source file. Previous breakpoints
  # for the file are replaced. Each breakpoint is verified and confirmed
  # to the client.
  #
  # @param req [Hash] The DAP setBreakpoints request containing source file path and line numbers
  # @return [void]
  def handle_set_breakpoints(req)
    source = req.dig("arguments", "source", "path")
    breakpoints = req.dig("arguments", "breakpoints") || []

    lines = breakpoints.map { |bp| bp["line"] }.to_set
    @breakpoints[source] = lines

    # Confirm breakpoint installation
    send_response(req, body: {
                         breakpoints: lines.map { |line| { verified: true, line: line } },
                       })
  end

  # Handles the DAP 'stackTrace' request to retrieve the call stack.
  #
  # Returns the current stack frames for the specified thread. In this MVP
  # implementation, only the main thread is supported. Stack frames include
  # source file locations and line numbers.
  #
  # @param req [Hash] The DAP stackTrace request with threadId argument
  # @return [void]
  def handle_stack_trace(req)
    thread_id = req.dig("arguments", "threadId")

    # For MVP: support only the main thread
    if Thread.main.object_id != thread_id
      send_response(req, body: { stackFrames: [], totalFrames: 0 })
      return
    end

    frames = @stack_frames || []
    send_response(req, body: {
                         stackFrames: frames,
                         totalFrames: frames.size,
                       })
  end

  # Handles the DAP 'disconnect' request to end the debugging session.
  #
  # Responds to the disconnect request. Additional cleanup logic for stopping
  # trace monitoring and closing connections can be added here.
  #
  # @param req [Hash] The DAP disconnect request
  # @return [void]
  def handle_disconnect(req)
    send_response(req)
    # Additional logic: stop processing, close connection, etc.
  end

  # Handles the DAP 'evaluate' request to evaluate an expression.
  #
  # Currently a placeholder implementation that echoes the expression back.
  # In a full implementation, this would evaluate the expression in the
  # current execution context and return the result.
  #
  # @param req [Hash] The DAP evaluate request with expression argument
  # @return [void]
  def handle_evaluate(req)
    expr = req.dig("arguments", "expression") || ""
    result = "Echo: #{expr}"
    send_response(req, body: {
                         result: result,
                         variablesReference: 0,
                       })
  end

  # Sends an output event to the client for logging/console messages.
  #
  # Output events display messages in the debug console. The category determines
  # how the client displays the message (e.g., stdout, stderr, console).
  #
  # @param category [String] The output category (e.g., "console", "stdout", "stderr")
  # @param message [String] The message to display
  # @return [void]
  def send_output_event(category, message)
    send_event("output", {
      category: category,
      output: message + "\n",
    })
  end

  # Updates the internal stack frame representation from the current execution context.
  #
  # Captures the call stack using caller_locations and builds DAP-compliant
  # stack frame objects. Filters out internal debugger frames and stores
  # the binding for the top frame to enable variable inspection.
  #
  # @param binding [Binding] The execution context at the current stop point
  # @return [void]
  def update_stack_frames(binding)
    locations = caller_locations(1) # skip this method itself
    @stack_frames = []
    @frame_bindings = {}

    filtered = []

    # Trim stack above trace_callback
    locations.each do |loc|
      path = File.expand_path(loc.path)
      next if path.include?(__FILE__) # skip calls from this file (DAP server)
      filtered << loc
    end

    filtered.each_with_index do |loc, i|
      @stack_frames << {
        id: i,
        name: loc.label,
        source: { name: File.basename(loc.path), path: File.expand_path(loc.path) },
        line: loc.lineno,
        column: 1,
      }

      # currently only the top frame has binding
      @frame_bindings[i] = binding if i == 0
    end
  end

  # Handles the DAP 'scopes' request to retrieve variable scopes for a stack frame.
  #
  # Returns the available variable scopes (Local, Instance, Global) for the
  # specified stack frame. Each scope has a variablesReference that can be
  # used to retrieve the actual variables.
  #
  # @param req [Hash] The DAP scopes request with frameId argument
  # @return [void]
  def handle_scopes(req)
    frame_id = req.dig("arguments", "frameId")
    binding = @frame_bindings[frame_id]

    scopes = []

    if binding
      local_ref = @next_var_ref
      @next_var_ref += 1
      @variables_map[local_ref] = [binding, :local]

      scopes << {
        name: "Local",
        variablesReference: local_ref,
        expensive: false,
      }

      instance_ref = @next_var_ref
      @next_var_ref += 1
      @variables_map[instance_ref] = [binding, :instance]

      scopes << {
        name: "Instance",
        variablesReference: instance_ref,
        expensive: false,
      }
    end

    global_ref = @next_var_ref
    @next_var_ref += 1
    @variables_map[global_ref] = [nil, :global]

    scopes << {
      name: "Global",
      variablesReference: global_ref,
      expensive: true,
    }

    send_response(req, body: { scopes: scopes })
  end

  # Handles the DAP 'variables' request to retrieve variables from a scope.
  #
  # Fetches and returns the variables (local, instance, or global) for the
  # scope identified by variablesReference. Each variable includes its name,
  # value, type, and nested variablesReference for complex objects.
  #
  # @param req [Hash] The DAP variables request with variablesReference argument
  # @return [void]
  def handle_variables(req)
    ref = req.dig("arguments", "variablesReference")
    binding, scope_type = @variables_map[ref]

    vars = case scope_type
      when :local
        binding.local_variables.map do |name|
          build_var(name, binding.local_variable_get(name))
        end
      when :instance
        self_obj = binding.eval("self")
        self_obj.instance_variables.map do |name|
          build_var(name, self_obj.instance_variable_get(name))
        end
      when :global
        global_variables.map do |name|
          build_var(name, eval(name.to_s))
        end
      else
        []
      end

    send_response(req, body: { variables: vars })
  end

  # Builds a DAP-compliant variable representation from a Ruby variable.
  #
  # Constructs a hash containing the variable's name, inspected value, type,
  # and variablesReference. Handles errors gracefully if inspection fails.
  #
  # @param name [Symbol, String] The variable name
  # @param value [Object] The variable value
  # @return [Hash] A DAP variable object with name, value, type, and variablesReference fields
  def build_var(name, value)
    {
      name: name.to_s,
      value: value.inspect,
      type: value.class.to_s,
      variablesReference: 0, # позже можно расширить
    }
  rescue => e
    {
      name: name.to_s,
      value: "[error: #{e.message}]",
      type: "Error",
      variablesReference: 0,
    }
  end

  # Pauses execution and waits for a continue or step command.
  #
  # Sends a 'stopped' event to the client and enters a busy-wait loop until
  # the client sends a continue or step command. This blocks the current
  # thread to maintain the execution state for inspection.
  #
  # @param reason [String] The stop reason (e.g., "breakpoint", "step")
  # @param file [String] The source file where execution stopped
  # @param line [Integer] The line number where execution stopped
  # @return [void]
  def handle_stop(reason, file, line)
    send_stopped_event(reason: reason, thread_id: Thread.current.object_id)
    @wait_for_continue = true
    sleep 0.05 while @wait_for_continue
    @stopped = false
  end

  # Sends a 'stopped' event to notify the client that execution has paused.
  #
  # The stopped event indicates that the debugger has paused execution due to
  # a breakpoint, step completion, or other stop reason. The client can then
  # query the current state.
  #
  # @param reason [String] The reason for stopping (e.g., "breakpoint", "step", "pause")
  # @param thread_id [Integer] The object_id of the thread that stopped
  # @return [void]
  def send_stopped_event(reason:, thread_id:)
    send_event("stopped", {
      reason: reason,
      threadId: thread_id,
      allThreadsStopped: true,
    })
  end
end

# === Запуск ===

debug_host = ENV["DEBUG_HOST"] || "127.0.0.1"
debug_port = (ENV["DEBUG_PORT"] || 9000).to_i

Thread.new do
  DAPServer.new(debug_host, debug_port).start
end
