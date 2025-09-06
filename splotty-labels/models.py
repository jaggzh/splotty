from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Literal

NodeType = Literal["branch", "field"]

@dataclass
class TreeNode:
    id: str
    name: str
    type: NodeType
    parent_id: Optional[str]
    children: List[str] = field(default_factory=list)
    expanded: bool = True
    field_id: Optional[str] = None  # if leaf, which Field it refers to

@dataclass
class FieldDef:
    id: str            # stable identifier, e.g., "S1.raw"
    label: str         # display label
    tags: Set[str] = field(default_factory=set)
    origin_index: Optional[int] = None

@dataclass
class Preset:
    name: str
    device: str = ""
    baud: int = 115200
    parity: str = "N"
    stopbits: int = 1
    monitor_secs: int = 3
    ui_max_preview: int = 8
    ui_max_dynamic: int = 3
    ui_max_help: int = 2
    tree_nodes: Dict[str, TreeNode] = field(default_factory=dict)
    fields: Dict[str, FieldDef] = field(default_factory=dict)
    root_id: str = "root"
    last_preview: Optional[dict] = None  # {"label_line": str, "data_line": str}
