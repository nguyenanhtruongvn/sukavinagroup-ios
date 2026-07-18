import { Controller, Delete, Get, Header, Param, Post, Req, StreamableFile, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { assertPermission, AuthUser } from '../auth/permissions';
import { MediaService } from './media.service';

@Controller()
export class MediaController {
  constructor(private readonly media: MediaService) {}

  @Get('media/:name')
  @Header('Cache-Control', 'public, max-age=31536000, immutable')
  async serve(@Param('name') name: string) {
    const type = name.endsWith('.webm') ? 'video/webm' : 'image/webp';
    return new StreamableFile(await this.media.read(name), { type });
  }

  @Get('admin/media')
  @UseGuards(JwtAuthGuard)
  list(@Req() req: { user: AuthUser }) {
    assertPermission(req.user, 'content.manage');
    return this.media.list();
  }

  @Post('admin/media')
  @UseGuards(JwtAuthGuard)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 80 * 1024 * 1024 } }))
  upload(@Req() req: { user: AuthUser }, @UploadedFile() file?: Express.Multer.File) {
    assertPermission(req.user, 'content.manage');
    return this.media.upload(file);
  }

  @Delete('admin/media/:name')
  @UseGuards(JwtAuthGuard)
  remove(@Req() req: { user: AuthUser }, @Param('name') name: string) {
    assertPermission(req.user, 'content.manage');
    return this.media.remove(name);
  }
}
