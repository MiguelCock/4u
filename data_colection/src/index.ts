import { Elysia } from 'elysia';
import { photoRoutes } from './photo';
import { openapi } from '@elysia/openapi'

const app = new Elysia()
  .use(photoRoutes)
  .use(openapi())
  .listen(3000);

console.log(`🦊 Elysia corriendo en http://0.0.0.0:3000`);
