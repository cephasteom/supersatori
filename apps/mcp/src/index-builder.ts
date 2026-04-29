import Database from 'better-sqlite3';
import * as sqliteVec from 'sqlite-vec';
import OpenAI from 'openai';
import path from 'path';
import { fileURLToPath } from 'url';
import type { Chunk } from './chunker.ts';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const DB_PATH = path.join(__dirname, '../satori.db');

const EMBED_MODEL = 'text-embedding-3-small';
const EMBED_DIM = 1536;
const BATCH_SIZE = 64;

const openai = new OpenAI();

function openDb(): Database.Database {
  const db = new Database(DB_PATH);
  sqliteVec.load(db);
  db.pragma('journal_mode = WAL');
  return db;
}

function initSchema(db: Database.Database): void {
  db.exec(`
    DROP TABLE IF EXISTS chunk_vecs;
    DROP TABLE IF EXISTS chunks;

    CREATE TABLE chunks (
      id      INTEGER PRIMARY KEY AUTOINCREMENT,
      label   TEXT NOT NULL,
      url     TEXT NOT NULL,
      content TEXT NOT NULL
    );

    CREATE VIRTUAL TABLE chunk_vecs USING vec0(
      embedding FLOAT[${EMBED_DIM}]
    );
  `);
}

async function embedBatch(texts: string[]): Promise<Float32Array[]> {
  const res = await openai.embeddings.create({ model: EMBED_MODEL, input: texts });
  return res.data.map(d => new Float32Array(d.embedding));
}

export async function buildIndex(chunks: Chunk[]): Promise<Database.Database> {
  const db = openDb();
  initSchema(db);

  const insertChunk = db.prepare(
    'INSERT INTO chunks (label, url, content) VALUES (?, ?, ?)'
  );
  const insertVec = db.prepare(
    'INSERT INTO chunk_vecs (embedding) VALUES (?)'
  );

  for (let i = 0; i < chunks.length; i += BATCH_SIZE) {
    const batch = chunks.slice(i, i + BATCH_SIZE);
    const end = Math.min(i + BATCH_SIZE, chunks.length);
    process.stderr.write(`embedding ${i + 1}–${end} / ${chunks.length}\n`);

    const embeddings = await embedBatch(batch.map(c => c.content));

    db.transaction(() => {
      for (let j = 0; j < batch.length; j++) {
        const { label, url, content } = batch[j];
        insertChunk.run(label, url, content);
        insertVec.run(embeddings[j]);
      }
    })();
  }

  return db;
}
