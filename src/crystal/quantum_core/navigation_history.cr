require "uri"

module QuantumCore
  # Represents a single entry in the navigation history.
  record NavigationEntry, url : URI, title : String? do
    # Provides a string representation for debugging or logging.
    def to_s(io : IO)
      io << "NavigationEntry(url=" << @url << ", title=" << (@title || "(none)") << ")"
    end
  end

  # Manages the navigation history for a Page.
  # Provides methods for adding entries, moving back/forward, and retrieving entries.
  # This class is designed to be thread-safe.
  class NavigationHistory
    getter entries : Array(NavigationEntry)
    getter current_index : Int32

    # Maximum number of history entries to keep.
    # Prevents unbounded memory growth.
    MAX_HISTORY_SIZE = 100

    def initialize
      @entries = [] of NavigationEntry
      @current_index = -1
      @mutex = Mutex.new
    end

    # Adds a new navigation entry.
    # If the current index is not at the end of the list,
    # subsequent entries (forward history) are discarded.
    # Limits the total history size to MAX_HISTORY_SIZE.
    def add_entry(url : URI, title : String? = nil)
      @mutex.synchronize do
        entry = NavigationEntry.new(url: url, title: title)

        # Avoid adding duplicate consecutive entries (e.g., fragment navigation)
        # unless it's the very first entry.
        if @current_index >= 0 && @entries[@current_index].url == url
          # Update title if necessary
          if title && @entries[@current_index].title != title
            @entries[@current_index] = @entries[@current_index].copy(title: title)
          end
          return # Do not add duplicate URL
        end

        # Trim forward history if navigating back and then to a new page
        if @current_index < @entries.size - 1
          @entries = @entries[0..@current_index]
        end

        @entries << entry
        @current_index += 1

        # Limit history size
        if @entries.size > MAX_HISTORY_SIZE
          # Shift entries and adjust index
          excess = @entries.size - MAX_HISTORY_SIZE
          @entries = @entries[excess..]
          @current_index -= excess
        end
      end
    end

    # Updates the title of the current navigation entry.
    # Does nothing if there is no current entry.
    def update_current_entry_title(title : String)
      @mutex.synchronize do
        return if @current_index < 0 || @current_index >= @entries.size
        current_entry = @entries[@current_index]
        # Only update if the title is different
        if current_entry.title != title
          @entries[@current_index] = current_entry.copy(title: title)
        end
      end
    end

    # Moves the current index back by one, if possible.
    # Returns the new current entry, or nil if cannot go back.
    def go_back : NavigationEntry?
      @mutex.synchronize do
        if can_go_back?
          @current_index -= 1
          @entries[@current_index]?
        else
          nil
        end
      end
    end

    # Moves the current index forward by one, if possible.
    # Returns the new current entry, or nil if cannot go forward.
    def go_forward : NavigationEntry?
      @mutex.synchronize do
        if can_go_forward?
          @current_index += 1
          @entries[@current_index]?
        else
          nil
        end
      end
    end

    # Checks if it's possible to navigate back.
    def can_go_back? : Bool
      @mutex.synchronize do
        @current_index > 0
      end
    end

    # Checks if it's possible to navigate forward.
    def can_go_forward? : Bool
      @mutex.synchronize do
        @current_index < @entries.size - 1
      end
    end

    # Returns the current navigation entry, if one exists.
    def current_entry? : NavigationEntry?
      @mutex.synchronize do
        if @current_index >= 0 && @current_index < @entries.size
          @entries[@current_index]?
        else
          nil
        end
      end
    end

    # Clears the entire navigation history.
    def clear
      @mutex.synchronize do
        @entries.clear
        @current_index = -1
      end
    end

    # Provides a string representation for debugging.
    def to_s(io : IO)
      @mutex.synchronize do
        io << "NavigationHistory(size=" << @entries.size << ", index=" << @current_index << ", entries=["
        @entries.each_with_index do |entry, i|
          io << "\n  " << (i == @current_index ? "* " : "  ") << entry
        end
        io << "\n])"
      end
    end
  end
end 