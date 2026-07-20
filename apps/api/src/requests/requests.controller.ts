import { Body, Controller, Delete, Get, Param, Post, Req, UseGuards } from '@nestjs/common';
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

  @Post()
  create(
    @Req() req: { user: { sub: string } },
    @Body() body: { kind?: string; startsAt?: string; endsAt?: string; reason?: string },
  ) {
    return this.requests.create(req.user.sub, body);
  }

  @Delete(':id')
  cancel(@Req() req: { user: { sub: string } }, @Param('id') id: string) {
    return this.requests.cancel(req.user.sub, id);
  }
}
