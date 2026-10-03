#!/usr/bin/env python3
"""Print the Steam data that a recipe needs, from the local Steam caches.

Reads appcache/appinfo.vdf and appcache/packageinfo.vdf from the native Mac Steam and from
the Silicon Cellar Steam prefix. Steam must have seen the app once (owned or opened in the
store) for it to be in the cache.

Usage:
  steam-app-info.py <Steam app ID>...   one JSON entry per app
  steam-app-info.py --owned             every owned game, with "hasRecipe"

Each entry has steamID, title, oslist, installFolder (the recipe "installFolder"),
windowsExecutables (candidates for "executable" / "executableRelativePath"), and
launchOptions (executable, arguments, oslist of each Steam launch entry).
"""

import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STEAM_ROOTS = [
    Path.home() / "Library/Application Support/Steam",
    Path.home() / "Library/Application Support/SiliconCellar/prefix/drive_c/Program Files (x86)/Steam",
]
APP_INFO_MAGIC_WITH_STRING_TABLE = 0x07564429


def read_cstring(data: bytes, offset: int) -> tuple[str, int]:
    end = data.index(b"\x00", offset)
    return data[offset:end].decode("utf-8", "replace"), end + 1


def read_binary_kv(data: bytes, offset: int, key_names: list[str] | None = None) -> tuple[dict, int]:
    result = {}
    while True:
        value_type = data[offset]
        offset += 1
        if value_type == 0x08:
            return result, offset
        if key_names is None:
            key, offset = read_cstring(data, offset)
        else:
            (key_index,) = struct.unpack_from("<I", data, offset)
            offset += 4
            key = key_names[key_index]
        if value_type == 0x00:
            result[key], offset = read_binary_kv(data, offset, key_names)
        elif value_type == 0x01:
            result[key], offset = read_cstring(data, offset)
        elif value_type in (0x02, 0x04, 0x06):
            (result[key],) = struct.unpack_from("<I", data, offset)
            offset += 4
        elif value_type == 0x03:
            (result[key],) = struct.unpack_from("<f", data, offset)
            offset += 4
        elif value_type in (0x07, 0x0A):
            (result[key],) = struct.unpack_from("<Q", data, offset)
            offset += 8
        else:
            raise ValueError(f"unknown KV type {value_type:#x} at {offset}")


def read_package_app_ids(path: Path) -> dict[int, list[int]]:
    data = path.read_bytes()
    magic, _universe = struct.unpack_from("<II", data, 0)
    has_token = (magic & 0xFF) >= 0x28
    offset = 8
    app_ids_by_package = {}
    while True:
        (package_id,) = struct.unpack_from("<I", data, offset)
        offset += 4
        if package_id == 0xFFFFFFFF:
            break
        offset += 20 + 4 + (8 if has_token else 0)
        package_kv, offset = read_binary_kv(data, offset)
        package_body = next(iter(package_kv.values()), {})
        app_ids_by_package[package_id] = [int(app_id) for app_id in package_body.get("appids", {}).values()]
    return app_ids_by_package


def read_app_infos(path: Path) -> dict[int, dict]:
    data = path.read_bytes()
    magic, _universe = struct.unpack_from("<II", data, 0)
    offset = 8
    key_names = None
    if magic == APP_INFO_MAGIC_WITH_STRING_TABLE:
        (string_table_offset,) = struct.unpack_from("<Q", data, offset)
        offset += 8
        (string_count,) = struct.unpack_from("<I", data, string_table_offset)
        key_names = []
        string_offset = string_table_offset + 4
        for _ in range(string_count):
            name, string_offset = read_cstring(data, string_offset)
            key_names.append(name)
    app_infos = {}
    while True:
        (app_id,) = struct.unpack_from("<I", data, offset)
        offset += 4
        if app_id == 0:
            break
        (entry_size,) = struct.unpack_from("<I", data, offset)
        entry_end = offset + 4 + entry_size
        # size, info state, last updated, PICS token, SHA-1, change number, binary SHA-1
        kv_offset = offset + 4 + 4 + 4 + 8 + 20 + 4 + 20
        app_kv, _ = read_binary_kv(data, kv_offset, key_names)
        app_infos[app_id] = app_kv.get("appinfo", app_kv)
        offset = entry_end
    return app_infos


def launch_options(app_info: dict) -> list[dict]:
    options = []
    for launch_entry in app_info.get("config", {}).get("launch", {}).values():
        if isinstance(launch_entry, dict) and launch_entry.get("executable"):
            options.append({
                "executable": launch_entry["executable"].replace("\\", "/"),
                "arguments": launch_entry.get("arguments", ""),
                "oslist": launch_entry.get("config", {}).get("oslist", ""),
            })
    return options


def windows_executables(app_info: dict) -> list[str]:
    executables = [
        option["executable"]
        for option in launch_options(app_info)
        if not option["oslist"] or "windows" in option["oslist"]
    ]
    return list(dict.fromkeys(executables))


def recipe_steam_ids() -> set[str]:
    return {
        str(json.loads(path.read_text()).get("steamID", ""))
        for path in (ROOT / "Recipes").glob("*.json")
    }


def describe(app_id: int, app_info: dict, steam_ids_with_recipe: set[str]) -> dict:
    common = app_info.get("common", {})
    return {
        "steamID": str(app_id),
        "title": common.get("name", ""),
        "oslist": common.get("oslist", ""),
        "installFolder": app_info.get("config", {}).get("installdir", ""),
        "windowsExecutables": windows_executables(app_info),
        "launchOptions": launch_options(app_info),
        "hasRecipe": str(app_id) in steam_ids_with_recipe,
    }


def main() -> int:
    arguments = sys.argv[1:]
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if arguments else 2

    owned_app_ids = set()
    app_infos = {}
    for steam_root in STEAM_ROOTS:
        package_path = steam_root / "appcache/packageinfo.vdf"
        app_info_path = steam_root / "appcache/appinfo.vdf"
        if package_path.exists():
            for package_id, app_ids in read_package_app_ids(package_path).items():
                if package_id != 0:
                    owned_app_ids.update(app_ids)
        if app_info_path.exists():
            app_infos.update(read_app_infos(app_info_path))

    steam_ids_with_recipe = recipe_steam_ids()
    if arguments == ["--owned"]:
        entries = [
            describe(app_id, app_infos[app_id], steam_ids_with_recipe)
            for app_id in sorted(owned_app_ids)
            if str(app_infos.get(app_id, {}).get("common", {}).get("type", "")).lower() == "game"
        ]
    else:
        missing = [app_id for app_id in arguments if not app_id.isdigit() or int(app_id) not in app_infos]
        if missing:
            print(f"Not in the local Steam cache: {', '.join(missing)}", file=sys.stderr)
            return 1
        entries = [describe(int(app_id), app_infos[int(app_id)], steam_ids_with_recipe) for app_id in arguments]
    json.dump(entries, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
