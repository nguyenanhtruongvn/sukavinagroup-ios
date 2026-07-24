import { Body, Controller, Get, MessageEvent, Post, Query, Req, Sse, UseGuards } from '@nestjs/common';
import { Observable } from 'rxjs';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { ContentEventsService } from './content-events.service';
import { DashboardService } from './dashboard.service';
import { AttendanceSyncService } from './attendance-sync.service';
import { AuthService } from '../auth/auth.service';

@Controller()
export class DashboardController {
  constructor(
    private readonly dashboardService: DashboardService,
    private readonly contentEvents: ContentEventsService,
    private readonly attendanceSync: AttendanceSyncService,
    private readonly authService: AuthService,
  ) {}

  @Get('public/news')
  getPublicNews() {
    return this.dashboardService.getPublicNews();
  }

  @Sse('public/news/events')
  newsEvents(): Observable<MessageEvent> {
    return this.contentEvents.stream();
  }

  @Post('public/widget/attendance')
  async getWidgetAttendance(@Body() body: { widgetToken: string }) {
    const userId = await this.authService.verifyWidgetToken(body.widgetToken);
    return this.dashboardService.getWidgetAttendance(userId);
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
    // Serve persisted punches immediately; refresh WiseEye in the background.
    void this.attendanceSync.syncMonth(month).catch((error) => {
      console.error(`Background attendance sync failed: ${error instanceof Error ? error.message : String(error)}`);
    });
    return this.dashboardService.getMonthlyAttendance(req.user.sub, month);
  }
}
