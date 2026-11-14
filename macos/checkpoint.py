#!/usr/bin/env python3
"""Keep a validated, nonempty JSON backup outside scheduled backup retention."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import tempfile
from pathlib import Path
import uuid


def checkpoint(source, destination):
    data = Path(source).read_bytes()
    document = json.loads(data)
    if document.get('version') != 1:
        raise ValueError('Unsupported backup version')
    for section in ['library', 'categories', 'progress']:
        if not isinstance(document.get(section), list):
            raise ValueError(f'Invalid {section} section')
    if not any(item.get('inLibrary') is True for item in document['library']):
        raise ValueError('Refusing an empty-library checkpoint; existing checkpoints remain untouched')
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = datetime.now(timezone.utc).strftime('sumidoku-verified-%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8] + '.json'
    target = destination / name
    # Exclusive creation: never replace a previous known-good snapshot.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination, suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(data).hexdigest()
    with target.with_suffix('.json.sha256').open('x') as stream:
        stream.write(f'{digest}  {target.name}\n')
    return target


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exported_json', type=Path)
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Documents/Sumidoku Backups/checkpoints')
    args = parser.parse_args()
    try:
        print(checkpoint(args.exported_json, args.destination))
    except (ValueError, OSError, TypeError, AttributeError) as error:
        parser.exit(1, f'Checkpoint rejected: {error}\n')
