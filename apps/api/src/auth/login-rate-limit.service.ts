import {
  HttpException,
  HttpStatus,
  Injectable,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { createHmac } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';

type LimitRule = {
  scope: string;
  key: string;
  identifierHash: string;
  maxAttempts: number;
  windowSeconds: number;
  blockSeconds: number;
};

@Injectable()
export class LoginRateLimitService implements OnModuleInit, OnModuleDestroy {
  private readonly secret =
    process.env.LOGIN_RATE_LIMIT_SECRET ??
    process.env.OTP_HMAC_SECRET ??
    process.env.JWT_SECRET ??
    'sukavina-login-rate-limit';

  constructor(private readonly prisma: PrismaService) {}

  private cleanupTimer?: NodeJS.Timeout;

  onModuleInit() {
    this.cleanupTimer = setInterval(() => void this.cleanup(), 60 * 60 * 1000);
    this.cleanupTimer.unref();
    void this.cleanup();
  }

  onModuleDestroy() {
    if (this.cleanupTimer) clearInterval(this.cleanupTimer);
  }

  async assertAllowed(loginId: string, clientIp: string) {
    const keys = this.rules(loginId, clientIp).map((rule) => rule.key);
    const blocked = await this.prisma.loginRateLimit.findFirst({
      where: {
        key: { in: keys },
        blockedUntil: { gt: new Date() },
      },
      orderBy: { blockedUntil: 'desc' },
    });
    if (!blocked?.blockedUntil) return;

    const retryAfter = Math.max(
      1,
      Math.ceil((blocked.blockedUntil.getTime() - Date.now()) / 1000),
    );
    throw new HttpException(
      {
        statusCode: HttpStatus.TOO_MANY_REQUESTS,
        message: 'Đăng nhập thất bại quá nhiều lần. Vui lòng thử lại sau.',
        retryAfter,
      },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }

  async recordFailure(loginId: string, clientIp: string) {
    await Promise.all(
      this.rules(loginId, clientIp).map((rule) => this.increment(rule)),
    );
  }

  async clear(loginId: string, clientIp: string) {
    await this.prisma.loginRateLimit.deleteMany({
      where: {
        key: { in: this.rules(loginId, clientIp).map((rule) => rule.key) },
      },
    });
  }

  private rules(loginId: string, clientIp: string): LimitRule[] {
    const accountHash = this.digest(loginId.trim().toLowerCase());
    const ipHash = this.digest(this.normalizeIp(clientIp));
    return [
      {
        scope: 'account',
        key: `account:${accountHash}`,
        identifierHash: accountHash,
        maxAttempts: 12,
        windowSeconds: 15 * 60,
        blockSeconds: 15 * 60,
      },
      {
        scope: 'account_ip',
        key: `account_ip:${accountHash}:${ipHash}`,
        identifierHash: `${accountHash}:${ipHash}`,
        maxAttempts: 6,
        windowSeconds: 5 * 60,
        blockSeconds: 10 * 60,
      },
    ];
  }

  private async increment(rule: LimitRule) {
    await this.prisma.$executeRaw`
      INSERT INTO "LoginRateLimit"
        ("key", "scope", "identifierHash", "count", "windowStartedAt", "blockedUntil", "updatedAt")
      VALUES
        (${rule.key}, ${rule.scope}, ${rule.identifierHash}, 1, NOW(), NULL, NOW())
      ON CONFLICT ("key") DO UPDATE SET
        "count" = CASE
          WHEN "LoginRateLimit"."windowStartedAt" < NOW() - (${rule.windowSeconds} * INTERVAL '1 second')
            THEN 1
          ELSE "LoginRateLimit"."count" + 1
        END,
        "windowStartedAt" = CASE
          WHEN "LoginRateLimit"."windowStartedAt" < NOW() - (${rule.windowSeconds} * INTERVAL '1 second')
            THEN NOW()
          ELSE "LoginRateLimit"."windowStartedAt"
        END,
        "blockedUntil" = CASE
          WHEN (
            CASE
              WHEN "LoginRateLimit"."windowStartedAt" < NOW() - (${rule.windowSeconds} * INTERVAL '1 second')
                THEN 1
              ELSE "LoginRateLimit"."count" + 1
            END
          ) >= ${rule.maxAttempts}
            THEN NOW() + (${rule.blockSeconds} * INTERVAL '1 second')
          ELSE "LoginRateLimit"."blockedUntil"
        END,
        "updatedAt" = NOW()
    `;
  }

  private digest(value: string) {
    return createHmac('sha256', this.secret)
      .update(value)
      .digest('hex')
      .slice(0, 32);
  }

  private normalizeIp(value: string) {
    const ip = value.trim().replace(/^::ffff:/, '');
    if (ip.includes(':')) return ip.split(':').slice(0, 4).join(':');
    const parts = ip.split('.');
    return parts.length === 4 ? `${parts[0]}.${parts[1]}.${parts[2]}.0/24` : ip;
  }

  private async cleanup() {
    await this.prisma.loginRateLimit.deleteMany({
      where: {
        updatedAt: { lt: new Date(Date.now() - 24 * 60 * 60 * 1000) },
      },
    });
  }
}
