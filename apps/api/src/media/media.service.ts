import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

@Injectable()
export class MediaService {
  private readonly root = process.env.MEDIA_ROOT || '/app/media';

  private safeName(name: string) {
    const safe = basename(name);
    if (!safe || safe !== name) throw new BadRequestException('Invalid media name');
    return safe;
  }

  async list() {
    await mkdir(this.root, { recursive: true });
    const names = await readdir(this.root);
    const items = await Promise.all(names.map(async (name) => {
      const details = await stat(join(this.root, name));
      return {
        name,
        url: `/api/media/${encodeURIComponent(name)}`,
        type: name.endsWith('.webm') ? 'video' : 'image',
        size: details.size,
        createdAt: details.birthtime.toISOString(),
      };
    }));
    return items.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  async upload(file?: Express.Multer.File) {
    if (!file) throw new BadRequestException('A media file is required');
    await mkdir(this.root, { recursive: true });
    const id = `${Date.now()}-${randomUUID().slice(0, 8)}`;

    if (file.mimetype.startsWith('image/')) {
      const input = join(this.root, `${id}${extname(file.originalname) || '.upload'}`);
      const name = `${id}.webp`;
      await writeFile(input, file.buffer);
      try {
        await execFileAsync('ffmpeg', [
          '-y', '-i', input, '-frames:v', '1', '-c:v', 'libwebp', '-quality', '82',
          join(this.root, name),
        ]);
      } finally {
        await rm(input, { force: true });
      }
      return (await this.list()).find((item) => item.name === name);
    }

    if (file.mimetype.startsWith('video/')) {
      const input = join(this.root, `${id}${extname(file.originalname) || '.upload'}`);
      const name = `${id}.webm`;
      await writeFile(input, file.buffer);
      try {
        await execFileAsync('ffmpeg', [
          '-y', '-i', input, '-c:v', 'libvpx-vp9', '-crf', '34', '-b:v', '0',
          '-c:a', 'libopus', '-b:a', '96k', '-movflags', '+faststart', join(this.root, name),
        ]);
      } finally {
        await rm(input, { force: true });
      }
      return (await this.list()).find((item) => item.name === name);
    }

    throw new BadRequestException('Only images and videos are supported');
  }

  async read(name: string) {
    const safe = this.safeName(name);
    try {
      return await readFile(join(this.root, safe));
    } catch {
      throw new NotFoundException('Media not found');
    }
  }

  async remove(name: string) {
    const safe = this.safeName(name);
    await rm(join(this.root, safe), { force: true });
    return { success: true };
  }
}
