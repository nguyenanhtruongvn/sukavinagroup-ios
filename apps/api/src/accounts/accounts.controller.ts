import { Body, Controller, Get, Header, Param, Patch, Req, Sse, UseGuards } from '@nestjs/common';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { RegistrationEventsService } from '../auth/registration-events.service';
import { AccountsService } from './accounts.service';

@UseGuards(JwtAuthGuard)
@Controller('admin/accounts')
export class AccountsController {
  constructor(
    private readonly accountsService: AccountsService,
    private readonly registrationEvents: RegistrationEventsService,
  ) {}

  @Get()
  list(@Req() req: { user: { sub: string; employeeCode?: string; accountType?: string; permissions?: string[] } }) {
    return this.accountsService.list(req.user);
  }

  @Sse('events')
  @Header('X-Accel-Buffering', 'no')
  events(@Req() req: { user: { sub: string; employeeCode?: string; accountType?: string; permissions?: string[] } }) {
    return this.registrationEvents.stream(req.user);
  }

  @Patch(':id')
  update(
    @Req() req: { user: { sub: string; employeeCode?: string; accountType?: string; permissions?: string[] } },
    @Param('id') id: string,
    @Body()
    body: {
      accountType: 'ADMIN' | 'EMPLOYEE';
      permissions?: string[];
      active?: boolean;
    },
  ) {
    return this.accountsService.update(req.user, id, body);
  }
}
