#!/usr/bin/env python3
"""Reorder a Bend file's top-level blocks so every def comes after the defs it
calls (Bend requires callees above callers). Comments directly above a block
travel with it; the file's leading imports and header stay first. Stable: an
already well-ordered file is left unchanged."""
import re
import sys


def blocks_of(src):
    lines = src.split("\n")
    head, i = [], 0
    while i < len(lines) and not re.match(r"(def|type|law|@unsafe)\b", lines[i]):
        head.append(lines[i])
        i += 1
    # pull trailing comment lines of the header into the first block
    pend = []
    while head and (head[-1].startswith("#") or head[-1] == "") and any(
        l.startswith("import") for l in head[:-1]
    ):
        pend.insert(0, head.pop())
        if pend[0].startswith("import"):
            head.append(pend.pop(0))
            break
    blocks, cur = [], pend
    for line in lines[i:]:
        top = re.match(r"(def|type|law|@unsafe)\b", line)
        if top and any(re.match(r"(def|type|law|@unsafe)\b", l) for l in cur):
            # split trailing comments/blank lines off into the next block
            tail = []
            while cur and (cur[-1].startswith("#") or cur[-1] == ""):
                tail.insert(0, cur.pop())
            blocks.append(cur)
            cur = tail
        cur.append(line)
    if cur:
        blocks.append(cur)
    return head, blocks


def name_of(block):
    for l in block:
        m = re.match(r"(?:def|type|law)\s+([A-Za-z_][A-Za-z0-9_.]*)", l)
        if m:
            return m.group(1)
    return None


def main(path):
    src = open(path).read()
    head, blocks = blocks_of(src)
    names = [name_of(b) for b in blocks]
    known = {n: i for i, n in enumerate(names) if n}
    deps = []
    for i, b in enumerate(blocks):
        body = "\n".join(l for l in b if not l.lstrip().startswith("#"))
        ds = set()
        for n, j in known.items():
            if j != i and re.search(r"(?<![A-Za-z0-9_.])" + re.escape(n) + r"(?![A-Za-z0-9_])\s*[\({]", body):
                ds.add(j)
        deps.append(ds)
    order, state = [], {}

    def visit(i):
        if state.get(i) == 2:
            return
        if state.get(i) == 1:
            return  # cycle: leave as is (Bend will report it)
        state[i] = 1
        for j in sorted(deps[i]):
            visit(j)
        state[i] = 2
        order.append(i)

    for i in range(len(blocks)):
        visit(i)
    out = "\n".join(head) + "\n" + "\n".join("\n".join(blocks[i]) for i in order)
    out = re.sub(r"\n{3,}", "\n\n", out)
    if not out.endswith("\n"):
        out += "\n"
    open(path, "w").write(out)


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
