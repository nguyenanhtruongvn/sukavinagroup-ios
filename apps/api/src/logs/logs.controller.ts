import { Controller, Get, Req, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { LogsService } from './logs.service';

@UseGuards(JwtAuthGuard)
@Controller('admin/logs')
export class LogsController {
  constructor(private readonly logsService: LogsService) {}

  @Get()
  list(@Req() req: { user: { employeeCode?: string; role?: string } }) {
    return this.logsService.list(req.user);
  }
}
