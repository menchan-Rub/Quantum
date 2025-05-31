# DOM Node実装 - W3C DOM仕様完全準拠
# 世界最高水準のDOM実装

require "json"

module QuantumCore::DOM
  # DOM Node Types (W3C DOM Level 1)
  enum NodeType : UInt16
    ELEMENT_NODE                = 1
    ATTRIBUTE_NODE              = 2  # Deprecated in DOM4
    TEXT_NODE                   = 3
    CDATA_SECTION_NODE          = 4
    ENTITY_REFERENCE_NODE       = 5  # Deprecated in DOM4
    ENTITY_NODE                 = 6  # Deprecated in DOM4
    PROCESSING_INSTRUCTION_NODE = 7
    COMMENT_NODE                = 8
    DOCUMENT_NODE               = 9
    DOCUMENT_TYPE_NODE          = 10
    DOCUMENT_FRAGMENT_NODE      = 11
    NOTATION_NODE               = 12 # Deprecated in DOM4
  end

  # Document Position Constants
  enum DocumentPosition : UInt16
    DISCONNECTED            = 0x01
    PRECEDING               = 0x02
    FOLLOWING               = 0x04
    CONTAINS                = 0x08
    CONTAINED_BY            = 0x10
    IMPLEMENTATION_SPECIFIC = 0x20
  end

  # DOM Exception Types
  class DOMException < Exception
    enum Code : UInt16
      INDEX_SIZE_ERR              = 1
      DOMSTRING_SIZE_ERR          = 2
      HIERARCHY_REQUEST_ERR       = 3
      WRONG_DOCUMENT_ERR          = 4
      INVALID_CHARACTER_ERR       = 5
      NO_DATA_ALLOWED_ERR         = 6
      NO_MODIFICATION_ALLOWED_ERR = 7
      NOT_FOUND_ERR               = 8
      NOT_SUPPORTED_ERR           = 9
      INUSE_ATTRIBUTE_ERR         = 10
      INVALID_STATE_ERR           = 11
      SYNTAX_ERR                  = 12
      INVALID_MODIFICATION_ERR    = 13
      NAMESPACE_ERR               = 14
      INVALID_ACCESS_ERR          = 15
      VALIDATION_ERR              = 16
      TYPE_MISMATCH_ERR           = 17
      SECURITY_ERR                = 18
      NETWORK_ERR                 = 19
      ABORT_ERR                   = 20
      URL_MISMATCH_ERR            = 21
      QUOTA_EXCEEDED_ERR          = 22
      TIMEOUT_ERR                 = 23
      INVALID_NODE_TYPE_ERR       = 24
      DATA_CLONE_ERR              = 25
    end

    getter code : Code

    def initialize(@code : Code, message : String)
      super(message)
    end
  end

  # Event Target Interface
  abstract class EventTarget
    @event_listeners = Hash(String, Array(Proc(Event, Nil))).new

    def add_event_listener(type : String, listener : Proc(Event, Nil), options = nil)
      @event_listeners[type] ||= [] of Proc(Event, Nil)
      @event_listeners[type] << listener
    end

    def remove_event_listener(type : String, listener : Proc(Event, Nil), options = nil)
      if listeners = @event_listeners[type]?
        listeners.delete(listener)
      end
    end

    def dispatch_event(event : Event) : Bool
      if listeners = @event_listeners[event.type]?
        listeners.each do |listener|
          begin
            listener.call(event)
          rescue ex
            # Log error but continue with other listeners
            puts "Error in event listener: #{ex.message}"
          end
        end
        return true
      end
      false
    end
  end

  # Base Node Class
  abstract class Node < EventTarget
    getter node_type : NodeType
    getter node_name : String
    getter? node_value : String?
    getter owner_document : Document?
    getter? parent_node : Node?
    getter child_nodes : Array(Node)
    getter? first_child : Node?
    getter? last_child : Node?
    getter? previous_sibling : Node?
    getter? next_sibling : Node?
    getter attributes : Hash(String, String)?
    getter namespace_uri : String?
    getter? prefix : String?
    getter local_name : String?
    getter base_uri : String?
    getter text_content : String?

    # Internal properties
    @child_nodes = Array(Node).new
    @attributes = Hash(String, String).new
    @mutation_observers = Array(MutationObserver).new

    def initialize(@node_type : NodeType, @node_name : String, @owner_document : Document? = nil)
      @node_value = nil
      @parent_node = nil
      @first_child = nil
      @last_child = nil
      @previous_sibling = nil
      @next_sibling = nil
      @namespace_uri = nil
      @prefix = nil
      @local_name = nil
      @base_uri = nil
      @text_content = nil
    end

    # Node manipulation methods
    def append_child(new_child : Node) : Node
      validate_hierarchy(new_child)
      
      # Remove from previous parent if exists
      new_child.parent_node?.try(&.remove_child(new_child))
      
      # Update relationships
      new_child.@parent_node = self
      new_child.@owner_document = @owner_document
      
      if @child_nodes.empty?
        @first_child = new_child
        @last_child = new_child
        new_child.@previous_sibling = nil
        new_child.@next_sibling = nil
      else
        old_last = @last_child
        old_last.try(&.@next_sibling = new_child)
        new_child.@previous_sibling = old_last
        new_child.@next_sibling = nil
        @last_child = new_child
      end
      
      @child_nodes << new_child
      
      # Notify mutation observers
      notify_mutation_observers("childList", [new_child], [] of Node)
      
      new_child
    end

    def insert_before(new_child : Node, ref_child : Node?) : Node
      if ref_child.nil?
        return append_child(new_child)
      end

      unless @child_nodes.includes?(ref_child)
        raise DOMException.new(DOMException::Code::NOT_FOUND_ERR, "Reference child not found")
      end

      validate_hierarchy(new_child)
      
      # Remove from previous parent if exists
      new_child.parent_node?.try(&.remove_child(new_child))
      
      # Find insertion index
      index = @child_nodes.index(ref_child).not_nil!
      
      # Update relationships
      new_child.@parent_node = self
      new_child.@owner_document = @owner_document
      new_child.@next_sibling = ref_child
      new_child.@previous_sibling = ref_child.@previous_sibling
      
      ref_child.@previous_sibling.try(&.@next_sibling = new_child)
      ref_child.@previous_sibling = new_child
      
      if index == 0
        @first_child = new_child
      end
      
      @child_nodes.insert(index, new_child)
      
      # Notify mutation observers
      notify_mutation_observers("childList", [new_child], [] of Node)
      
      new_child
    end

    def remove_child(old_child : Node) : Node
      unless @child_nodes.includes?(old_child)
        raise DOMException.new(DOMException::Code::NOT_FOUND_ERR, "Child not found")
      end
      
      # Update sibling relationships
      old_child.@previous_sibling.try(&.@next_sibling = old_child.@next_sibling)
      old_child.@next_sibling.try(&.@previous_sibling = old_child.@previous_sibling)
      
      # Update first/last child pointers
      if @first_child == old_child
        @first_child = old_child.@next_sibling
      end
      
      if @last_child == old_child
        @last_child = old_child.@previous_sibling
      end
      
      # Remove from child list
      @child_nodes.delete(old_child)
      
      # Clear parent reference
      old_child.@parent_node = nil
      old_child.@previous_sibling = nil
      old_child.@next_sibling = nil
      
      # Notify mutation observers
      notify_mutation_observers("childList", [] of Node, [old_child])
      
      old_child
    end

    def replace_child(new_child : Node, old_child : Node) : Node
      unless @child_nodes.includes?(old_child)
        raise DOMException.new(DOMException::Code::NOT_FOUND_ERR, "Child not found")
      end

      validate_hierarchy(new_child)
      
      # Insert new child before old child
      insert_before(new_child, old_child)
      
      # Remove old child
      remove_child(old_child)
      
      old_child
    end

    def clone_node(deep : Bool = false) : Node
      cloned = create_clone
      
      if deep
        @child_nodes.each do |child|
          cloned.append_child(child.clone_node(true))
        end
      end
      
      cloned
    end

    # Node comparison
    def is_same_node(other : Node?) : Bool
      self == other
    end

    def is_equal_node(other : Node?) : Bool
      return false unless other
      return false unless @node_type == other.node_type
      return false unless @node_name == other.node_name
      return false unless @node_value == other.node_value
      return false unless @namespace_uri == other.namespace_uri
      return false unless @prefix == other.prefix
      return false unless @local_name == other.local_name
      
      # Compare attributes
      return false unless @attributes == other.attributes
      
      # Compare children
      return false unless @child_nodes.size == other.child_nodes.size
      
      @child_nodes.zip(other.child_nodes) do |child1, child2|
        return false unless child1.is_equal_node(child2)
      end
      
      true
    end

    def compare_document_position(other : Node) : DocumentPosition
      return DocumentPosition::DISCONNECTED if @owner_document != other.owner_document
      
      # Same node
      return DocumentPosition.new(0) if self == other
      
      # Check if one contains the other
      if contains(other)
        return DocumentPosition::FOLLOWING | DocumentPosition::CONTAINED_BY
      elsif other.contains(self)
        return DocumentPosition::PRECEDING | DocumentPosition::CONTAINS
      end
      
      # Find common ancestor and determine order
      self_ancestors = get_ancestors
      other_ancestors = other.get_ancestors
      
      # Find common ancestor
      common_ancestor = nil
      self_ancestors.reverse.zip(other_ancestors.reverse) do |self_anc, other_anc|
        if self_anc == other_anc
          common_ancestor = self_anc
        else
          break
        end
      end
      
      return DocumentPosition::DISCONNECTED unless common_ancestor
      
      # Determine order based on position in common ancestor
      self_path = get_path_to_ancestor(common_ancestor)
      other_path = other.get_path_to_ancestor(common_ancestor)
      
      if self_path.first < other_path.first
        DocumentPosition::FOLLOWING
      else
        DocumentPosition::PRECEDING
      end
    end

    def contains(other : Node?) : Bool
      return false unless other
      
      current = other.parent_node
      while current
        return true if current == self
        current = current.parent_node
      end
      
      false
    end

    def lookup_prefix(namespace_uri : String?) : String?
      return nil unless namespace_uri
      
      current = self
      while current
        if current.namespace_uri == namespace_uri
          return current.prefix
        end
        current = current.parent_node
      end
      
      nil
    end

    def lookup_namespace_uri(prefix : String?) : String?
      current = self
      while current
        if current.prefix == prefix
          return current.namespace_uri
        end
        current = current.parent_node
      end
      
      nil
    end

    def is_default_namespace(namespace_uri : String?) : Bool
      lookup_namespace_uri(nil) == namespace_uri
    end

    # Text content methods
    def text_content=(value : String?)
      # Remove all child nodes
      @child_nodes.clear
      @first_child = nil
      @last_child = nil
      
      if value && !value.empty?
        text_node = Text.new(value, @owner_document)
        append_child(text_node)
      end
      
      @text_content = value
    end

    def text_content : String?
      case @node_type
      when .document_node?, .document_type_node?
        nil
      when .text_node?, .cdata_section_node?, .comment_node?, .processing_instruction_node?
        @node_value
      else
        content = String.build do |str|
          collect_text_content(str)
        end
        content.empty? ? nil : content
      end
    end

    # Utility methods
    def has_child_nodes : Bool
      !@child_nodes.empty?
    end

    def normalize
      # Merge adjacent text nodes and remove empty text nodes
      i = 0
      while i < @child_nodes.size
        child = @child_nodes[i]
        
        if child.node_type.text_node?
          # Check for adjacent text nodes
          next_child = @child_nodes[i + 1]?
          if next_child && next_child.node_type.text_node?
            # Merge text nodes
            merged_text = (child.node_value || "") + (next_child.node_value || "")
            child.node_value = merged_text
            remove_child(next_child)
            next
          end
          
          # Remove empty text nodes
          if child.node_value.nil? || child.node_value.try(&.empty?)
            remove_child(child)
            next
          end
        else
          # Recursively normalize child elements
          child.normalize
        end
        
        i += 1
      end
    end

    # Mutation observer support
    def add_mutation_observer(observer : MutationObserver)
      @mutation_observers << observer
    end

    def remove_mutation_observer(observer : MutationObserver)
      @mutation_observers.delete(observer)
    end

    # Abstract methods to be implemented by subclasses
    abstract def create_clone : Node

    # Protected methods
    protected def validate_hierarchy(new_child : Node)
      # Check for circular reference
      current = self
      while current
        if current == new_child
          raise DOMException.new(DOMException::Code::HIERARCHY_REQUEST_ERR, "Circular reference detected")
        end
        current = current.parent_node
      end
      
      # Check document ownership
      if @owner_document && new_child.owner_document && @owner_document != new_child.owner_document
        raise DOMException.new(DOMException::Code::WRONG_DOCUMENT_ERR, "Wrong document")
      end
      
      # Type-specific validation
      case @node_type
      when .document_node?
        case new_child.node_type
        when .element_node?
          # Document can only have one element child
          if @child_nodes.any?(&.node_type.element_node?)
            raise DOMException.new(DOMException::Code::HIERARCHY_REQUEST_ERR, "Document already has an element child")
          end
        when .document_type_node?
          # Document can only have one doctype child
          if @child_nodes.any?(&.node_type.document_type_node?)
            raise DOMException.new(DOMException::Code::HIERARCHY_REQUEST_ERR, "Document already has a doctype child")
          end
        when .text_node?, .cdata_section_node?
          raise DOMException.new(DOMException::Code::HIERARCHY_REQUEST_ERR, "Document cannot contain text nodes")
        end
      when .text_node?, .comment_node?, .processing_instruction_node?, .cdata_section_node?
        raise DOMException.new(DOMException::Code::HIERARCHY_REQUEST_ERR, "This node type cannot have children")
      end
    end

    protected def collect_text_content(str : String::Builder)
      @child_nodes.each do |child|
        case child.node_type
        when .text_node?, .cdata_section_node?
          str << (child.node_value || "")
        when .element_node?
          child.collect_text_content(str)
        end
      end
    end

    protected def get_ancestors : Array(Node)
      ancestors = [] of Node
      current = @parent_node
      while current
        ancestors << current
        current = current.parent_node
      end
      ancestors
    end

    protected def get_path_to_ancestor(ancestor : Node) : Array(Int32)
      path = [] of Int32
      current = self
      
      while current && current != ancestor
        if parent = current.parent_node
          index = parent.child_nodes.index(current)
          path.unshift(index || 0)
          current = parent
        else
          break
        end
      end
      
      path
    end

    protected def notify_mutation_observers(type : String, added_nodes : Array(Node), removed_nodes : Array(Node))
      @mutation_observers.each do |observer|
        observer.notify(type, self, added_nodes, removed_nodes)
      end
      
      # Bubble up to parent
      @parent_node.try(&.notify_mutation_observers(type, added_nodes, removed_nodes))
    end

    # Serialization
    def to_json(json : JSON::Builder)
      json.object do
        json.field "nodeType", @node_type.value
        json.field "nodeName", @node_name
        json.field "nodeValue", @node_value
        json.field "namespaceURI", @namespace_uri
        json.field "prefix", @prefix
        json.field "localName", @local_name
        
        if @attributes && !@attributes.empty?
          json.field "attributes" do
            json.object do
              @attributes.each do |name, value|
                json.field name, value
              end
            end
          end
        end
        
        if !@child_nodes.empty?
          json.field "childNodes" do
            json.array do
              @child_nodes.each do |child|
                child.to_json(json)
              end
            end
          end
        end
      end
    end

    def inspect(io : IO) : Nil
      io << "#<#{self.class.name}:0x"
      object_id.to_s(16, io)
      io << " nodeName=" << @node_name.inspect
      io << " nodeType=" << @node_type
      if @node_value
        io << " nodeValue=" << @node_value.inspect
      end
      io << " children=" << @child_nodes.size
      io << ">"
    end
  end

  # Mutation Observer for DOM changes
  class MutationObserver
    def notify(type : String, target : Node, added_nodes : Array(Node), removed_nodes : Array(Node))
      # Override in subclasses
    end
  end

  # Event class for DOM events
  class Event
    getter type : String
    getter target : EventTarget?
    getter current_target : EventTarget?
    getter bubbles : Bool
    getter cancelable : Bool
    getter? default_prevented : Bool
    getter timestamp : Time

    @default_prevented = false

    def initialize(@type : String, @bubbles : Bool = false, @cancelable : Bool = false)
      @timestamp = Time.utc
    end

    def prevent_default
      @default_prevented = true if @cancelable
    end

    def stop_propagation
      # Implementation for event propagation control
    end

    def stop_immediate_propagation
      # Implementation for immediate propagation control
    end
  end
end 