import { Body, Controller, Delete, Get, Param, Patch, Post, Req, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { AdminContentService } from './admin-content.service';

@UseGuards(JwtAuthGuard)
@Controller('admin/content')
export class AdminContentController {
  constructor(private readonly adminContentService: AdminContentService) {}

  @Get()
  list(@Req() req: { user: { sub: string; employeeCode: string; role?: string } }) {
    return this.adminContentService.list(req.user);
  }

  @Post()
  create(
    @Req() req: { user: { sub: string; employeeCode: string; role?: string } },
    @Body()
    body: {
      page: string;
      key: string;
      title: string;
      body: string;
      sortOrder?: number;
      published?: boolean;
    },
  ) {
    return this.adminContentService.create(req.user, body);
  }

  @Patch(':id')
  update(
    @Req() req: { user: { sub: string; employeeCode: string; role?: string } },
    @Param('id') id: string,
    @Body()
    body: Partial<{
      page: string;
      key: string;
      title: string;
      body: string;
      sortOrder: number;
      published: boolean;
    }>,
  ) {
    return this.adminContentService.update(req.user, id, body);
  }

  @Delete(':id')
  remove(
    @Req() req: { user: { sub: string; employeeCode: string; role?: string } },
    @Param('id') id: string,
  ) {
    return this.adminContentService.remove(req.user, id);
  }
}
