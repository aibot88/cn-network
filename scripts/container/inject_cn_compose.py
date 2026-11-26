#!/usr/bin/env python3
"""Inject Mainland-China runtime network settings into any docker-compose YAML.

Injects into each target service under `services:`:
  * dns: [223.5.5.5, 119.29.29.29]   (merges without dropping existing DNS)
  * extra_hosts: ["host.docker.internal:host-gateway"]
  * environment:
      NO_PROXY / no_proxy containing "127.0.0.1,localhost,::1,host.docker.internal,.local"
      TZ: "Asia/Shanghai" (only if TZ is not already set)
  * optional (--disable-ipv6): sysctls net.ipv6.conf.{all,default}.disable_ipv6="1"

Cross-platform (macOS / Linux / Windows) and Python 3.6+ compatible. Uses PyYAML
when installed and falls back to a pure-stdlib line-aware injector when PyYAML
is unavailable. Always writes LF line endings.

Usage:
  python3 scripts/container/inject_cn_compose.py docker-compose.yml
  python scripts/container/inject_cn_compose.py compose.yaml --in-place
  python3 scripts/container/inject_cn_compose.py docker-compose.yml -o out.yml --services app,worker
  python3 scripts/container/inject_cn_compose.py docker-compose.yml --disable-ipv6 --dry-run
"""
import argparse
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None  # type: ignore

DEFAULT_DNS = ["223.5.5.5", "119.29.29.29"]
DEFAULT_EXTRA_HOST = "host.docker.internal:host-gateway"
DEFAULT_NO_PROXY_TOKENS = ["127.0.0.1", "localhost", "::1", "host.docker.internal", ".local"]
DEFAULT_TZ = "Asia/Shanghai"


def _merge_no_proxy(existing: Optional[str], required: Sequence[str]) -> str:
    tokens: List[str] = []
    if existing:
        for part in str(existing).split(","):
            t = part.strip()
            if t and t not in tokens:
                tokens.append(t)
    for req in required:
        if req not in tokens:
            tokens.append(req)
    return ",".join(tokens)


def _merge_dns(cur: Any, required_dns: Sequence[str]) -> List[str]:
    out: List[str] = []
    if isinstance(cur, str):
        if cur.strip():
            out.append(cur.strip())
    elif isinstance(cur, list):
        for item in cur:
            s = str(item).strip()
            if s and s not in out:
                out.append(s)
    for ip in required_dns:
        if ip not in out:
            out.append(ip)
    return out


def _merge_extra_hosts(cur: Any, entry: str = DEFAULT_EXTRA_HOST) -> Any:
    host, target = entry.split(":", 1)
    if cur is None:
        return [entry]
    if isinstance(cur, dict):
        if host not in cur:
            cur[host] = target
        return cur
    if isinstance(cur, list):
        items = [str(x) for x in cur]
        if not any(x.startswith(host + ":") or x.startswith(host + "=") for x in items):
            items.append(entry)
        return items
    return [str(cur), entry]


def _merge_environment(cur: Any, no_proxy_tokens: Sequence[str], tz: str) -> Any:
    if cur is None:
        np = _merge_no_proxy("", no_proxy_tokens)
        return {"NO_PROXY": np, "no_proxy": np, "TZ": tz}
    if isinstance(cur, dict):
        for key in ("NO_PROXY", "no_proxy"):
            cur[key] = _merge_no_proxy(cur.get(key), no_proxy_tokens)
        if "TZ" not in cur:
            cur["TZ"] = tz
        return cur
    if isinstance(cur, list):
        items = list(cur)
        idx_map: Dict[str, int] = {}
        for idx, raw in enumerate(items):
            s = str(raw)
            if "=" in s:
                k = s.split("=", 1)[0].strip()
                idx_map[k] = idx
            else:
                idx_map[s.strip()] = idx
        for key in ("NO_PROXY", "no_proxy"):
            if key in idx_map:
                i = idx_map[key]
                old = str(items[i])
                val = old.split("=", 1)[1] if "=" in old else ""
                items[i] = "%s=%s" % (key, _merge_no_proxy(val, no_proxy_tokens))
            else:
                items.append("%s=%s" % (key, _merge_no_proxy("", no_proxy_tokens)))
        if "TZ" not in idx_map:
            items.append("TZ=%s" % tz)
        return items
    return cur


