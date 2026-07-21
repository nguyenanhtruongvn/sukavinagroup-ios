import { Body, Controller, Delete, Get, Post, Req, UseGuards } from '@nestjs/common';
import { AuthService } from './auth.service';
import { LoginDto } from './dto/login.dto';
import { JwtAuthGuard } from './jwt-auth.guard';

@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  @Post('login')
  login(@Body() body: LoginDto) {
    return this.authService.login(body.loginId, body.password);
  }

  @UseGuards(JwtAuthGuard)
  @Get('me')
  me(@Req() req: { user: { sub: string } }) {
    return this.authService.profile(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Post('password-change/request')
  requestPasswordChange(@Req() req: { user: { sub: string } }) {
    return this.authService.requestPasswordChange(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Post('password-change/confirm')
  confirmPasswordChange(
    @Req() req: { user: { sub: string } },
    @Body() body: { code: string; newPassword: string },
  ) {
    return this.authService.confirmPasswordChange(req.user.sub, body.code, body.newPassword);
  }

  @UseGuards(JwtAuthGuard)
  @Delete('me')
  deleteMyAccount(
    @Req() req: { user: { sub: string } },
    @Body() body: { password: string; confirmation: string },
  ) {
    return this.authService.deleteMyAccount(req.user.sub, body.password, body.confirmation);
  }
}
