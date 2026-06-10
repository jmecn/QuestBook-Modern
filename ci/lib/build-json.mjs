import { createHash } from 'node:crypto';

export const VERSION_KEYS = [
  'modpack',
  'ftb-quest-export',
  'questbook-react',
  'headlessmc',
  'quest-book-modern',
];

export const EXPORT_VERSION_KEYS = [
  'modpack',
  'ftb-quest-export',
];

export function versionsFromArgv(argv, startIndex = 0) {
  /** @type {Record<string, string>} */
  const versions = {};
  for (let i = 0; i < VERSION_KEYS.length; i += 1) {
    versions[VERSION_KEYS[i]] = argv[startIndex + i] ?? '';
  }
  return versions;
}

export function contentHash(versions, hashLen = 7) {
  const fingerprint = {};
  for (const key of VERSION_KEYS) {
    fingerprint[key] = versions[key];
  }
  const canonical = JSON.stringify(fingerprint);
  const len = Math.max(4, Number.parseInt(String(hashLen), 10) || 7);
  return createHash('sha256').update(canonical).digest('hex').slice(0, len);
}

export function enrichBuildJson(versions, bundleId, hashLen = 7) {
  const digest = contentHash(versions, hashLen);
  return {
    ...versions,
    contentHash: digest,
    releaseTag: `site-${bundleId}-${digest}`,
  };
}
