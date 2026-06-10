#!/usr/bin/env node
import { readFileSync, existsSync, appendFileSync } from 'node:fs';

import {
  enrichBuildJson,
  EXPORT_VERSION_KEYS,
  VERSION_KEYS,
  versionsFromArgv,
} from '../lib/build-json.mjs';

const args = process.argv.slice(2);
if (args.length < 8) {
  console.error(
    'usage: check-build-changes.mjs <recordedPath> <bundleId> <hashLen> <versions...5>',
  );
  process.exit(1);
}

const [recordedPath, bundleId, hashLen, ...versionArgs] = args;
const forceExport = process.env.FORCE_EXPORT === 'true';
const current = versionsFromArgv(versionArgs);
const expected = enrichBuildJson(current, bundleId, hashLen);

/** @type {Record<string, unknown>} */
let recorded = {};
if (existsSync(recordedPath)) {
  try {
    recorded = JSON.parse(readFileSync(recordedPath, 'utf8'));
  } catch {
    recorded = {};
  }
}

const differs = (key) => String(recorded[key] ?? '') !== String(current[key] ?? '');
const hasRecorded = Object.keys(recorded).length > 0;
let exportNeeded = !hasRecorded || EXPORT_VERSION_KEYS.some(differs);
if (forceExport) exportNeeded = true;

const releaseMetadataMissing = !recorded.contentHash || !recorded.releaseTag;
const releaseMetadataMismatch =
  String(recorded.contentHash ?? '') !== String(expected.contentHash) ||
  String(recorded.releaseTag ?? '') !== String(expected.releaseTag);
const releaseMetadataStale = releaseMetadataMissing || releaseMetadataMismatch;

const versionDeployNeeded = !hasRecorded || VERSION_KEYS.some(differs) || releaseMetadataStale;

const lines = [
  `export_needed=${exportNeeded}`,
  `version_deploy_needed=${versionDeployNeeded}`,
  `release_metadata_stale=${releaseMetadataStale}`,
  `expected_release_tag=${expected.releaseTag}`,
  `changed=${versionDeployNeeded || forceExport}`,
];
for (const key of VERSION_KEYS) {
  if (differs(key)) {
    lines.push(`changed_${key.replace(/[^a-z0-9]+/gi, '_')}=true`);
  }
}

const payload = `${lines.join('\n')}\n`;
const outPath = process.env.GITHUB_OUTPUT;
if (outPath) {
  appendFileSync(outPath, payload);
} else {
  process.stdout.write(payload);
}

if (versionDeployNeeded || forceExport) {
  console.error('::group::build.json diff (published site)');
  for (const key of VERSION_KEYS) {
    console.error(`${key}: recorded=${recorded[key] ?? '<none>'} current=${current[key]}`);
  }
  console.error(
    `releaseTag: recorded=${recorded.releaseTag ?? '<none>'} expected=${expected.releaseTag}`,
  );
  console.error(
    `contentHash: recorded=${recorded.contentHash ?? '<none>'} expected=${expected.contentHash}`,
  );
  console.error('::endgroup::');
} else {
  console.error(
    'Published build.json matches resolved versions and release metadata — version gate clear',
  );
}
