from __future__ import annotations
import json
from pathlib import Path
from typing import Tuple
from models import Preset, TreeNode, FieldDef

SCHEMA_VERSION = 1

class Storage:
    def __init__(self, base_dir: Path):
        self.base_dir = base_dir
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def preset_path(self, name: str) -> Path:
        return self.base_dir / f"{name}.json"

    def list_presets(self) -> list[str]:
        return sorted(p.stem for p in self.base_dir.glob("*.json"))

    def load(self, name: str) -> Preset:
        p = self.preset_path(name)
        if not p.exists():
            # create an empty preset with a default root branch
            preset = Preset(name=name)
            preset.tree_nodes[preset.root_id] = TreeNode(
                id=preset.root_id, name="Root", type="branch", parent_id=None, children=[], expanded=True
            )
            return preset
        data = json.loads(p.read_text())
        # minimal tolerant loader
        preset = Preset(name=data.get("name", name))
        preset.device = data.get("device", "")
        preset.baud = data.get("baud", 115200)
        preset.parity = data.get("parity", "N")
        preset.stopbits = data.get("stopbits", 1)
        preset.monitor_secs = data.get("monitor_secs", 3)
        preset.ui_max_preview = data.get("ui_max_preview", 8)
        preset.ui_max_dynamic = data.get("ui_max_dynamic", 3)
        preset.ui_max_help = data.get("ui_max_help", 2)
        preset.root_id = data.get("root_id", "root")
        preset.last_preview = data.get("last_preview")
        # nodes
        for nid, nd in data.get("tree_nodes", {}).items():
            preset.tree_nodes[nid] = TreeNode(
                id=nid,
                name=nd["name"],
                type=nd["type"],
                parent_id=nd.get("parent_id"),
                children=nd.get("children", []),
                expanded=nd.get("expanded", True),
                field_id=nd.get("field_id"),
            )
        # fields
        for fid, fd in data.get("fields", {}).items():
            preset.fields[fid] = FieldDef(
                id=fid, label=fd.get("label", fid), tags=set(fd.get("tags", [])), origin_index=fd.get("origin_index")
            )
        # ensure root exists
        if preset.root_id not in preset.tree_nodes:
            preset.tree_nodes[preset.root_id] = TreeNode(
                id=preset.root_id, name="Root", type="branch", parent_id=None
            )
        return preset

    def save(self, preset: Preset) -> None:
        p = self.preset_path(preset.name)
        tmp = p.with_suffix(".json.tmp")
        data = {
            "schema": SCHEMA_VERSION,
            "name": preset.name,
            "device": preset.device,
            "baud": preset.baud,
            "parity": preset.parity,
            "stopbits": preset.stopbits,
            "monitor_secs": preset.monitor_secs,
            "ui_max_preview": preset.ui_max_preview,
            "ui_max_dynamic": preset.ui_max_dynamic,
            "ui_max_help": preset.ui_max_help,
            "root_id": preset.root_id,
            "last_preview": preset.last_preview,
            "tree_nodes": {
                nid: {
                    "name": nd.name,
                    "type": nd.type,
                    "parent_id": nd.parent_id,
                    "children": nd.children,
                    "expanded": nd.expanded,
                    "field_id": nd.field_id,
                }
                for nid, nd in preset.tree_nodes.items()
            },
            "fields": {
                fid: {"label": f.label, "tags": sorted(f.tags), "origin_index": f.origin_index}
                for fid, f in preset.fields.items()
            },
        }
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(p)
