"""Print the Redis start command built from redis-start.sh.

    python3 to-start-command.py            # print the start command
    python3 to-start-command.py --check    # exit 1 if template.json differs
    python3 to-start-command.py --write    # update template.json in place

The script is joined into one line (comments and blank lines dropped, lines
joined with "; " unless they end in then/do/else) and wrapped in
/bin/bash -c '<script>'. The script itself execs the image's entrypoint
(docker-entrypoint.sh redis-server /etc/redis-railway/redis.conf).
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "redis-start.sh"
TEMPLATE = HERE.parent.parent / "template.json"
SERVICE = "Redis"
PREFIX = "/bin/bash -c '"
SUFFIX = "'"
OPENERS = ("then", "do", "else")


def build() -> str:
    lines = []
    for raw in SCRIPT.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "'" in line or "\\" in line:
            raise SystemExit(f"single quote or backslash not allowed: {line}")
        lines.append(line)
    out = ""
    for i, line in enumerate(lines):
        out += line
        if i < len(lines) - 1:
            out += " " if line.split()[-1] in OPENERS else "; "
    return PREFIX + out + SUFFIX


def main() -> int:
    command = build()
    template = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    current = template["services"][SERVICE].get("startCommand")
    if "--check" in sys.argv:
        if current != command:
            print("template.json startCommand is out of date; run with --write")
            return 1
        print(f"OK: template.json startCommand matches redis-start.sh ({len(command)} chars)")
        return 0
    if "--write" in sys.argv:
        template["services"][SERVICE]["startCommand"] = command
        TEMPLATE.write_text(json.dumps(template, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"template.json updated ({len(command)} chars)")
        return 0
    print(command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
