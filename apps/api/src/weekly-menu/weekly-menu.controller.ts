import {
  Controller,
  Delete,
  Body,
  Get,
  Patch,
  Post,
  Query,
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
  current(@Req() req: { user: AuthUser }, @Query('week') week?: string) {
    return this.weeklyMenu.current(req.user, week);
  }

  @Post('import')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 5 * 1024 * 1024 } }))
  import(
    @Req() req: { user: AuthUser },
    @UploadedFile() file?: Express.Multer.File,
    @Query('week') week?: string,
  ) {
    return this.weeklyMenu.import(req.user, file, week);
  }

  @Patch()
  update(
    @Req() req: { user: AuthUser },
    @Body() body: WeeklyMenuData,
    @Query('week') week?: string,
  ) {
    return this.weeklyMenu.update(req.user, body, week);
  }
}

@UseGuards(JwtAuthGuard)
@Controller('me/menu')
export class EmployeeWeeklyMenuController {
  constructor(private readonly weeklyMenu: WeeklyMenuService) {}

  @Get()
  today(@Req() req: { user: AuthUser }) {
    return this.weeklyMenu.today(req.user);
  }

  @Patch('selection')
  select(
    @Req() req: { user: AuthUser },
    @Body() body: { choice?: string },
  ) {
    return this.weeklyMenu.selectMeal(req.user, body.choice);
  }

  @Patch('selection/received')
  receiveSelection(@Req() req: { user: AuthUser }) {
    return this.weeklyMenu.receiveMealSelection(req.user);
  }

  @Delete('selection')
  cancelSelection(@Req() req: { user: AuthUser }) {
    return this.weeklyMenu.cancelMealSelection(req.user);
  }
}
