export function normalizePublication(pub, { archiveHosts, urlPrefix }) {
  if (!pub.fileURL) {
    return { ok: false, reason: 'null_fileurl' };
  }
  let url;
  try {
    url = new URL(pub.fileURL);
  } catch {
    return { ok: false, reason: 'unparseable' };
  }
  if (!archiveHosts.includes(url.host)) {
    return { ok: false, reason: 'non_archive_host' };
  }
  const decoded = decodeURIComponent(url.pathname);
  if (!decoded.startsWith(urlPrefix)) {
    return { ok: false, reason: 'unexpected_prefix' };
  }
  return { ok: true, path: decoded.slice(urlPrefix.length) };
}
