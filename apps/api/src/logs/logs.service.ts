import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { assertPermission, AuthUser } from '../auth/permissions';

@Injectable()
export class LogsService {
  constructor(private readonly prisma: PrismaService) {}

  list(user: AuthUser) {
    assertPermission(user, 'logs.view');
    return this.prisma.appLog.findMany({
      orderBy: { createdAt: 'desc' },
      take: 20,
    });
  }

  async write(level: string, source: string, message: string, meta = '') {
    const created = await this.prisma.appLog.create({
      data: { level, source, message, meta },
    });
    const staleLogs = await this.prisma.appLog.findMany({
      orderBy: { createdAt: 'desc' },
      skip: 20,
      select: { id: true },
    });
    if (staleLogs.length) {
      await this.prisma.appLog.deleteMany({
        where: { id: { in: staleLogs.map((log) => log.id) } },
      });
    }
    return created;
  }
}
