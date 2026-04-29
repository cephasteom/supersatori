import sources from './sources.json' with { type: 'json' };

export interface Chunk {
  label: string;
  content: string;
  url: string;
}

function blobToRaw(url: string): string {
  return url
    .replace('https://github.com/', 'https://raw.githubusercontent.com/')
    .replace('/blob/', '/');
}

function treeToApiUrl(url: string): string {
  const m = url.match(/https:\/\/github\.com\/([^/]+)\/([^/]+)\/tree\/([^/]+)\/(.+)/);
  if (!m) throw new Error(`Invalid tree URL: ${url}`);
  const [, owner, repo, ref, path] = m;
  return `https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${ref}`;
}

async function fetchText(url: string): Promise<string> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.text();
}

interface FileRef { url: string; category: string; filename: string }

async function resolveUrls(category: string, value: string | string[]): Promise<FileRef[]> {
  const urls = Array.isArray(value) ? value : [value];
  const out: FileRef[] = [];

  for (const url of urls) {
    if (url.includes('/tree/')) {
      const apiUrl = treeToApiUrl(url);
      const res = await fetch(apiUrl);
      const files = await res.json() as Array<{ name: string; download_url: string; type: string }>;
      for (const f of files) {
        if (f.type === 'file') out.push({ url: f.download_url, category, filename: f.name });
      }
    } else {
      const raw = url.includes('raw.githubusercontent.com') ? url : blobToRaw(url);
      out.push({ url: raw, category, filename: url.split('/').pop()! });
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// Chunking strategies
// ---------------------------------------------------------------------------

const MAX_CHARS = 2000;

function splitBySize(text: string, max = MAX_CHARS): string[] {
  if (text.length <= max) return [text];
  const chunks: string[] = [];
  const lines = text.split('\n');
  let current = '';
  for (const line of lines) {
    if (current.length + line.length + 1 > max && current) {
      chunks.push(current.trim());
      current = line;
    } else {
      current += (current ? '\n' : '') + line;
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

function chunkMarkdown(text: string): Array<{ title: string; text: string }> {
  const parts = text.split(/^(#{1,3} .+)$/m);
  const out: Array<{ title: string; text: string }> = [];
  let title = 'intro';
  let body = '';

  for (const part of parts) {
    if (/^#{1,3} /.test(part)) {
      if (body.trim()) splitBySize(body.trim()).forEach(t => out.push({ title, text: t }));
      title = part.replace(/^#+\s*/, '').trim();
      body = '';
    } else {
      body += part;
    }
  }
  if (body.trim()) splitBySize(body.trim()).forEach(t => out.push({ title, text: t }));
  return out;
}

function chunkTypeScript(text: string): Array<{ title: string; text: string }> {
  const re = /^(export\s+(default\s+)?(class|function|const|type|interface|enum)\s+(\w+))/gm;
  const positions: Array<{ index: number; name: string }> = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    const nm = m[0].match(/(?:class|function|const|type|interface|enum)\s+(\w+)/);
    positions.push({ index: m.index, name: nm ? nm[1] : `export_${positions.length + 1}` });
  }

  if (!positions.length) return splitBySize(text).map((t, i) => ({ title: `part_${i + 1}`, text: t }));

  const out: Array<{ title: string; text: string }> = [];
  if (positions[0].index > 0) {
    const pre = text.slice(0, positions[0].index).trim();
    if (pre) splitBySize(pre).forEach(t => out.push({ title: 'imports', text: t }));
  }
  for (let i = 0; i < positions.length; i++) {
    const slice = text.slice(positions[i].index, positions[i + 1]?.index ?? text.length).trim();
    splitBySize(slice).forEach(t => out.push({ title: positions[i].name, text: t }));
  }
  return out;
}

function chunkJson(text: string): Array<{ title: string; text: string }> {
  try {
    const obj = JSON.parse(text) as Record<string, unknown>;
    if (typeof obj !== 'object' || Array.isArray(obj)) throw new Error();
    return Object.entries(obj).flatMap(([key, val]) =>
      splitBySize(JSON.stringify({ [key]: val }, null, 2)).map(t => ({ title: key, text: t }))
    );
  } catch {
    return splitBySize(text).map((t, i) => ({ title: `chunk_${i + 1}`, text: t }));
  }
}

function chunkScd(text: string): Array<{ title: string; text: string }> {
  const re = /SynthDef\s*\(\s*\\(\w+)/g;
  const positions: Array<{ index: number; name: string }> = [];
  let m;
  while ((m = re.exec(text)) !== null) positions.push({ index: m.index, name: m[1] });

  if (!positions.length) return splitBySize(text).map((t, i) => ({ title: `part_${i + 1}`, text: t }));

  const out: Array<{ title: string; text: string }> = [];
  if (positions[0].index > 0) {
    const pre = text.slice(0, positions[0].index).trim();
    if (pre) splitBySize(pre).forEach(t => out.push({ title: 'setup', text: t }));
  }
  for (let i = 0; i < positions.length; i++) {
    const slice = text.slice(positions[i].index, positions[i + 1]?.index ?? text.length).trim();
    splitBySize(slice).forEach(t => out.push({ title: positions[i].name, text: t }));
  }
  return out;
}

function chunkByExtension(text: string, filename: string): Array<{ title: string; text: string }> {
  const ext = filename.split('.').pop()?.toLowerCase();
  if (ext === 'md') return chunkMarkdown(text);
  if (ext === 'ts') return chunkTypeScript(text);
  if (ext === 'json') return chunkJson(text);
  if (ext === 'scd') return chunkScd(text);
  return splitBySize(text).map((t, i) => ({ title: `part_${i + 1}`, text: t }));
}

// ---------------------------------------------------------------------------
// Main export
// ---------------------------------------------------------------------------

export async function chunkSources(): Promise<Chunk[]> {
  const chunks: Chunk[] = [];

  for (const [category, value] of Object.entries(sources)) {
    const files = await resolveUrls(category, value as string | string[]);

    for (const { url, category: cat, filename } of files) {
      process.stderr.write(`fetching ${cat}/${filename}\n`);
      let text: string;
      try {
        text = await fetchText(url);
      } catch (e) {
        process.stderr.write(`  skip: ${e}\n`);
        continue;
      }

      for (const section of chunkByExtension(text, filename)) {
        chunks.push({ label: `${cat}/${filename}#${section.title}`, content: section.text, url });
      }
    }
  }

  return chunks;
}
