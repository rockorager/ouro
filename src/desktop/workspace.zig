//! Protocol-neutral workspace policy values.

pub const GroupId = packed struct { value: u64 };
pub const WorkspaceId = packed struct { value: u64 };

pub const GroupCapabilities = packed struct(u32) {
    create_workspace: bool = false,
    _reserved: u31 = 0,
};

pub const State = packed struct(u32) {
    active: bool = false,
    urgent: bool = false,
    hidden: bool = false,
    _reserved: u29 = 0,
};

pub const Capabilities = packed struct(u32) {
    activate: bool = false,
    deactivate: bool = false,
    remove: bool = false,
    assign: bool = false,
    _reserved: u28 = 0,
};

pub const Group = struct {
    id: GroupId,
    capabilities: GroupCapabilities = .{},
};

pub const Workspace = struct {
    id: WorkspaceId,
    group: GroupId,
    identifier: []const u8,
    name: []const u8,
    state: State = .{},
    capabilities: Capabilities = .{},
};

pub const Request = struct {
    workspace: WorkspaceId,
    kind: Kind,

    pub const Kind = union(enum) {
        activate,
        deactivate,
        remove,
        assign: GroupId,
    };
};