def _merge_sysctls(cur: Any) -> Any:
    pairs = [
        ("net.ipv6.conf.all.disable_ipv6", "1"),
        ("net.ipv6.conf.default.disable_ipv6", "1"),
    ]
    if cur is None:
        return dict(pairs)
    if isinstance(cur, dict):
        for k, v in pairs:
            cur.setdefault(k, v)
        return cur
    if isinstance(cur, list):
        items = [str(x) for x in cur]
        for k, v in pairs:
            if not any(x.startswith(k + "=") for x in items):
                items.append("%s=%s" % (k, v))
        return items
    return cur


def inject_with_pyyaml(
    text: str,
    target_services: Optional[Sequence[str]],
    dns_list: Sequence[str],
    no_proxy_tokens: Sequence[str],
    disable_ipv6: bool,
) -> Tuple[str, List[str]]:
    data = yaml.safe_load(text)
    if not isinstance(data, dict) or not isinstance(data.get("services"), dict):
        raise ValueError("Compose file has no top-level 'services' mapping")

    services = data["services"]
    modified: List[str] = []
    wanted = set(target_services) if target_services else None

    for svc_name, svc_cfg in services.items():
        if wanted is not None and svc_name not in wanted:
            continue
        if svc_cfg is None:
            svc_cfg = {}
            services[svc_name] = svc_cfg
        if not isinstance(svc_cfg, dict):
            continue
        svc_cfg["dns"] = _merge_dns(svc_cfg.get("dns"), dns_list)
        svc_cfg["extra_hosts"] = _merge_extra_hosts(svc_cfg.get("extra_hosts"))
        svc_cfg["environment"] = _merge_environment(
            svc_cfg.get("environment"), no_proxy_tokens, DEFAULT_TZ
        )
        if disable_ipv6:
            svc_cfg["sysctls"] = _merge_sysctls(svc_cfg.get("sysctls"))
        modified.append(str(svc_name))

    class _OrderedSafeDumper(yaml.SafeDumper):
        pass

    def _dict_representer(dumper: Any, mapping: Dict[Any, Any]) -> Any:
        return dumper.represent_mapping("tag:yaml.org,2002:map", list(mapping.items()))

    _OrderedSafeDumper.add_representer(dict, _dict_representer)
    rendered = yaml.dump(
        data,
        Dumper=_OrderedSafeDumper,
        default_flow_style=False,
        allow_unicode=True,
        indent=2,
        line_break="\n",
    )
    return rendered, modified


def _yaml_quote(val: str) -> str:
    escaped = val.replace("\\", "\\\\").replace('"', '\\"')
    return '"%s"' % escaped


