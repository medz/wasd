#!/usr/bin/env python3
"""Offline audit of the fixed WASI 0.2.12 source and embedded contracts.

Usage: python3 tool/wasi_preview2_contract.py --sources /path/to/WASI \
    --wasm-tools .toolchains/bin/wasm-tools

The source directory must contain proposals/<package>/wit/*.wit. Checks run
offline; rebuilt contracts and fixture binaries use a temporary directory.
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check_bytes(data, expected, label):
    require(len(data) == expected['bytes'], f'{label}: byte length changed')
    require(digest(data) == expected['sha256'], f'{label}: SHA-256 changed')


def qualified(graph, interface_id):
    interface = graph['interfaces'][interface_id]
    package, version = graph['packages'][interface['package']]['name'].split('@')
    return f'{package}/{interface["name"]}@{version}'


def worlds(graph):
    result = {}
    for world in graph['worlds']:
        package, version = graph['packages'][world['package']]['name'].split('@')
        result[f'{package}/{world["name"]}@{version}'] = {
            direction: [qualified(graph, item['interface']['id'])
                        for item in world[direction].values()]
            for direction in ('imports', 'exports')
        }
    return result


def run(tool, package, features, *options):
    command = [str(tool), 'component', 'wit', str(package)]
    for feature in features:
        command.extend(['--features', feature])
    command.extend(options)
    return subprocess.run(command, check=True, capture_output=True).stdout


def value_type(graph, reference):
    """Compare wire structures while retaining nominal resource owners.

    Alias hops are checked by the embedded-source audit; binaries may flatten
    them. Field/label order, function parameter names and own/borrow remain.
    """
    if reference is None or isinstance(reference, str):
        return reference
    definition = graph['types'][reference]
    kind = definition['kind']
    if kind == 'resource':
        return ['resource', qualified(graph, definition['owner']['interface']),
                definition['name']]
    name, value = next(iter(kind.items()))
    if name == 'type':
        return value_type(graph, value)
    if name in ('list', 'option'):
        return [name, value_type(graph, value)]
    if name == 'handle':
        return [name, [(ownership, value_type(graph, target))
                       for ownership, target in value.items()]]
    if name == 'tuple':
        return [name, [value_type(graph, item) for item in value['types']]]
    if name == 'result':
        return [name, value_type(graph, value['ok']), value_type(graph, value['err'])]
    if name in ('record', 'variant'):
        members = value['fields' if name == 'record' else 'cases']
        return [name, [(item['name'], value_type(graph, item.get('type')))
                       for item in members]]
    if name in ('enum', 'flags'):
        return [name, [item['name'] for item in value['cases' if name == 'enum' else 'flags']]]
    raise ValueError(f'Unsupported fixed-contract type: {name}')


def interface_surface(graph, interface_id):
    interface = graph['interfaces'][interface_id]
    functions = {}
    for name, function in interface['functions'].items():
        kind = function['kind']
        if not isinstance(kind, str):
            kind = [(name, value_type(graph, target)) for name, target in kind.items()]
        functions[name] = {
            'kind': kind,
            'params': [(item['name'], value_type(graph, item['type']))
                       for item in function['params']],
            'result': value_type(graph, function.get('result')),
        }
    return {'types': {name: value_type(graph, target)
                      for name, target in interface['types'].items()},
            'functions': functions}


def world_surface(graph, world, direction):
    result = {}
    for key, item in world[direction].items():
        require('interface' in item, f'Unexpected non-interface {direction}: {key}')
        interface_id = item['interface']['id']
        canonical = key == f'interface-{interface_id}'
        name = ('interface', qualified(graph, interface_id)) if canonical else ('name', key)
        require(name not in result, f'Duplicate world key: {name}')
        result[name] = interface_surface(graph, interface_id)
    return result


def check_fixtures(tool, fixed, fixtures, directory):
    reports = []
    for name, expected in fixtures.items():
        binary = REPO / 'test/fixtures/wasi_preview2' / name
        data = binary.read_bytes()
        check_bytes(data, expected, name)
        check_bytes(binary.with_suffix('.wat').read_bytes(), expected['source'],
                    f'{name}: WAT source')
        rebuilt = directory / name
        subprocess.run([str(tool), 'parse', str(binary.with_suffix('.wat')),
                        '-o', str(rebuilt)], check=True, capture_output=True)
        require(rebuilt.read_bytes() == data, f'{name}: WAT does not reproduce binary')
        subprocess.run([str(tool), 'validate', str(binary)], check=True, capture_output=True)
        actual = json.loads(run(tool, binary, [], '--json'))
        require(len(actual['worlds']) == 1, f'{name}: expected one actual world')
        target = expected['world']
        original = None
        for world in fixed['worlds']:
            package, version = fixed['packages'][world['package']]['name'].split('@')
            if f'{package}/{world["name"]}@{version}' == target:
                original = world
                break
        require(original is not None, f'Unknown fixed world: {target}')
        for direction in ('imports', 'exports'):
            require(world_surface(fixed, original, direction) ==
                    world_surface(actual, actual['worlds'][0], direction),
                    f'{name}: {direction} keys, signatures, types or resource owners differ')
        reports.append({'file': name, 'world': target,
                        'imports': len(actual['worlds'][0]['imports']),
                        'exports': len(actual['worlds'][0]['exports'])})
    return reports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', required=True, type=Path)
    parser.add_argument('--wasm-tools', type=Path,
                        default=REPO / '.toolchains/bin/wasm-tools')
    args = parser.parse_args()
    lock = json.loads((REPO / 'tool/wasi_preview2_contract.lock.json').read_text())
    sources = args.sources.resolve()
    if not (sources / 'proposals').is_dir() and (sources / 'raw/proposals').is_dir():
        sources = sources / 'raw'
    expected_paths = {item['path'] for item in lock['wasi']['source_files']}
    actual_paths = {str(path.relative_to(sources))
                    for path in sources.glob('proposals/*/wit/*.wit')}
    require(actual_paths == expected_paths, 'source WIT file inventory changed')
    for item in lock['wasi']['source_files']:
        data = (sources / item['path']).read_bytes()
        check_bytes(data, item, item['path'])
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        require(blob == item['git_blob'], f'{item["path"]}: Git blob changed')
    require(sum(item['bytes'] for item in lock['wasi']['source_files']) ==
            lock['wasi']['source_bytes'], 'locked source byte total changed')

    part = (REPO / 'lib/src/wasi/component/standard_wit_preview2.dart').read_bytes().decode()
    embedded = {'wasi:' + name.lower(): text.encode() for name, text in re.findall(
        r"const String _wasi([A-Za-z]+)0212PinnedSource\s*=\s*r'''([\s\S]*?)''';", part)}
    stable = lock['profiles']['stable-default']['packages']
    require(set(embedded) == set(stable), 'embedded package inventory changed')
    extension = lock['informational_extension']
    method = re.search(
        r"const String _wasiHttp0212InformationalMethod\s*=\s*r'''([\s\S]*?)''';", part)
    require(method is not None, 'missing informational method fragment')
    delta = method.group(1).encode()
    check_bytes(delta, extension, 'informational method')
    marker_match = re.search(r"const _wasiHttp0212InformationalMarker = ('[^']*');", part)
    require(marker_match is not None, 'missing informational insertion marker')
    marker = ast.literal_eval(marker_match.group(1))
    require(marker == extension['insert_after'], 'informational insertion marker changed')
    require(embedded['wasi:http'].count(marker.encode()) == 1,
            'informational insertion point must be unique')

    tool = args.wasm_tools.resolve()
    version = subprocess.check_output([str(tool), '--version'], text=True).strip()
    require(version.startswith(f'wasm-tools {lock["wasm_tools"]["version"]} ') and
            lock['wasm_tools']['revision'] in version, f'unexpected parser: {version}')
    graphs = {}
    summary = {}
    with tempfile.TemporaryDirectory(prefix='wasd-preview2-contract-') as directory:
        temporary = Path(directory)
        package = temporary / 'http'
        for item in lock['wasi']['source_files']:
            path = Path(item['path'])
            name = path.parts[1]
            target = (package if name == 'http' else package / 'deps' / name) / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(sources / path, target)
        for profile, expected in lock['profiles'].items():
            graph = json.loads(run(tool, package, expected['features'], '--json'))
            graphs[profile] = graph
            require(worlds(graph) == lock['worlds'], f'{profile}: world boundaries changed')
            function_count = sum(len(item['functions']) for item in graph['interfaces'])
            require(function_count == expected['declared_interface_functions'],
                    f'{profile}: function inventory changed')
            normalized = temporary / profile
            run(tool, package, expected['features'], '--no-docs', '--out-dir', str(normalized))
            for name, expected_bytes in expected['packages'].items():
                member = name.split(':')[1]
                path = normalized / ('http.wit' if member == 'http' else f'deps/{member}.wit')
                generated = path.read_bytes()
                check_bytes(generated, expected_bytes, f'{profile} {name}')
                source = embedded[name]
                if expected['features'] and member == 'http':
                    source = source.replace(marker.encode(), marker.encode() + delta, 1)
                require(source == generated, f'{profile} {name}: embedded WIT differs')
            summary[profile] = {
                'packages': len(expected['packages']), 'worlds': len(graph['worlds']),
                'declared_interface_functions': function_count,
                'normalized_bytes': sum(item['bytes'] for item in expected['packages'].values()),
            }
        fixture_reports = check_fixtures(tool, graphs['stable-default'],
                                        lock['fixtures'], temporary)

    before = graphs['stable-default']
    after = graphs[extension['feature']]
    for field in ('packages', 'worlds', 'types'):
        require(before[field] == after[field], f'feature changed {field}')
    require(len(before['interfaces']) == len(after['interfaces']), 'feature added an interface')
    changed = []
    for index, (left, right) in enumerate(zip(before['interfaces'], after['interfaces'])):
        require({k: v for k, v in left.items() if k != 'functions'} ==
                {k: v for k, v in right.items() if k != 'functions'},
                'feature changed interface metadata')
        for name in left['functions'].keys() | right['functions'].keys():
            if left['functions'].get(name) != right['functions'].get(name):
                changed.append((qualified(before, index), name,
                                left['functions'].get(name), right['functions'].get(name)))
    require(len(changed) == 1 and changed[0][:2] ==
            (extension['interface'], extension['function']) and
            changed[0][2] is None and changed[0][3] is not None,
            'feature delta is not exactly the informational method')
    print(json.dumps({'verified_source_files': len(expected_paths),
                      'verified_source_bytes': lock['wasi']['source_bytes'],
                      'parser': version, 'profiles': summary,
                      'fixtures': fixture_reports}, indent=2))


if __name__ == '__main__':
    main()
