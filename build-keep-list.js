#!/usr/bin/env node
import { writeFile } from 'node:fs/promises';
import { normalizePublication } from './lib/normalize.js';

const DEFAULTS = {
  endpoint: 'https://agency.icjia-api.cloud/graphql',
  pageSize: 500,
  hosts: 'archive.icjia-api.cloud,archive.icjia.cloud',
  urlPrefix: '/files/',
  maxPubs: 50000,
  out: null
};

function parseArgs(argv) {
  const opts = { ...DEFAULTS };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];
    switch (arg) {
      case '--endpoint': opts.endpoint = next; i++; break;
      case '--page-size': opts.pageSize = parseInt(next, 10); i++; break;
      case '--out': opts.out = next; i++; break;
      case '--hosts':
      case '--host': opts.hosts = next; i++; break;
      case '--url-prefix': opts.urlPrefix = next; i++; break;
      case '--max-pubs': opts.maxPubs = parseInt(next, 10); i++; break;
      case '-h':
      case '--help': printHelp(); process.exit(0);
      default:
        console.error(`Unknown argument: ${arg}`);
        printHelp();
        process.exit(2);
    }
  }
  if (!Number.isFinite(opts.pageSize) || opts.pageSize <= 0) {
    throw new Error(`Invalid --page-size: ${opts.pageSize}`);
  }
  opts.hostList = opts.hosts.split(',').map((h) => h.trim()).filter(Boolean);
  if (opts.hostList.length === 0) {
    throw new Error('--hosts must contain at least one host');
  }
  if (!opts.out) {
    const stamp = new Date().toISOString().replace(/:/g, '-');
    opts.out = `./keep-${stamp}.json`;
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: node build-keep-list.js [options]

Queries the ICJIA publications GraphQL endpoint with pagination and emits a
JSON keep-list for the archive quarantine tool. See docs/archive-quarantine-design.md.

Options:
  --endpoint URL    GraphQL endpoint (default: ${DEFAULTS.endpoint})
  --page-size N     Records per request (default: ${DEFAULTS.pageSize})
  --out PATH        Output path (default: ./keep-{ISO}.json)
  --hosts LIST      Comma-separated list of archive hosts (default: ${DEFAULTS.hosts})
                    Also accepts --host as an alias.
  --url-prefix S    URL path prefix to strip (default: ${DEFAULTS.urlPrefix})
  --max-pubs N      Safety cap on total publications (default: ${DEFAULTS.maxPubs})
  -h, --help        Show this help`);
}

// This endpoint (Strapi v3) uses snake_case timestamps (created_at, updated_at, published_at)
// alongside the camelCase fileURL. Confirmed via live error on first run.
const QUERY_FIELDS = `id
    title
    slug
    fileURL
    created_at
    updated_at
    published_at`;

async function fetchPage(endpoint, start, pageSize) {
  const query = `{\n  publications(limit: ${pageSize}, start: ${start}, sort: "id:asc") {\n    ${QUERY_FIELDS}\n  }\n}`;
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
    body: JSON.stringify({ query })
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '<no body>');
    throw new Error(`HTTP ${res.status} ${res.statusText}: ${body.slice(0, 500)}`);
  }
  const json = await res.json();
  if (json.errors) {
    throw new Error(`GraphQL errors: ${JSON.stringify(json.errors)}`);
  }
  const pubs = json?.data?.publications;
  if (!Array.isArray(pubs)) {
    throw new Error(`Unexpected response shape: ${JSON.stringify(json).slice(0, 300)}`);
  }
  return pubs;
}

async function fetchAll(opts) {
  const pubs = [];
  let pagesFetched = 0;
  let start = 0;
  while (true) {
    process.stderr.write(`  fetching page ${pagesFetched + 1} (start=${start})… `);
    const page = await fetchPage(opts.endpoint, start, opts.pageSize);
    pagesFetched++;
    process.stderr.write(`${page.length} record(s)\n`);
    pubs.push(...page);
    if (page.length < opts.pageSize) break;
    if (pubs.length > opts.maxPubs) {
      throw new Error(
        `Pagination exceeded --max-pubs (${opts.maxPubs}) after ${pagesFetched} pages. ` +
        `Raise the cap or verify the endpoint is paginating correctly.`
      );
    }
    start += opts.pageSize;
  }
  return { pubs, pagesFetched };
}

function classify(pubs, opts) {
  const keep = [];
  const skipped = {
    null_fileurl: 0,
    unparseable: 0,
    non_archive_host: 0,
    unexpected_prefix: 0
  };
  for (const pub of pubs) {
    const r = normalizePublication(pub, {
      archiveHosts: opts.hostList,
      urlPrefix: opts.urlPrefix
    });
    if (r.ok) {
      keep.push({
        id: pub.id ?? null,
        title: pub.title ?? null,
        slug: pub.slug ?? null,
        fileURL: pub.fileURL,
        path: r.path,
        created_at: pub.created_at ?? null,
        updated_at: pub.updated_at ?? null,
        published_at: pub.published_at ?? null
      });
    } else {
      skipped[r.reason]++;
    }
  }
  return { keep, skipped };
}

function buildOutput(opts, pubs, pagesFetched, keep, skipped) {
  return {
    generated_at: new Date().toISOString(),
    source: opts.endpoint,
    archive_hosts: opts.hostList,
    url_prefix_stripped: opts.urlPrefix,
    query_template: `{ publications(limit: N, start: N, sort: "id:asc") { ${QUERY_FIELDS.replace(/\s+/g, ' ').trim()} } }`,
    pagination: {
      syntax: 'strapi-v3-limit-start-sort',
      page_size: opts.pageSize
    },
    stats: {
      total_publications: pubs.length,
      kept: keep.length,
      skipped,
      pages_fetched: pagesFetched
    },
    keep
  };
}

function printSummary(output) {
  const s = output.stats;
  console.log(`
Total fetched:          ${s.total_publications}
Pages fetched:          ${s.pages_fetched}
Kept (archive-hosted):  ${s.kept}
Skipped (null URL):     ${s.skipped.null_fileurl}
Skipped (unparseable):  ${s.skipped.unparseable}
Skipped (non-archive):  ${s.skipped.non_archive_host}
Skipped (bad prefix):   ${s.skipped.unexpected_prefix}`.trim());

  if (output.keep.length > 0) {
    console.log('\nFirst 3 keep entries:');
    for (const k of output.keep.slice(0, 3)) {
      console.log(`  • ${k.path}`);
    }
  }
}

async function main() {
  const opts = parseArgs(process.argv);
  console.error('Config:', JSON.stringify(opts, null, 2));
  console.error('Fetching publications…');

  const { pubs, pagesFetched } = await fetchAll(opts);
  console.error(`Fetched ${pubs.length} total publication(s).`);

  const { keep, skipped } = classify(pubs, opts);
  const output = buildOutput(opts, pubs, pagesFetched, keep, skipped);

  await writeFile(opts.out, JSON.stringify(output, null, 2));
  console.error(`Wrote ${opts.out}`);

  printSummary(output);

  if (keep.length === 0) {
    console.error(
      '\n⚠️  WARNING: 0 records kept. This is almost certainly an upstream bug ' +
      '(wrong endpoint, wrong host filter, or schema change). Inspect before ' +
      'passing this file to Tools 2/3.'
    );
  }
}

main().catch((err) => {
  console.error('FATAL:', err?.message ?? err);
  process.exit(1);
});
