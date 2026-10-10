"""Join the shard-NN directories of a sharded traces run into one output directory that
the later shorten_sft.py steps (build, train, ...) read as if one job had made it.

    python experiments/metacentrum/merge_shards.py results/shorten-sft-full

Every key holds the question id, so the shards never share a key: joining is
concatenation. A shard that has not finished both steps stops the merge."""

import json
from pathlib import Path
import sys

FILES = ["questions.jsonl", "sample-gen.jsonl", "traces.jsonl", "oracle-gen.jsonl"]

root = Path(sys.argv[1])
shards = sorted(root.glob("shard-*"))
assert shards, f"no shard-* directories in {root}"
for shard in shards:
    missing = [f for f in FILES if not (shard / f).exists()]
    assert not missing, f"{shard.name} has no {', '.join(missing)}: not finished"
    questions = sum(1 for _ in (shard / "questions.jsonl").open())
    sampled = sum(1 for _ in (shard / "sample-gen.jsonl").open())
    assert sampled == questions, f"{shard.name}: {sampled} of {questions} questions sampled"

for name in FILES:
    keys = set()
    with (root / name).open("w") as out:
        for shard in shards:
            with (shard / name).open() as f:
                for line in f:
                    key = json.loads(line)["key" if name != "questions.jsonl" else "qid"]
                    assert key not in keys, f"{key} in two shards"
                    keys.add(key)
                    out.write(line)
    print(f"{name}: {len(keys)} rows from {len(shards)} shards")