def inject_with_text_fallback(
    text: str,
    target_services: Optional[Sequence[str]],
    dns_list: Sequence[str],
    no_proxy_tokens: Sequence[str],
    disable_ipv6: bool,
) -> Tuple[str, List[str]]:
    """Pure-stdlib line-aware compose injector when PyYAML is not available."""
    lines = text.splitlines()
    n = len(lines)

    svc_start = -1
    for i, line in enumerate(lines):
        if re.match(r"^services:\s*(#.*)?$", line):
            svc_start = i
            break
    if svc_start < 0:
        raise ValueError("Compose file has no top-level 'services:' section")

    svc_end = n
    for i in range(svc_start + 1, n):
        line = lines[i]
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            svc_end = i
            break

    svc_indent: Optional[int] = None
    svc_headers: List[Tuple[int, str]] = []
    for i in range(svc_start + 1, svc_end):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if svc_indent is None:
            svc_indent = indent
        if indent == svc_indent:
            m = re.match(r"^([A-Za-z0-9_.-]+):\s*(#.*)?$", stripped)
            if m:
                svc_headers.append((i, m.group(1)))

    if not svc_headers or svc_indent is None:
        raise ValueError("No services found under 'services:'")

    wanted = set(target_services) if target_services else None
    child_indent = " " * (svc_indent + 2)
    item_indent = " " * (svc_indent + 4)
    modified: List[str] = []

    for idx in range(len(svc_headers) - 1, -1, -1):
        h_line, svc_name = svc_headers[idx]
        if wanted is not None and svc_name not in wanted:
            continue
        block_end = svc_headers[idx + 1][0] if idx + 1 < len(svc_headers) else svc_end
        insert_at = block_end
        while insert_at > h_line + 1 and not lines[insert_at - 1].strip():
            insert_at -= 1

        block = lines[h_line + 1 : insert_at]
        has_dns = any(re.match(r"^%sdns:" % re.escape(child_indent), l) for l in block)
        has_extra = any(re.match(r"^%sextra_hosts:" % re.escape(child_indent), l) for l in block)
        has_sysctls = any(re.match(r"^%ssysctls:" % re.escape(child_indent), l) for l in block)

        env_idx = -1
        for bi, bl in enumerate(block):
            if re.match(r"^%senvironment:" % re.escape(child_indent), bl):
                env_idx = bi
                break

        np_str = _merge_no_proxy("", no_proxy_tokens)
        additions: List[str] = []
        if not has_dns:
            additions.append("%sdns: [%s]" % (child_indent, ", ".join(dns_list)))
        if not has_extra:
            additions.append("%sextra_hosts:" % child_indent)
            additions.append("%s- %s" % (item_indent, _yaml_quote(DEFAULT_EXTRA_HOST)))
        if disable_ipv6 and not has_sysctls:
            additions.append("%ssysctls:" % child_indent)
            additions.append('%snet.ipv6.conf.all.disable_ipv6: "1"' % item_indent)
            additions.append('%snet.ipv6.conf.default.disable_ipv6: "1"' % item_indent)

        if env_idx < 0:
            additions.append("%senvironment:" % child_indent)
            additions.append("%sNO_PROXY: %s" % (item_indent, _yaml_quote(np_str)))
            additions.append("%sno_proxy: %s" % (item_indent, _yaml_quote(np_str)))
            additions.append("%sTZ: %s" % (item_indent, _yaml_quote(DEFAULT_TZ)))
        else:
            e_end = env_idx + 1
            while e_end < len(block):
                bl = block[e_end]
                if not bl.strip() or bl.lstrip().startswith("#"):
                    e_end += 1
                    continue
                if (len(bl) - len(bl.lstrip(" "))) <= len(child_indent):
                    break
                e_end += 1
            env_slice = block[env_idx + 1 : e_end]
            is_list_env = any(l.lstrip().startswith("- ") for l in env_slice)
            env_extra: List[str] = []
            seen_keys = set()
            for offset in range(env_idx + 1, e_end):
                raw_line = lines[h_line + 1 + offset]
                s_line = raw_line.strip()
                if not s_line or s_line.startswith("#"):
                    continue
                if is_list_env and s_line.startswith("- "):
                    kv = s_line[2:].strip()
                    if "=" in kv:
                        ek, ev = kv.split("=", 1)
                        ek = ek.strip()
                        seen_keys.add(ek)
                        if ek in ("NO_PROXY", "no_proxy"):
                            merged = _merge_no_proxy(ev.strip().strip('"').strip("'"), no_proxy_tokens)
                            lines[h_line + 1 + offset] = "%s- %s=%s" % (item_indent, ek, merged)
                elif not is_list_env and ":" in s_line:
                    ek, ev = s_line.split(":", 1)
                    ek = ek.strip()
                    seen_keys.add(ek)
                    if ek in ("NO_PROXY", "no_proxy"):
                        merged = _merge_no_proxy(ev.strip().strip('"').strip("'"), no_proxy_tokens)
                        lines[h_line + 1 + offset] = "%s%s: %s" % (item_indent, ek, _yaml_quote(merged))

            if is_list_env:
                if "NO_PROXY" not in seen_keys:
                    env_extra.append("%s- NO_PROXY=%s" % (item_indent, np_str))
                if "no_proxy" not in seen_keys:
                    env_extra.append("%s- no_proxy=%s" % (item_indent, np_str))
                if "TZ" not in seen_keys:
                    env_extra.append("%s- TZ=%s" % (item_indent, DEFAULT_TZ))
            else:
                if "NO_PROXY" not in seen_keys:
                    env_extra.append("%sNO_PROXY: %s" % (item_indent, _yaml_quote(np_str)))
                if "no_proxy" not in seen_keys:
                    env_extra.append("%sno_proxy: %s" % (item_indent, _yaml_quote(np_str)))
                if "TZ" not in seen_keys:
                    env_extra.append("%sTZ: %s" % (item_indent, _yaml_quote(DEFAULT_TZ)))
            if env_extra:
                abs_env_insert = h_line + 1 + e_end
                lines[abs_env_insert:abs_env_insert] = env_extra
                insert_at += len(env_extra)

        if additions:
            lines[insert_at:insert_at] = additions
        modified.append(svc_name)

    modified.reverse()
    return "\n".join(lines) + "\n", modified


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Inject Mainland-China DNS, extra_hosts, NO_PROXY, and TZ into a docker-compose file."
    )
    parser.add_argument("compose_file", type=Path, help="Input docker-compose YAML file")
    parser.add_argument("-o", "--output", type=Path, default=None, help="Output file path (default: stdout)")
    parser.add_argument("-i", "--in-place", action="store_true", help="Modify compose_file in place")
    parser.add_argument("--no-backup", action="store_true", help="Do not write .cn-bak with --in-place")
    parser.add_argument("--services", default="", help="Comma-separated service names (default: all)")
    parser.add_argument(
        "--dns",
        default=",".join(DEFAULT_DNS),
        help="Comma-separated DNS servers (default: 223.5.5.5,119.29.29.29)",
    )
    parser.add_argument(
        "--no-proxy-extra",
        default="",
        help="Comma-separated extra entries to append to NO_PROXY/no_proxy",
    )
    parser.add_argument("--disable-ipv6", action="store_true", help="Also inject sysctls disabling IPv6")
    parser.add_argument("--dry-run", action="store_true", help="Print rendered YAML without writing files")
    parser.add_argument(
        "--engine",
        choices=("auto", "pyyaml", "text"),
        default="auto",
        help="YAML engine selection (default: auto)",
    )
    args = parser.parse_args(argv)

    if not args.compose_file.is_file():
        print("[inject_cn_compose] ERROR: file not found: %s" % args.compose_file, file=sys.stderr)
        return 2

    text = args.compose_file.read_text(encoding="utf-8", errors="replace")
    target_services = [s.strip() for s in args.services.split(",") if s.strip()] or None
    dns_list = [d.strip() for d in args.dns.split(",") if d.strip()] or list(DEFAULT_DNS)
    no_proxy_tokens = list(DEFAULT_NO_PROXY_TOKENS)
    for tok in args.no_proxy_extra.split(","):
        t = tok.strip()
        if t and t not in no_proxy_tokens:
            no_proxy_tokens.append(t)

    use_pyyaml = (args.engine == "pyyaml") or (args.engine == "auto" and yaml is not None)
    if args.engine == "pyyaml" and yaml is None:
        print("[inject_cn_compose] ERROR: PyYAML requested but not installed", file=sys.stderr)
        return 2

    try:
        if use_pyyaml:
            rendered, modified = inject_with_pyyaml(
                text, target_services, dns_list, no_proxy_tokens, args.disable_ipv6
            )
        else:
            rendered, modified = inject_with_text_fallback(
                text, target_services, dns_list, no_proxy_tokens, args.disable_ipv6
            )
    except Exception as exc:
        print("[inject_cn_compose] ERROR: %s" % exc, file=sys.stderr)
        return 1

    if args.dry_run or (not args.in_place and args.output is None):
        sys.stdout.write(rendered)
        print(
            "[inject_cn_compose] updated services (%s): %s"
            % ("pyyaml" if use_pyyaml else "text", ", ".join(modified)),
            file=sys.stderr,
        )
        return 0

    dest = args.compose_file if args.in_place else args.output
    if args.in_place and not args.no_backup:
        bak = Path(str(args.compose_file) + ".cn-bak")
        if not bak.exists():
            shutil.copy2(str(args.compose_file), str(bak))
    with open(str(dest), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(rendered)
    print(
        "[inject_cn_compose] wrote %s (%s; services=%s)"
        % (dest, "pyyaml" if use_pyyaml else "text", ", ".join(modified)),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
