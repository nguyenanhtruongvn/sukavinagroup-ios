import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { PrismaService } from '../prisma/prisma.service';

@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(private readonly prisma: PrismaService) {
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      ignoreExpiration: false,
      secretOrKey: process.env.JWT_SECRET ?? 'dev-secret',
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
