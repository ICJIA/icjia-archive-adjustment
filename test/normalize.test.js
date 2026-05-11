import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { normalizePublication } from '../lib/normalize.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const PREFIX = '/files/';
const opts = { archiveHosts: ['archive.icjia-api.cloud'], urlPrefix: PREFIX };

test('happy path: URL-encoded space decodes to literal space in path', () => {
  const pub = {
    title: 'Authority Endorses Proposed CHRI Act',
    slug: 'authority-endorses-proposed-chri-act',
    fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/compiler/Authority%20Endorses%20Proposed%20CHRI%20Act.pdf'
  };
  assert.deepEqual(normalizePublication(pub, opts), {
    ok: true,
    path: 'icjia/pdf/compiler/Authority Endorses Proposed CHRI Act.pdf'
  });
});

test('null fileURL returns reason null_fileurl', () => {
  assert.deepEqual(
    normalizePublication({ title: 't', slug: 's', fileURL: null }, opts),
    { ok: false, reason: 'null_fileurl' }
  );
});

test('empty string fileURL returns reason null_fileurl', () => {
  assert.deepEqual(
    normalizePublication({ title: 't', slug: 's', fileURL: '' }, opts),
    { ok: false, reason: 'null_fileurl' }
  );
});

test('malformed URL returns reason unparseable', () => {
  assert.deepEqual(
    normalizePublication({ title: 't', slug: 's', fileURL: 'not a url' }, opts),
    { ok: false, reason: 'unparseable' }
  );
});

test('non-archive host returns reason non_archive_host', () => {
  assert.deepEqual(
    normalizePublication(
      { title: 't', slug: 's', fileURL: 'https://researchhub.icjia.cloud/files/x.pdf' },
      opts
    ),
    { ok: false, reason: 'non_archive_host' }
  );
});

test('pathname not starting with urlPrefix returns reason unexpected_prefix', () => {
  assert.deepEqual(
    normalizePublication(
      { title: 't', slug: 's', fileURL: 'https://archive.icjia-api.cloud/uploads/x.pdf' },
      opts
    ),
    { ok: false, reason: 'unexpected_prefix' }
  );
});

test('empty pathname returns reason unexpected_prefix', () => {
  assert.deepEqual(
    normalizePublication(
      { title: 't', slug: 's', fileURL: 'https://archive.icjia-api.cloud/' },
      opts
    ),
    { ok: false, reason: 'unexpected_prefix' }
  );
});

test('literal spaces in URL pathname are preserved', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/ResearchReports/Murder in Illinois 1973 to 1982.pdf'
    },
    opts
  );
  assert.deepEqual(result, {
    ok: true,
    path: 'icjia/pdf/ResearchReports/Murder in Illinois 1973 to 1982.pdf'
  });
});

test('literal straight apostrophes are preserved', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: "https://archive.icjia-api.cloud/files/icjia/pdf/Bulletins/Illinois' Computerized Criminal History.pdf"
    },
    opts
  );
  assert.deepEqual(result, {
    ok: true,
    path: "icjia/pdf/Bulletins/Illinois' Computerized Criminal History.pdf"
  });
});

test('curly apostrophe (U+2019) round-trips through URL encoding', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/Bulletins/Illinois%E2%80%99%20CCH.pdf'
    },
    opts
  );
  assert.deepEqual(result, {
    ok: true,
    path: 'icjia/pdf/Bulletins/Illinois’ CCH.pdf'
  });
});

test('literal ampersands are preserved', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/TIUpdate/T&I 1987.pdf'
    },
    opts
  );
  assert.deepEqual(result, {
    ok: true,
    path: 'icjia/pdf/TIUpdate/T&I 1987.pdf'
  });
});

test('directory case is preserved (PascalCase)', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/ResearchReports/X.pdf'
    },
    opts
  );
  assert.equal(result.path, 'icjia/pdf/ResearchReports/X.pdf');
});

test('directory case is preserved (lowercase)', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf/compiler/X.pdf'
    },
    opts
  );
  assert.equal(result.path, 'icjia/pdf/compiler/X.pdf');
});

test('doubled slash in URL pathname is collapsed to single slash', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/icjia/pdf//AtAGlance/vol1_no3_Class4felonyoffenders.pdf'
    },
    opts
  );
  assert.deepEqual(result, {
    ok: true,
    path: 'icjia/pdf/AtAGlance/vol1_no3_Class4felonyoffenders.pdf'
  });
});

test('triple slash in URL pathname is collapsed to single slash', () => {
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia-api.cloud/files/a///b.pdf'
    },
    opts
  );
  assert.equal(result.path, 'a/b.pdf');
});

test('host matching: second allowed host (archive.icjia.cloud) returns ok', () => {
  const optsMulti = {
    archiveHosts: ['archive.icjia-api.cloud', 'archive.icjia.cloud'],
    urlPrefix: '/files/'
  };
  const result = normalizePublication(
    {
      title: 't',
      slug: 's',
      fileURL: 'https://archive.icjia.cloud/files/icjia/pdf/mvtpc/SLATE03.pdf'
    },
    optsMulti
  );
  assert.deepEqual(result, { ok: true, path: 'icjia/pdf/mvtpc/SLATE03.pdf' });
});

test('host matching: host not in the allowed list returns non_archive_host', () => {
  const optsMulti = {
    archiveHosts: ['archive.icjia-api.cloud', 'archive.icjia.cloud'],
    urlPrefix: '/files/'
  };
  const result = normalizePublication(
    { title: 't', slug: 's', fileURL: 'https://researchhub.icjia-api.cloud/files/x.pdf' },
    optsMulti
  );
  assert.deepEqual(result, { ok: false, reason: 'non_archive_host' });
});

test('fixture smoke test: all 25 sample records normalize cleanly', async () => {
  const fixturePath = join(HERE, 'fixtures', 'sample-graphql.json');
  const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
  const pubs = fixture.data.publications;

  assert.equal(pubs.length, 25, 'fixture has 25 records');

  const results = pubs.map((p) => normalizePublication(p, opts));
  const ok = results.filter((r) => r.ok);
  const notOk = results.filter((r) => !r.ok);

  assert.equal(ok.length, 25, 'all 25 records should normalize successfully');
  assert.equal(notOk.length, 0, 'no records should be skipped');

  const paths = new Set(ok.map((r) => r.path));
  assert.ok(
    paths.has('icjia/pdf/compiler/Authority Endorses Proposed CHRI Act.pdf'),
    'URL-encoded spaces decoded'
  );
  assert.ok(
    paths.has('icjia/pdf/ResearchReports/Murder in Illinois 1973 to 1982.pdf'),
    'literal spaces preserved'
  );
  assert.ok(
    paths.has('icjia/pdf/TIUpdate/T&I 1987.pdf'),
    'literal ampersand preserved'
  );
  assert.ok(
    paths.has("icjia/pdf/Bulletins/Illinois' Computerized Criminal History.pdf"),
    'literal apostrophe preserved'
  );
});
