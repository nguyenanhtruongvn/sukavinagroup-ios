import {
  Body,
  Controller,
  Delete,
  Get,
  Post,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { AuthService } from './auth.service';
import { LoginDto } from './dto/login.dto';
import { JwtAuthGuard } from './jwt-auth.guard';
import type {
  AuthenticationResponseJSON,
  RegistrationResponseJSON,
} from '@simplewebauthn/server';

@Controller('auth')
export class AuthController {
  constructor(private readonly authService: AuthService) {}

  private setSessionCookies(
    response: Response,
    session: { accessToken: string; refreshToken: string },
  ) {
    const common = {
      httpOnly: true,
      secure: true,
      sameSite: 'strict' as const,
      path: '/',
    };
    response.cookie('__Host-sukavina_access', session.accessToken, {
      ...common,
      maxAge: 24 * 60 * 60 * 1000,
    });
    response.cookie('__Host-sukavina_refresh', session.refreshToken, {
      ...common,
      maxAge: 180 * 24 * 60 * 60 * 1000,
    });
  }

  private clearSessionCookies(response: Response) {
    const options = { httpOnly: true, secure: true, sameSite: 'strict' as const, path: '/' };
    response.clearCookie('__Host-sukavina_access', options);
    response.clearCookie('__Host-sukavina_refresh', options);
  }

  @Post('login')
  async login(
    @Body() body: LoginDto,
    @Req()
    req: {
      ip?: string;
      headers: Record<string, string | string[] | undefined>;
    },
    @Res({ passthrough: true }) response: Response,
  ) {
    const forwarded = req.headers['x-forwarded-for'];
    const forwardedValue = Array.isArray(forwarded) ? forwarded[0] : forwarded;
    const clientIp =
      forwardedValue?.split(',')[0]?.trim() || req.ip || 'unknown';
    const session = await this.authService.login(body.loginId, body.password, clientIp);
    this.setSessionCookies(response, session);
    return session;
  }

  @Post('refresh')
  async refresh(
    @Body() body: { refreshToken?: string },
    @Req() req: { headers: { cookie?: string } },
    @Res({ passthrough: true }) response: Response,
  ) {
    const cookieToken = (req.headers.cookie ?? '')
      .split(';')
      .map((entry) => entry.trim())
      .find((entry) => entry.startsWith('__Host-sukavina_refresh='))
      ?.split('=').slice(1).join('=');
    const session = await this.authService.refreshSession(
      body.refreshToken || (cookieToken ? decodeURIComponent(cookieToken) : ''),
    );
    this.setSessionCookies(response, session);
    return session;
  }

  @Post('logout')
  logout(@Res({ passthrough: true }) response: Response) {
    this.clearSessionCookies(response);
    return { message: 'Đã đăng xuất an toàn.' };
  }

  @UseGuards(JwtAuthGuard)
  @Get('me')
  me(@Req() req: { user: { sub: string } }) {
    return this.authService.profile(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Post('session/upgrade')
  upgradeSession(@Req() req: { user: { sub: string } }) {
    return this.authService.upgradeSession(req.user.sub);
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
    return this.authService.confirmPasswordChange(
      req.user.sub,
      body.code,
      body.newPassword,
    );
  }

  @UseGuards(JwtAuthGuard)
  @Post('passkeys/register/options')
  passkeyRegistrationOptions(@Req() req: { user: { sub: string } }) {
    return this.authService.passkeyRegistrationOptions(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Post('passkeys/register/verify')
  verifyPasskeyRegistration(
    @Req() req: { user: { sub: string } },
    @Body()
    body: { challengeToken: string; response: RegistrationResponseJSON },
  ) {
    return this.authService.verifyPasskeyRegistration(
      req.user.sub,
      body.challengeToken,
      body.response,
    );
  }

  @Post('passkeys/login/options')
  passkeyAuthenticationOptions() {
    return this.authService.passkeyAuthenticationOptions();
  }

  @Post('passkeys/login/verify')
  async verifyPasskeyAuthentication(
    @Body()
    body: {
      challengeToken: string;
      response: AuthenticationResponseJSON;
    },
    @Res({ passthrough: true }) httpResponse: Response,
  ) {
    const session = await this.authService.verifyPasskeyAuthentication(
      body.challengeToken,
      body.response,
    );
    this.setSessionCookies(httpResponse, session);
    return session;
  }

  @UseGuards(JwtAuthGuard)
  @Delete('passkeys')
  removePasskeys(@Req() req: { user: { sub: string } }) {
    return this.authService.removePasskeys(req.user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Delete('me')
  deleteMyAccount(
    @Req() req: { user: { sub: string } },
    @Body() body: { confirmation: string },
  ) {
    return this.authService.deleteMyAccount(
      req.user.sub,
      '',
      body.confirmation,
    );
  }
}
