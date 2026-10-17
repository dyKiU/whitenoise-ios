#!/usr/bin/env python3
"""Loopback-only Nostr fault proxy. Never logs frames or account data."""
import argparse
import asyncio
import json
import logging
from pathlib import Path
import signal
from urllib.parse import urlsplit

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


async def run(args):
    endpoint = urlsplit(args.upstream)
    if endpoint.scheme != 'ws' or endpoint.hostname != '127.0.0.1' or endpoint.port is None:
        raise ValueError('loopback upstream required')
    rejected = 0
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stopped.set)

    async def handle(downstream):
        nonlocal rejected
        tasks = []
        try:
            async with connect(args.upstream, proxy=None, max_size=2097152,
                               max_queue=16, close_timeout=2) as upstream:
                async def forward():
                    nonlocal rejected
                    async for frame in downstream:
                        command = json.loads(frame)
                        if isinstance(command, list) and len(command) == 2 and command[0] == 'EVENT':
                            event = command[1]
                            text = args.control.read_text()
                            if len(text) > 6:
                                raise ValueError('invalid control')
                            kind = int(text)
                            if kind and isinstance(event, dict) and event.get('kind') == kind:
                                event_id = event.get('id')
                                if not isinstance(event_id, str) or len(event_id) != 64:
                                    raise ValueError('invalid event id')
                                rejected += 1
                                args.control.with_suffix('.rejected').write_text(str(rejected))
                                await downstream.send(json.dumps(['OK', event_id, False,
                                    'error: isolated transient acceptance fault']))
                                continue
                        await upstream.send(frame)

                async def backward():
                    async for frame in upstream:
                        await downstream.send(frame)

                tasks = [asyncio.create_task(forward()), asyncio.create_task(backward())]
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
        except ConnectionClosed:
            pass
        except (OSError, ValueError, TypeError):
            # No tracebacks: malformed synthetic traffic/control closes this
            # connection and the controller will fail its acceptance gate.
            await downstream.close(code=1011, reason='isolated proxy refused')
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    logger = logging.getLogger('isolated-fault-proxy')
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    async with serve(handle, '127.0.0.1', args.port, max_size=2097152,
                     max_queue=16, close_timeout=2, logger=logger):
        print('ws://127.0.0.1:' + str(args.port), flush=True)
        await stopped.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--control', type=Path, required=True)
    try:
        asyncio.run(run(parser.parse_args()))
    except (OSError, ValueError):
        raise SystemExit('isolated proxy startup refused')
