import { chunkSources } from './chunker.js';
import { buildIndex, DB_PATH } from './index-builder.js';

console.error('chunking sources…');
const chunks = await chunkSources();
console.error(`${chunks.length} chunks — embedding & storing…`);
const db = await buildIndex(chunks);
const { n } = db.prepare('SELECT count(*) as n FROM chunks').get() as { n: number };
console.log(`done — ${n} chunks stored in ${DB_PATH}`);
