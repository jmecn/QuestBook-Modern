#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const buildJsonPath = process.argv[2];
if (!buildJsonPath) {
  console.error('usage: read-release-tag.mjs <build.json>');
  process.exit(1);
}

const build = JSON.parse(readFileSync(buildJsonPath, 'utf8'));
if (!build.releaseTag) {
  console.error('::error::build.json missing releaseTag — run record-build-versions first');
  process.exit(1);
}

process.stdout.write(String(build.releaseTag));
