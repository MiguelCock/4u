import { Elysia, t } from 'elysia';
import { writeFile, mkdir } from 'fs/promises';
import { join } from 'path';
import { existsSync } from 'fs';
import { db } from './db';
import { randomUUID } from 'crypto';

const uploadDir = join(process.cwd(), '../uploads');
if (!existsSync(uploadDir)) {
  await mkdir(uploadDir, { recursive: true });
}

export const photoRoutes = new Elysia()

  .post('/upload', async ({ body }) => {
    const { photo, latitude, longitude } = body;
    
    console.log("ENPOINT CALLED");

    const originalName = photo.name;
    const extension = originalName.split('.').pop() || 'bin';
    const filename = `${randomUUID()}.${extension}`;
    const filePath = join(uploadDir, filename);

    const buffer = await photo.arrayBuffer();
    await writeFile(filePath, new Uint8Array(buffer));

    const stmt = db.prepare(`
      INSERT INTO photos (filename, size, longitude, latitude)
      VALUES (?, ?, ?, ?)
    `);
    const info = stmt.run(
      filename,
      photo.size,
      longitude,
      latitude
    );

    return "OK";
  }, {
    body: t.Object({
      photo: t.File({ type: ["image/png", "image/jpeg", "image/jpg"] }),
      latitude: t.Numeric(),
      longitude: t.Numeric(),
   })
  })

  .get('/photos', async () => {
    const stmt = db.query(`
      SELECT id, filename, size, longitude, latitude, created_at
      FROM photos
      ORDER BY created_at DESC
    `);
    console.log("ENPOINT CALLED");

    const photos = stmt.all();
    // Agregamos la URL para cada foto
    return photos.map(photo => ({
      ...photo,
      url: `/uploads/${photo.filename}`
    }));
  })

  .get('/photos/:id', async ({ params: { id }, error }) => {
    const stmt = db.query(`
      SELECT id, filename, size, longitude, latitude, created_at
      FROM photos
      WHERE id = ?
    `);
    console.log("ENPOINT CALLED");

    const photo = stmt.get(Number(id));
    if (!photo) {
      return error(404, 'Foto no encontrada');
    }
    return {
      ...photo,
      url: `/uploads/${photo.filename}`
    };
  });
