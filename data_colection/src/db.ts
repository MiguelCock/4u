import { Database } from 'bun:sqlite';

const db = new Database('../photos.db');

db.run(`
  CREATE TABLE IF NOT EXISTS photos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    size INTEGER NOT NULL,
    longitude FLOAT,
    latitude FLOAT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )
`);

export { db };
