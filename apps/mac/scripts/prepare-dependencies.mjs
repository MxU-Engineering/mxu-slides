#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Share the checked-in SwiftPM pins with the generated Xcode project. The
// ProImport manifest includes SwiftProtobuf only when its generated sources exist.
const macDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const packages = [
  { name: 'LocalAPI', required: ['flyingfox'] },
  { name: 'StreamEngine', required: ['haishinkit.swift', 'logboard'] },
];
if (existsSync(resolve(macDir, 'Packages/ProImport/Sources/ProImport/Generated'))) {
  packages.push({ name: 'ProImport', required: ['swift-protobuf'] });
}

const pins = new Map();
for (const { name, required } of packages) {
  const lock = JSON.parse(readFileSync(resolve(macDir, 'Packages', name, 'Package.resolved'), 'utf8'));
  if (![2, 3].includes(lock.version) || !Array.isArray(lock.pins) || lock.pins.length === 0) {
    throw new Error(`Missing or unsupported dependency pins for ${name}`);
  }
  for (const identity of required) {
    if (!lock.pins.some(pin => pin.identity === identity)) {
      throw new Error(`Missing ${identity} dependency pin in ${name}`);
    }
  }
  for (const pin of lock.pins) {
    if (!pin.identity || !pin.location || !/^[a-f0-9]{40}$/.test(pin.state?.revision ?? '')) {
      throw new Error(`Invalid dependency pin in ${name}`);
    }
    const previous = pins.get(pin.identity);
    if (previous && (previous.location !== pin.location ||
        JSON.stringify(previous.state) !== JSON.stringify(pin.state))) {
      throw new Error(`Conflicting dependency pins for ${pin.identity}`);
    }
    pins.set(pin.identity, pin);
  }
}

const destination = resolve(macDir, 'MxUSlides.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');
const expected = {
  pins: [...pins.values()].sort((a, b) => a.identity.localeCompare(b.identity)),
  version: 2,
};
if (process.argv.includes('--check')) {
  const actual = JSON.parse(readFileSync(destination, 'utf8'));
  const key = pin => [pin.identity, pin.kind, pin.location, pin.state.revision, pin.state.version ?? null, pin.state.branch ?? null];
  const actualPins = (actual.pins ?? []).map(key).sort();
  const expectedPins = expected.pins.map(key).sort();
  if (JSON.stringify(actualPins) !== JSON.stringify(expectedPins)) {
    throw new Error('Xcode dependency pins differ from the checked-in package locks. Run xcodegen generate before building.');
  }
  console.log(`Verified Xcode dependency lock (${pins.size} pins).`);
} else {
  mkdirSync(dirname(destination), { recursive: true });
  // Version 2 is supported by Xcode and does not need a graph-specific originHash.
  writeFileSync(destination, JSON.stringify(expected, null, 2) + '\n');
  console.log(`Prepared Xcode dependency lock (${pins.size} pins).`);
}
