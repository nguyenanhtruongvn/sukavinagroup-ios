import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import type { Request } from 'express';
import { PrismaService } from '../prisma/prisma.service';
import { getJwtSecret } from './jwt-secret';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(private readonly prisma: PrismaService) {
    super({
      jwtFromRequest: ExtractJwt.fromExtractors([
        (request: Request) => {
          const authorization = request.headers.authorization;
          if (authorization?.startsWith('Bearer ')) {
            const token = authorization.slice(7).trim();
            if (token && token !== '__cookie_session__') return token;
          }
          const cookieHeader = request.headers.cookie ?? '';
          const cookie = cookieHeader
            .split(';')
            .map((entry) => entry.trim())
            .find((entry) => entry.startsWith('__Host-sukavina_access='));
          return cookie ? decodeURIComponent(cookie.split('=').slice(1).join('=')) : null;
        },
      ]),
      ignoreExpiration: false,
      secretOrKey: getJwtSecret(),
    });
  }

  async validate(payload: {
    sub: string;
    employeeCode: string;
    role?: string;
    accountType?: string;
    permissions?: string[];
  }) {
    const user = await this.prisma.employee.findUnique({ where: { id: payload.sub } });
    if (!user || !user.active) throw new UnauthorizedException('Account disabled');
    return {
      ...payload,
      role: user.role,
      accountType: user.accountType,
      permissions: user.permissions,
      protected: user.protected,
    };
  }
}
