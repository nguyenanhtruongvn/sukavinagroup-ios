import { Controller, Get, MessageEvent, Query, Req, Sse, UseGuards } from '@nestjs/common';
import { Observable } from 'rxjs';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { ContentEventsService } from './content-events.service';
import { DashboardService } from './dashboard.service';
import { AttendanceSyncService } from './attendance-sync.service';

@Controller()
export class DashboardController {
  constructor(
    private readonly dashboardService: DashboardService,
    private readonly contentEvents: ContentEventsService,
    private readonly attendanceSync: AttendanceSyncService,
  ) {}

  @Get('public/news')
  getPublicNews() {
    return this.dashboardService.getPublicNews();
  }

  @Sse('public/news/events')
  newsEvents(): Observable<MessageEvent> {
    return this.contentEvents.stream();
  }

  @UseGuards(JwtAuthGuard)
  @Get('me/dashboard')
  getDashboard(@Req() req: { user: { sub: string; employeeCode: string } }) {
    return this.dashboardService.getDashboard(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Get('me/attendance')
  async getMonthlyAttendance(
    @Req() req: { user: { sub: string } },
    @Query('month') month?: string,
  ) {
    await this.attendanceSync.syncMonth(month);
    return this.dashboardService.getMonthlyAttendance(req.user.sub, month);
  }
}
