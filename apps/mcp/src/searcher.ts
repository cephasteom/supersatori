import Database from 'better-sqlite3';
import * as sqliteVec from 'sqlite-vec';
import OpenAI from 'openai';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DB_PATH = path.join(__dirname, '../satori.db');
const EMBED_MODEL = 'text-embedding-3-small';

const openai = new OpenAI();

let _db: Database.Database | null = null;

function getDb(): Database.Database {
  if (!_db) {
    _db = new Database(DB_PATH, { readonly: true });
    sqliteVec.load(_db);
  }
  return _db;
}

function toFloat32Buffer(vec: number[]): Buffer {
  const buf = Buffer.allocUnsafe(vec.length * 4);
  for (let i = 0; i < vec.length; i++) buf.writeFloatLE(vec[i], i * 4);
  return buf;
}

export interface SearchResult {
  label: string;
  url: string;
  content: string;
  distance: number;
}

export async function search(query: string, topK = 5): Promise<SearchResult[]> {
  const db = getDb();

  const res = await openai.embeddings.create({ model: EMBED_MODEL, input: query });
  const vec = toFloat32Buffer(res.data[0].embedding);

  const rows = db.prepare(`
    SELECT c.label, c.url, c.content, v.distance
    FROM chunk_vecs v
    JOIN chunks c ON c.id = v.rowid
    WHERE v.embedding MATCH ?
      AND k = ?
    ORDER BY v.distance
  `).all(vec, topK) as SearchResult[];

  return rows;
}
