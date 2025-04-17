const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

pub const NodeType = enum(u8) {
    ELEMENT_NODE = 1,
    ATTRIBUTE_NODE = 2,
    TEXT_NODE = 3,
    CDATA_SECTION_NODE = 4,
    PROCESSING_INSTRUCTION_NODE = 7,
    COMMENT_NODE = 8,
    DOCUMENT_NODE = 9,
    DOCUMENT_TYPE_NODE = 10,
    DOCUMENT_FRAGMENT_NODE = 11,
};

pub const ElementNamespace = enum {
    HTML,
    SVG,
    MathML,
    XLink,
    XML,
    XMLNS,
    None,
};

pub const NamedNodeMap = struct {
    attributes: StringHashMap([]const u8),
    allocator: *Allocator,

    pub fn init(allocator: *Allocator) NamedNodeMap {
        return .{
            .attributes = StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NamedNodeMap) void {
        var iter = self.attributes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    pub fn getNamedItem(self: *const NamedNodeMap, name: []const u8) ?[]const u8 {
        return self.attributes.get(name);
    }

    pub fn setNamedItem(self: *NamedNodeMap, name: []const u8, value: []const u8) !void {
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);
        const value_dup = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_dup);

        const result = try self.attributes.getOrPut(name_dup);
        if (result.found_existing) {
            self.allocator.free(name_dup);
            self.allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = value_dup;
    }

    pub fn removeNamedItem(self: *NamedNodeMap, name: []const u8) bool {
        if (self.attributes.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn getLength(self: *const NamedNodeMap) usize {
        return self.attributes.count();
    }

    pub fn item(self: *const NamedNodeMap, index: usize) ?struct { name: []const u8, value: []const u8 } {
        var iter = self.attributes.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| {
            if (i == index) {
                return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
            }
            i += 1;
        }
        return null;
    }
};

pub const Node = struct {
    node_type: NodeType,
    node_name: []const u8,
    node_value: ?[]const u8 = null,
    parent_node: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    previous_sibling: ?*Node = null,
    next_sibling: ?*Node = null,
    owner_document: ?*Node = null,
    attributes: ?NamedNodeMap = null,
    namespace_uri: ?[]const u8 = null,
    element_namespace: ElementNamespace = .None,
    is_connected: bool = false,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator, node_type: NodeType, node_name: []const u8) !*Node {
        const node = try allocator.create(Node);
        const name_dup = try allocator.dupe(u8, node_name);
        node.* = .{
            .node_type = node_type,
            .node_name = name_dup,
            .allocator = allocator,
        };
        return node;
    }

    pub fn deinit(self: *Node) void {
        // Free the node name
        self.allocator.free(self.node_name);

        // Free the node value if it exists
        if (self.node_value) |value| {
            self.allocator.free(value);
        }

        // Free the namespace URI if it exists
        if (self.namespace_uri) |uri| {
            self.allocator.free(uri);
        }

        // Deinitialize and free attributes if they exist
        if (self.attributes) |*attrs| {
            attrs.deinit();
        }

        // Note: We don't recursively free child nodes here
        // That should be handled by the caller to prevent double frees
        // when nodes are shared between different parts of the tree
    }

    pub fn deinitRecursive(self: *Node) void {
        // First deinitialize all children recursively
        var child = self.first_child;
        while (child != null) {
            const next = child.?.next_sibling;
            child.?.deinitRecursive();
            self.allocator.destroy(child.?);
            child = next;
        }

        // Then deinitialize itself
        self.deinit();
    }

    pub fn setNodeValue(self: *Node, value: ?[]const u8) !void {
        if (self.node_value) |old_value| {
            self.allocator.free(old_value);
        }

        if (value) |new_value| {
            const value_dup = try self.allocator.dupe(u8, new_value);
            self.node_value = value_dup;
        } else {
            self.node_value = null;
        }
    }

    pub fn appendChild(self: *Node, child: *Node) !void {
        // Cannot append a node to itself
        if (self == child) {
            return error.HierarchyRequestError;
        }

        // Check if the child is already a parent of this node (would create a cycle)
        var node = self.parent_node;
        while (node != null) {
            if (node.? == child) {
                return error.HierarchyRequestError;
            }
            node = node.?.parent_node;
        }

        // Remove the child from its current parent if it has one
        if (child.parent_node) |parent| {
            try parent.removeChild(child);
        }

        // Append the child to this node
        child.parent_node = self;
        child.previous_sibling = self.last_child;
        child.next_sibling = null;

        if (self.last_child) |last| {
            last.next_sibling = child;
        } else {
            self.first_child = child;
        }

        self.last_child = child;
        
        // Set owner document and connected status
        child.owner_document = self.owner_document;
        if (self.is_connected) {
            child.setConnected(true);
        }
    }

    pub fn removeChild(self: *Node, child: *Node) !void {
        if (child.parent_node != self) {
            return error.NotFoundError;
        }

        if (self.first_child == child) {
            self.first_child = child.next_sibling;
        }

        if (self.last_child == child) {
            self.last_child = child.previous_sibling;
        }

        if (child.previous_sibling) |prev| {
            prev.next_sibling = child.next_sibling;
        }

        if (child.next_sibling) |next| {
            next.previous_sibling = child.previous_sibling;
        }

        child.parent_node = null;
        child.previous_sibling = null;
        child.next_sibling = null;
        child.setConnected(false);
    }

    pub fn insertBefore(self: *Node, new_child: *Node, reference_child: ?*Node) !void {
        if (reference_child == null) {
            return self.appendChild(new_child);
        }

        if (reference_child.?.parent_node != self) {
            return error.NotFoundError;
        }

        // Cannot insert a node before itself
        if (new_child == reference_child.?) {
            return error.HierarchyRequestError;
        }

        // Check if new_child is already a parent of this node (would create a cycle)
        var node = self.parent_node;
        while (node != null) {
            if (node.? == new_child) {
                return error.HierarchyRequestError;
            }
            node = node.?.parent_node;
        }

        // Remove the new child from its current parent if it has one
        if (new_child.parent_node) |parent| {
            try parent.removeChild(new_child);
        }

        // Insert the new child before the reference child
        new_child.parent_node = self;
        new_child.next_sibling = reference_child;
        new_child.previous_sibling = reference_child.?.previous_sibling;

        if (reference_child.?.previous_sibling) |prev| {
            prev.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }

        reference_child.?.previous_sibling = new_child;
        
        // Set owner document and connected status
        new_child.owner_document = self.owner_document;
        if (self.is_connected) {
            new_child.setConnected(true);
        }
    }

    pub fn replaceChild(self: *Node, new_child: *Node, old_child: *Node) !void {
        if (old_child.parent_node != self) {
            return error.NotFoundError;
        }

        if (new_child == old_child) {
            return;
        }

        // Check if new_child is already a parent of this node (would create a cycle)
        var node = self.parent_node;
        while (node != null) {
            if (node.? == new_child) {
                return error.HierarchyRequestError;
            }
            node = node.?.parent_node;
        }

        // Remove the new child from its current parent if it has one
        if (new_child.parent_node) |parent| {
            try parent.removeChild(new_child);
        }

        // Replace the old child with the new child
        new_child.parent_node = self;
        new_child.previous_sibling = old_child.previous_sibling;
        new_child.next_sibling = old_child.next_sibling;

        if (old_child.previous_sibling) |prev| {
            prev.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }

        if (old_child.next_sibling) |next| {
            next.previous_sibling = new_child;
        } else {
            self.last_child = new_child;
        }

        old_child.parent_node = null;
        old_child.previous_sibling = null;
        old_child.next_sibling = null;
        old_child.setConnected(false);
        
        // Set owner document and connected status
        new_child.owner_document = self.owner_document;
        if (self.is_connected) {
            new_child.setConnected(true);
        }
    }

    pub fn hasChildNodes(self: *const Node) bool {
        return self.first_child != null;
    }

    pub fn getChildNodes(self: *const Node, allocator: *Allocator) !ArrayList(*Node) {
        var children = ArrayList(*Node).init(allocator);
        var child = self.first_child;
        while (child != null) {
            try children.append(child.?);
            child = child.?.next_sibling;
        }
        return children;
    }

    pub fn cloneNode(self: *const Node, deep: bool) !*Node {
        const clone = try Node.init(self.allocator, self.node_type, self.node_name);
        
        // Clone node value if it exists
        if (self.node_value) |value| {
            try clone.setNodeValue(value);
        }
        
        // Clone namespace URI if it exists
        if (self.namespace_uri) |uri| {
            clone.namespace_uri = try self.allocator.dupe(u8, uri);
        }
        
        clone.element_namespace = self.element_namespace;
        
        // Clone attributes if they exist
        if (self.attributes) |attrs| {
            var clone_attrs = NamedNodeMap.init(self.allocator);
            var iter = attrs.attributes.iterator();
            while (iter.next()) |entry| {
                try clone_attrs.setNamedItem(entry.key_ptr.*, entry.value_ptr.*);
            }
            clone.attributes = clone_attrs;
        }
        
        // Clone children if requested and they exist
        if (deep and self.hasChildNodes()) {
            var child = self.first_child;
            while (child != null) {
                const child_clone = try child.?.cloneNode(true);
                try clone.appendChild(child_clone);
                child = child.?.next_sibling;
            }
        }
        
        return clone;
    }
    
    pub fn getTextContent(self: *const Node, allocator: *Allocator) !?[]const u8 {
        switch (self.node_type) {
            .TEXT_NODE, .COMMENT_NODE, .CDATA_SECTION_NODE, .PROCESSING_INSTRUCTION_NODE, .ATTRIBUTE_NODE => {
                return self.node_value;
            },
            .ELEMENT_NODE, .DOCUMENT_FRAGMENT_NODE => {
                var result = ArrayList(u8).init(allocator);
                defer result.deinit();
                
                var child = self.first_child;
                while (child != null) {
                    if (try child.?.getTextContent(allocator)) |content| {
                        defer allocator.free(content);
                        try result.appendSlice(content);
                    }
                    child = child.?.next_sibling;
                }
                
                if (result.items.len == 0) {
                    return null;
                }
                
                return try allocator.dupe(u8, result.items);
            },
            else => return null,
        }
    }
    
    pub fn setTextContent(self: *Node, content: ?[]const u8) !void {
        switch (self.node_type) {
            .TEXT_NODE, .COMMENT_NODE, .CDATA_SECTION_NODE, .PROCESSING_INSTRUCTION_NODE, .ATTRIBUTE_NODE => {
                try self.setNodeValue(content);
            },
            .ELEMENT_NODE, .DOCUMENT_FRAGMENT_NODE => {
                // Remove all children
                while (self.first_child != null) {
                    var child = self.first_child.?;
                    try self.removeChild(child);
                    child.deinitRecursive();
                    self.allocator.destroy(child);
                }
                
                // Add a single text node if content is provided
                if (content) |text| {
                    if (text.len > 0) {
                        const text_node = try Node.init(self.allocator, .TEXT_NODE, "#text");
                        try text_node.setNodeValue(text);
                        try self.appendChild(text_node);
                    }
                }
            },
            else => {},
        }
    }
    
    pub fn setConnected(self: *Node, connected: bool) void {
        if (self.is_connected == connected) {
            return;
        }
        
        self.is_connected = connected;
        
        // Update all child nodes
        var child = self.first_child;
        while (child != null) {
            child.?.setConnected(connected);
            child = child.?.next_sibling;
        }
    }
    
    pub fn getAttribute(self: *const Node, name: []const u8) ?[]const u8 {
        if (self.attributes) |attrs| {
            return attrs.getNamedItem(name);
        }
        return null;
    }
    
    pub fn setAttribute(self: *Node, name: []const u8, value: []const u8) !void {
        if (self.node_type != .ELEMENT_NODE) {
            return error.InvalidNodeTypeError;
        }
        
        if (self.attributes == null) {
            self.attributes = NamedNodeMap.init(self.allocator);
        }
        
        try self.attributes.?.setNamedItem(name, value);
    }
    
    pub fn removeAttribute(self: *Node, name: []const u8) bool {
        if (self.node_type != .ELEMENT_NODE or self.attributes == null) {
            return false;
        }
        
        return self.attributes.?.removeNamedItem(name);
    }
    
    pub fn hasAttribute(self: *const Node, name: []const u8) bool {
        return self.getAttribute(name) != null;
    }
    
    pub fn getElementsByTagName(self: *const Node, tag_name: []const u8, allocator: *Allocator) !ArrayList(*Node) {
        var result = ArrayList(*Node).init(allocator);
        errdefer result.deinit();
        
        try self.collectElementsByTagName(tag_name, &result);
        return result;
    }
    
    fn collectElementsByTagName(self: *const Node, tag_name: []const u8, result: *ArrayList(*Node)) !void {
        var child = self.first_child;
        while (child != null) {
            if (child.?.node_type == .ELEMENT_NODE) {
                const all_elements = std.mem.eql(u8, tag_name, "*");
                
                if (all_elements or std.mem.eql(u8, child.?.node_name, tag_name)) {
                    try result.append(child.?);
                }
                
                try child.?.collectElementsByTagName(tag_name, result);
            }
            
            child = child.?.next_sibling;
        }
    }
};

pub const Element = struct {
    node: *Node,
    
    pub fn init(allocator: *Allocator, tag_name: []const u8) !Element {
        const node = try Node.init(allocator, .ELEMENT_NODE, tag_name);
        return Element{ .node = node };
    }
    
    pub fn getAttribute(self: Element, name: []const u8) ?[]const u8 {
        return self.node.getAttribute(name);
    }
    
    pub fn setAttribute(self: Element, name: []const u8, value: []const u8) !void {
        try self.node.setAttribute(name, value);
    }
    
    pub fn removeAttribute(self: Element, name: []const u8) bool {
        return self.node.removeAttribute(name);
    }
    
    pub fn hasAttribute(self: Element, name: []const u8) bool {
        return self.node.hasAttribute(name);
    }
    
    pub fn getTagName(self: Element) []const u8 {
        return self.node.node_name;
    }
    
    pub fn getClassName(self: Element) ?[]const u8 {
        return self.getAttribute("class");
    }
    
    pub fn setClassName(self: Element, class_name: []const u8) !void {
        try self.setAttribute("class", class_name);
    }
    
    pub fn hasChildNodes(self: Element) bool {
        return self.node.hasChildNodes();
    }
    
    pub fn appendChild(self: Element, child: *Node) !void {
        try self.node.appendChild(child);
    }
    
    pub fn removeChild(self: Element, child: *Node) !void {
        try self.node.removeChild(child);
    }
    
    pub fn insertBefore(self: Element, new_child: *Node, reference_child: ?*Node) !void {
        try self.node.insertBefore(new_child, reference_child);
    }
    
    pub fn getElementsByTagName(self: Element, tag_name: []const u8, allocator: *Allocator) !ArrayList(*Node) {
        return self.node.getElementsByTagName(tag_name, allocator);
    }
};

pub const Text = struct {
    node: *Node,
    
    pub fn init(allocator: *Allocator, data: []const u8) !Text {
        const node = try Node.init(allocator, .TEXT_NODE, "#text");
        try node.setNodeValue(data);
        return Text{ .node = node };
    }
    
    pub fn getData(self: Text) ?[]const u8 {
        return self.node.node_value;
    }
    
    pub fn setData(self: Text, data: []const u8) !void {
        try self.node.setNodeValue(data);
    }
    
    pub fn getLength(self: Text) usize {
        if (self.node.node_value) |value| {
            return value.len;
        }
        return 0;
    }
    
    pub fn splitText(self: Text, offset: usize) !Text {
        const data = self.getData() orelse return error.NoDataError;
        
        if (offset > data.len) {
            return error.IndexSizeError;
        }
        
        // Create a new text node with the text after the offset
        const new_data = data[offset..];
        const new_text = try Text.init(self.node.allocator, new_data);
        
        // Update this text node to contain only the text before the offset
        try self.setData(data[0..offset]);
        
        // Insert the new text node after this one
        if (self.node.parent_node) |parent| {
            try parent.insertBefore(new_text.node, self.node.next_sibling);
        }
        
        return new_text;
    }
};

pub const Comment = struct {
    node: *Node,
    
    pub fn init(allocator: *Allocator, data: []const u8) !Comment {
        const node = try Node.init(allocator, .COMMENT_NODE, "#comment");
        try node.setNodeValue(data);
        return Comment{ .node = node };
    }
    
    pub fn getData(self: Comment) ?[]const u8 {
        return self.node.node_value;
    }
    
    pub fn setData(self: Comment, data: []const u8) !void {
        try self.node.setNodeValue(data);
    }
    
    pub fn getLength(self: Comment) usize {
        if (self.node.node_value) |value| {
            return value.len;
        }
        return 0;
    }
};

pub const Document = struct {
    node: *Node,
    doctype: ?*Node = null,
    document_element: ?*Node = null,
    
    pub fn init(allocator: *Allocator) !Document {
        const node = try Node.init(allocator, .DOCUMENT_NODE, "#document");
        node.owner_document = node;
        node.is_connected = true;
        
        return Document{ .node = node };
    }
    
    pub fn createElement(self: Document, tag_name: []const u8) !*Node {
        const element = try Node.init(self.node.allocator, .ELEMENT_NODE, tag_name);
        element.owner_document = self.node;
        return element;
    }
    
    pub fn createTextNode(self: Document, data: []const u8) !*Node {
        const text = try Node.init(self.node.allocator, .TEXT_NODE, "#text");
        try text.setNodeValue(data);
        text.owner_document = self.node;
        return text;
    }
    
    pub fn createComment(self: Document, data: []const u8) !*Node {
        const comment = try Node.init(self.node.allocator, .COMMENT_NODE, "#comment");
        try comment.setNodeValue(data);
        comment.owner_document = self.node;
        return comment;
    }
    
    pub fn createDocumentFragment(self: Document) !*Node {
        const fragment = try Node.init(self.node.allocator, .DOCUMENT_FRAGMENT_NODE, "#document-fragment");
        fragment.owner_document = self.node;
        return fragment;
    }
    
    pub fn getElementById(self: Document, id: []const u8) ?*Node {
        return self.findElementById(self.node, id);
    }
    
    fn findElementById(self: Document, node: *Node, id: []const u8) ?*Node {
        if (node.node_type == .ELEMENT_NODE) {
            if (node.getAttribute("id")) |node_id| {
                if (std.mem.eql(u8, node_id, id)) {
                    return node;
                }
            }
        }
        
        var child = node.first_child;
        while (child != null) {
            if (self.findElementById(child.?, id)) |element| {
                return element;
            }
            child = child.?.next_sibling;
        }
        
        return null;
    }
    
    pub fn getElementsByTagName(self: Document, tag_name: []const u8, allocator: *Allocator) !ArrayList(*Node) {
        return self.node.getElementsByTagName(tag_name, allocator);
    }
    
    pub fn appendChild(self: Document, child: *Node) !void {
        try self.node.appendChild(child);
        
        // Update document_element if this is an element node and would become the root element
        if (child.node_type == .ELEMENT_NODE) {
            if (self.document_element == null) {
                self.document_element = child;
            } else if (self.document_element != child) {
                // Check if there are other element siblings
                var has_other_element = false;
                var sibling = self.node.first_child;
                
                while (sibling != null) {
                    if (sibling.? != child and sibling.?.node_type == .ELEMENT_NODE) {
                        has_other_element = true;
                        break;
                    }
                    sibling = sibling.?.next_sibling;
                }
                
                // Only one element can be the document element
                if (!has_other_element) {
                    self.document_element = child;
                }
            }
        } else if (child.node_type == .DOCUMENT_TYPE_NODE) {
            self.doctype = child;
        }
    }
    
    pub fn removeChild(self: Document, child: *Node) !void {
        try self.node.removeChild(child);
        
        // Update document_element if the removed child was the document element
        if (child == self.document_element) {
            self.document_element = null;
            
            // Find a new document element if one exists
            var node = self.node.first_child;
            while (node != null) {
                if (node.?.node_type == .ELEMENT_NODE) {
                    self.document_element = node.?;
                    break;
                }
                node = node.?.next_sibling;
            }
        } else if (child == self.doctype) {
            self.doctype = null;
        }
    }
}; 