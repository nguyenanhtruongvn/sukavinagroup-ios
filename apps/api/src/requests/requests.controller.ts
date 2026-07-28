import { Body, Controller, Delete, Get, Param, Patch, Post, Req, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { RequestsService } from './requests.service';

@UseGuards(JwtAuthGuard)
@Controller('me/requests')
export class RequestsController {
  constructor(private readonly requests: RequestsService) {}

  @Get()
  list(@Req() req: { user: { sub: string } }) {
    return this.requests.list(req.user.sub);
  }

  @Get('admin/all')
  adminList(
    @Req() req: { user: { sub: string; employeeCode?: string; accountType?: string; permissions?: string[] } },
  ) {
    return this.requests.adminList(req.user);
  }

  @Delete('admin/:id')
  adminDelete(
    @Req() req: { user: { sub: string; accountType?: string } },
    @Param('id') id: string,
  ) {
    return this.requests.adminDelete(req.user, id);
  }

  @Post()
  create(
    @Req() req: { user: { sub: string } },
    @Body() body: { kind?: string; startsAt?: string; endsAt?: string; reason?: string },
  ) {
    return this.requests.create(req.user.sub, body);
  }

  @Get('approvals')
  approvals(@Req() req: { user: { sub: string } }) {
    return this.requests.approvals(req.user.sub);
  }

  @Get('notifications')
  notifications(@Req() req: { user: { sub: string } }) {
    return this.requests.notifications(req.user.sub);
  }

  @Patch('notifications/read')
  readNotifications(@Req() req: { user: { sub: string } }) {
    return this.requests.readNotifications(req.user.sub);
  }

  @Patch('notifications/:notificationId/read')
  readNotification(
    @Req() req: { user: { sub: string } },
    @Param('notificationId') notificationId: string,
  ) {
    return this.requests.readNotification(req.user.sub, notificationId);
  }

  @Delete('notifications')
  clearNotifications(@Req() req: { user: { sub: string } }) {
    return this.requests.clearNotifications(req.user.sub);
  }

  @Delete('notifications/:notificationId')
  deleteNotification(
    @Req() req: { user: { sub: string } },
    @Param('notificationId') notificationId: string,
  ) {
    return this.requests.deleteNotification(req.user.sub, notificationId);
  }

  @Patch(':id/decision')
  decide(
    @Req() req: { user: { sub: string } },
    @Param('id') id: string,
    @Body() body: { status?: string; note?: string },
  ) {
    return this.requests.decide(req.user.sub, id, body);
  }

  @Delete(':id')
  cancel(@Req() req: { user: { sub: string } }, @Param('id') id: string) {
    return this.requests.cancel(req.user.sub, id);
  }
}
