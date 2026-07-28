import {
  Controller,
  Body,
  Get,
  Patch,
  Post,
  Req,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { AuthUser } from '../auth/permissions';
import { WeeklyMenuData, WeeklyMenuService } from './weekly-menu.service';

@UseGuards(JwtAuthGuard)
@Controller('admin/menu')
export class WeeklyMenuController {
  constructor(private readonly weeklyMenu: WeeklyMenuService) {}

  @Get()
  current(@Req() req: { user: AuthUser }) {
    return this.weeklyMenu.current(req.user);
  }

  @Post('import')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 5 * 1024 * 1024 } }))
  import(
    @Req() req: { user: AuthUser },
    @UploadedFile() file?: Express.Multer.File,
  ) {
    return this.weeklyMenu.import(req.user, file);
  }

  @Patch()
  update(
    @Req() req: { user: AuthUser },
    @Body() body: WeeklyMenuData,
  ) {
    return this.weeklyMenu.update(req.user, body);
  }
}
